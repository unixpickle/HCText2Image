import Foundation
import Honeycrisp

class CommandVQVAE: Command {

  public struct State: Codable {
    let step: Int
    let model: Trainable.State
    let dataset: ImageDataLoader.State?
    let opt: Adam.State?
  }

  let lr: Float = 0.0001
  let bs = 8
  let reviveInterval = 100
  let reviveBatches = 2
  let commitCoeff = 0.5
  let ssimCoeff = 0.1

  let savePath: String
  let imageDir: String
  let model: VQVAE
  let opt: Adam
  let ssim: SSIM
  var step: Int = 0
  let dataLoader: ImageDataLoader
  var dataStream: AsyncThrowingStream<(Tensor, ImageDataLoader.State), Error>?

  init(_ args: [String]) throws {
    Backend.defaultBackend = try MPSBackend(allocator: .bucket)

    if args.count != 2 {
      print("Usage: ... vqvae <image_dir> <save_path>")
      throw ArgumentError.invalidArgs
    }
    imageDir = args[0]
    savePath = args[1]

    model = VQVAE(channels: 4, vocab: 16384, latentChannels: 4, downsamples: 4)
    opt = Adam(model.parameters, lr: lr)
    ssim = SSIM()
    dataLoader = ImageDataLoader(
      batchSize: bs, images: try ImageIterator(imageDir: imageDir, imageSize: 256))
  }

  override public func run() async throws {
    try await prepare()

    while true {
      try await revive()
      try await trainInnerLoop()
      try await sampleAndSave()
    }
  }

  private func prepare() async throws {
    if FileManager.default.fileExists(atPath: savePath) {
      print("loading from checkpoint: \(savePath) ...")
      let data = try Data(contentsOf: URL(fileURLWithPath: savePath))
      let decoder = PropertyListDecoder()
      let state = try decoder.decode(State.self, from: data)
      try model.loadState(state.model)
      if let optState = state.opt {
        try opt.loadState(optState)
      }
      if let dataState = state.dataset {
        dataLoader.state = dataState
      }
      step = state.step
    }

    dataStream = loadDataInBackground(dataLoader)
  }

  private func takeDataset(_ n: Int) -> AsyncPrefixSequence<
    AsyncThrowingStream<(Tensor, ImageDataLoader.State), Error>
  > {
    return dataStream!.prefix(n)
  }

  private func revive() async throws {
    print("reviving unused dictionary entries...")
    print(" => collecting features...")
    var reviveBatch = [Tensor]()
    for try await (x, _) in takeDataset(reviveBatches) {
      reviveBatch.append(x)
    }
    let revivedCount = Tensor.withGrad(enabled: false) {
      let features = model.withMode(.inference) {
        Tensor(concat: reviveBatch.map(model.features))
      }
      print(" => collected \(features.shape[0]) features")
      return model.bottleneck.revive(features)
    }
    print(" => revived \(try await revivedCount.ints()[0]) entries")
  }

  private func trainInnerLoop() async throws {
    print("training...")
    for try await (batch, _) in takeDataset(reviveInterval) {
      step += 1
      let (output, vqLosses) = model(batch)
      let loss = (output - batch).pow(2).mean()
      let ssimLoss = ssim(output, batch)
      let ssimMSE = (2 * (1 - ssimLoss)).mean()  // scale more similarly to MSE
      (loss + ssimMSE * ssimCoeff + vqLosses.codebookLoss + commitCoeff
        * vqLosses.commitmentLoss).backward()
      opt.step()
      opt.clearGrads()
      print(
        "step \(step):"
          + " loss=\(try await loss.item())"
          + " ssim=\(try await ssimLoss.mean().item())"
          + " commitment=\(try await vqLosses.commitmentLoss.item())"
          + " gflops=\(gflops)")
    }
  }

  private func sampleAndSave() async throws {
    print("dumping samples to: samples.png ...")
    var it = dataStream!.makeAsyncIterator()
    let (input, dataState) = try await it.next()!
    let (output, _) = Tensor.withGrad(enabled: false) {
      model.withMode(.inference) {
        model(input)
      }
    }
    let images = Tensor(concat: [input, output], axis: -1)
    let img = try await tensorToImage(tensor: images.move(axis: 1, to: -1).flatten(endAxis: 1))
    try img.write(to: URL(filePath: "samples.png"))

    print("saving to \(savePath) ...")
    let state = State(
      step: step,
      model: try await model.state(),
      dataset: dataState,
      opt: try await opt.state()
    )
    let stateData = try PropertyListEncoder().encode(state)
    try stateData.write(to: URL(filePath: savePath), options: .atomic)
  }

}
