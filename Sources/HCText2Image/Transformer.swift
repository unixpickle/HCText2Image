import Cocoa
import Foundation
import Honeycrisp

struct TransformerConfig {
  var VocabSize: Int
  let TokenCount: Int
  var WeightGradBackend: Backend
  var LayerCount: Int = 24
  var ModelDim: Int = 1024
  var HeadDim: Int = 64
}

/// Implementation based on
/// https://pytorch.org/torchtune/stable/_modules/torchtune/modules/position_embeddings.html#RotaryPositionalEmbeddings
class RoPE {
  let cache: Tensor

  init(dim: Int, maxTokens: Int, base: Int = 10000, dtype: Tensor.DType = .float32) {
    let theta = (-log(Float(base)) * Tensor(data: 0..<(dim / 2)).cast(dtype) / dim).exp()
    let indices = Tensor(data: 0..<maxTokens).cast(dtype).unsqueeze(axis: -1).repeating(
      axis: 1, count: dim / 2)
    let args = indices * theta
    cache = Tensor(stack: [args.cos(), args.sin()], axis: -1)
  }

  func callAsFunction(_ x: Tensor, offset: Int = 0) -> Tensor {
    assert(x.shape.count == 4, "expected [B x H x T x C]")

    let cache = self.cache[offset..<(x.shape[2] + offset)]

    let x2D = x.reshape(Array(x.shape[..<3]) + [x.shape[3] / 2, 2])  // [B x H x T x C/2 x 2]
    let shapedCache = cache.reshape([x2D.shape[2], x2D.shape[3], 2])
    let x0 = x2D[..., ..., ..., ..., 0]
    let x1 = x2D[..., ..., ..., ..., 1]
    let r0 = shapedCache[..., ..., 0]
    let r1 = shapedCache[..., ..., 1]
    return Tensor(stack: [x0 * r0 - x1 * r1, x0 * r1 + x1 * r0], axis: -1).flatten(startAxis: 3)
  }
}

class KVCache {
  class Layer {
    var k: Tensor
    var v: Tensor

    var tokenCount: Int {
      k.shape[1]
    }

    init(batchSize: Int, config: TransformerConfig) {
      k = Tensor(zeros: [batchSize, 0, config.ModelDim], dtype: .float16)
      v = Tensor(zeros: [batchSize, 0, config.ModelDim], dtype: .float16)
    }
  }

  var layers: [Layer]

  var tokenCount: Int {
    layers[0].tokenCount
  }

  init(batchSize: Int, config: TransformerConfig) {
    layers = []
    for _ in 0..<config.LayerCount {
      layers.append(Layer(batchSize: batchSize, config: config))
    }
  }
}

class Attention: Trainable {
  let config: TransformerConfig
  let causalMask: Tensor
  var rope: RoPE

  @Child var qProj: Linear
  @Child var kProj: Linear
  @Child var vProj: Linear
  @Child var outProj: Linear

  init(config: TransformerConfig) {
    self.config = config
    rope = RoPE(dim: config.HeadDim, maxTokens: config.TokenCount)
    causalMask = Tensor(constant: 1e8, shape: [config.TokenCount, config.TokenCount]).tril() - 1e8
    super.init()
    self.qProj = Linear(
      inCount: config.ModelDim, outCount: config.ModelDim, castParams: .float16, bias: false)
    self.kProj = Linear(
      inCount: config.ModelDim, outCount: config.ModelDim, castParams: .float16, bias: false)
    self.vProj = Linear(
      inCount: config.ModelDim, outCount: config.ModelDim, castParams: .float16, bias: false)
    self.outProj = Linear(
      inCount: config.ModelDim, outCount: config.ModelDim, castParams: .float16, bias: false)
  }

  func callAsFunction(_ x: Tensor, kvCache: KVCache.Layer? = nil) -> Tensor {
    // Go from [B x T x C] -> [B x H x T x C/H]
    func moveHeadsToOuter(_ x: Tensor) -> Tensor {
      x.reshape([x.shape[0], x.shape[1], config.ModelDim / config.HeadDim, config.HeadDim])[
        FullRange(), PermuteAxes(1, 0)]
    }

    // Go from [B x H x T x C/H] -> [B x T x C]
    func moveHeadsToInner(_ x: Tensor) -> Tensor {
      x[FullRange(), PermuteAxes(1, 0)].reshape([x.shape[0], x.shape[2], x.shape[1] * x.shape[3]])
    }

    let tokenOffset = kvCache?.tokenCount ?? 0

    let (k, v) =
      if let kvCache = kvCache {
        {
          let innerK = Tensor(
            concat: [kvCache.k, kProj(x, weightGradBackend: config.WeightGradBackend)], axis: 1)
          let innerV = Tensor(
            concat: [kvCache.v, vProj(x, weightGradBackend: config.WeightGradBackend)], axis: 1)
          let k = moveHeadsToOuter(innerK) / sqrt(sqrt(Float(config.HeadDim)))
          let v = moveHeadsToOuter(innerV)
          kvCache.k = innerK
          kvCache.v = innerV
          return (k, v)
        }()
      } else {
        (
          moveHeadsToOuter(kProj(x, weightGradBackend: config.WeightGradBackend))
            / sqrt(sqrt(Float(config.HeadDim))),
          moveHeadsToOuter(vProj(x, weightGradBackend: config.WeightGradBackend))
        )
      }
    let q =
      moveHeadsToOuter(qProj(x, weightGradBackend: config.WeightGradBackend))
      / sqrt(sqrt(Float(config.HeadDim)))

    let energy = Tensor.batchedMatmul(
      a: rope(q.cast(.float32), offset: tokenOffset), transA: false, b: rope(k.cast(.float32)),
      transB: true, transOut: false)
    let probs = (energy + causalMask[tokenOffset..<k.shape[2], 0..<k.shape[2]])
      .softmax().cast(.float16)
    let reducedValues = Tensor.batchedMatmul(
      a: probs, transA: false, b: v, transB: false, transOut: false)
    return outProj(moveHeadsToInner(reducedValues), weightGradBackend: config.WeightGradBackend)
  }
}

class Block: Trainable {
  let config: TransformerConfig

  @Child var attn: Attention
  @Child var norm1: LayerNorm
  @Child var norm2: LayerNorm
  @Child var lin1: Linear
  @Child var lin2: Linear

  init(config: TransformerConfig) {
    self.config = config
    super.init()
    self.attn = Attention(config: config)
    self.norm1 = LayerNorm(shape: [config.ModelDim])
    self.norm2 = LayerNorm(shape: [config.ModelDim])
    self.lin1 = Linear(
      inCount: config.ModelDim, outCount: config.ModelDim * 2, castParams: .float16, bias: false)
    self.lin2 = Linear(
      inCount: config.ModelDim * 2, outCount: config.ModelDim, castParams: .float16, bias: false)
  }

  func callAsFunction(_ x: Tensor, kvCache: KVCache.Layer? = nil) -> Tensor {
    var h = x
    h = h + attn(norm1(h), kvCache: kvCache)
    h =
      h
      + lin2(
        lin1(norm2(h), weightGradBackend: config.WeightGradBackend).gelu(),
        weightGradBackend: config.WeightGradBackend)
    return h
  }
}

class Transformer: Trainable {
  let config: TransformerConfig

  @Param var embed: Tensor
  @Child var layers: TrainableArray<Block>
  @Child var normOut: LayerNorm
  @Child var unembed: Linear

  init(config: TransformerConfig) {
    self.config = config
    super.init()
    embed = Tensor(randn: [config.VocabSize, config.ModelDim])
    layers = TrainableArray((0..<config.LayerCount).map { _ in Block(config: config) })
    normOut = LayerNorm(shape: [config.ModelDim])

    unembed = Linear(
      inCount: config.ModelDim, outCount: config.VocabSize, castParams: .float16, bias: false)

    // Uniform initial probability
    unembed.weight = unembed.weight.noGrad() * 0
  }

  func callAsFunction(_ x: Tensor, kvCache: KVCache? = nil) -> Tensor {
    // Input should be a [N x T] tensor of indices
    var h = embed.gather(axis: 0, indices: x.flatten()).cast(.float16).reshape([
      x.shape[0], x.shape[1], config.ModelDim,
    ])

    for (i, layer) in layers.children.enumerated() {
      let cacheLayer: KVCache.Layer? =
        if let kvCache = kvCache {
          kvCache.layers[i]
        } else {
          nil
        }
      h = layer(h, kvCache: cacheLayer)
    }
    h = normOut(h)
    h = unembed(h, weightGradBackend: config.WeightGradBackend)
    return h
  }

  func sample(prefixes: Tensor, generator: RandomGenerator? = nil, cfgScale: Float? = nil)
    async throws -> Tensor
  {
    var outputs: [Tensor] = []
    for try await x in sampleStream(prefixes: prefixes, generator: generator, cfgScale: cfgScale) {
      outputs.append(x)
    }
    return Tensor(concat: outputs, axis: 1)
  }

  func sampleStream(prefixes: Tensor, generator: RandomGenerator? = nil, cfgScale: Float? = nil)
    -> AsyncStream<Tensor>
  {
    assert(prefixes.shape.count == 2, "\(prefixes.shape)")
    assert(prefixes.shape[1] >= 1, "\(prefixes.shape)")
    let prefixes =
      cfgScale == nil ? prefixes : Tensor(concat: [prefixes, Tensor(zerosLike: prefixes)], axis: 0)
    let kvCache = KVCache(batchSize: prefixes.shape[0], config: config)
    let config = config
    return AsyncStream { continuation in
      let t = Task.detached {
        var prevToken = prefixes
        for _ in 0..<(config.TokenCount - prefixes.shape[1]) {
          if Task.isCancelled {
            return
          }
          let logits = Tensor.withGrad(enabled: false) {
            // Without asDependency, we may allocate fp16 parameters many
            // times at once since the internal cast() in the model doesn't
            // depend on any other result tensors.
            prevToken.asDependency {
              self(prevToken, kvCache: kvCache)[..., -1].cast(.float32)
            }
          }
          let guidedLogits =
            if let cfgScale = cfgScale {
              {
                let pieces = logits.chunk(axis: 0, count: 2)
                let cond = pieces[0]
                let uncond = pieces[1]
                return uncond + cfgScale * (cond - uncond)
              }()
            } else {
              logits
            }

          let gumbels = prevToken.asDependency {
            -(-Tensor(randLike: guidedLogits, generator: generator).log()).log()
          }
          let samples = (guidedLogits + gumbels).argmax(axis: -1).unsqueeze(axis: 1)
          if cfgScale == nil {
            prevToken = samples
          } else {
            prevToken = samples.repeating(axis: 0, count: 2)
          }

          continuation.yield(samples)
        }
        continuation.finish()
      }
      continuation.onTermination = { reason in
        if case .cancelled = reason {
          t.cancel()
        }
      }
    }
  }

  func paramNorm() async throws -> Float {
    try await parameters.map { (_, param) in param.data!.pow(2).sum() }
      .reduce(
        Tensor(zeros: []), { $0 + $1 }
      ).sqrt().item()
  }

  func gradNorm() async throws -> Float {
    var sum = Tensor(zeros: [])
    for (name, param) in parameters {
      if let grad = param.grad {
        sum = sum + grad.pow(2).sum()
      } else {
        print("WARNING: param \(name) has no gradient!")
      }
    }
    return try await sum.sqrt().item()
  }
}