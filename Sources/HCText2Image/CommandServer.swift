import Foundation
import Honeycrisp
import Vapor

enum ServerError: Error {
  case invalidPort(String)
  case missingResource(String)
  case loadResource(String)
}

class CommandServer: Command {

  let loadPath: String
  let vqPath: String
  let port: Int

  let vqvae: VQVAE
  let model: Transformer

  let captionTokenOffset: Int = 16384
  let captionBytes: Int = 128

  init(_ args: [String]) throws {
    Backend.defaultBackend = try MPSBackend()

    if ![2, 3].contains(args.count) {
      print("Usage: Text2Image server <vqvae_path> <save_path> [port]")
      throw ArgumentError.invalidArgs
    }
    vqPath = args[0]
    loadPath = args[1]
    guard let port = args.count > 2 ? Int(args[2]) : 8080 else {
      throw ServerError.invalidPort(args[2])
    }
    self.port = port

    vqvae = VQVAE(channels: 4, vocab: 16384, latentChannels: 4, downsamples: 4)
    model = Transformer(
      config: TransformerConfig(
        VocabSize: vqvae.bottleneck.vocab + 256, TokenCount: captionBytes + 16 * 16,
        WeightGradBackend: Backend.current))
  }

  override public func run() async throws {
    try await loadVQVAE()
    try await loadModel()

    let app = try await Application.make(.detect(arguments: ["serve"]))
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = port

    let filenames = ["index.html", "app.js"]
    let contentTypes = ["html": "text/html", "js": "text/javascript"]
    for filename in filenames {
      let parts = filename.split(separator: ".")
      guard
        let url = Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1]))
      else {
        throw ServerError.missingResource(filename)
      }
      guard let contents = try? Data(contentsOf: url) else {
        throw ServerError.loadResource(filename)
      }
      app.on(.GET, filename == "index.html" ? "" : "\(filename)") { request -> Response in
        Response(
          status: .ok,
          headers: ["content-type": contentTypes[String(parts[1])]!],
          body: .init(data: contents))
      }
    }

    app.responseCompression(.disable, force: true).on(.GET, "sample") { request -> Response in
      guard let prompt = request.query[String.self, at: "prompt"] else {
        print("missing prompt in query")
        return Response(status: .badRequest)
      }

      guard let guidanceScale = request.query[Float.self, at: "guidanceScale"] else {
        print("missing guidanceScale in query")
        return Response(status: .badRequest)
      }

      let response = Response(
        body: Response.Body.init(asyncStream: { [self] writer in
          print("starting sampling for prompt: \(prompt)")
          defer { print("sampling request exiting for prompt: \(prompt)") }

          // This seems to work around server-side buffering that would
          // otherwise delay the response.
          let bufferFiller = [String](repeating: "\n", count: 1024).joined().utf8
          try await writer.write(.buffer(ByteBuffer(data: Data(bufferFiller))))

          for try await token in sample(prompt: prompt, cfgScale: guidanceScale) {
            try await writer.write(.buffer(ByteBuffer(bytes: Data("\(token)\n".utf8))))
          }
          try await writer.write(.end)
        })
      )

      return response
    }

    app.on(.GET, "render") { request -> Response in
      guard let tokenStr = request.query[String.self, at: "tokens"] else {
        return Response(status: .badRequest)
      }
      var tokens = [Int]()
      for comp in tokenStr.split(separator: ",") {
        guard let token = Int(comp) else {
          return Response(status: .badRequest)
        }
        tokens.append(token)
      }
      if tokens.count > 16 * 16 {
        return Response(status: .badRequest)
      }

      while tokens.count < 16 * 16 {
        tokens.append(tokens.last ?? 0)
      }

      let imgTensor = Tensor.withGrad(enabled: false) {
        let embs = self.vqvae.bottleneck.embed(
          Tensor(data: tokens, shape: [1, 16, 16], dtype: .int64))
        return self.vqvae.decoder(embs.move(axis: -1, to: 1)).move(axis: 1, to: -1).flatten(
          endAxis: 1)
      }
      let img = try await tensorToImage(tensor: imgTensor)
      return Response(
        status: .ok,
        headers: ["content-type": "image/png"],
        body: .init(data: img)
      )
    }

    try await app.execute()
  }

  private func loadVQVAE() async throws {
    print("loading VQVAE from checkpoint: \(vqPath) ...")
    let data = try Data(contentsOf: URL(fileURLWithPath: vqPath))
    let decoder = PropertyListDecoder()
    let state = try decoder.decode(CommandVQVAE.State.self, from: data)
    try vqvae.loadState(state.model)
  }

  private func loadModel() async throws {
    print("loading model from checkpoint: \(loadPath) ...")
    let data = try Data(contentsOf: URL(fileURLWithPath: loadPath))
    let decoder = PropertyListDecoder()
    let state = try decoder.decode(CommandTransformer.State.self, from: data)
    try model.loadState(state.model)
  }

  func captionTensor(_ caption: String) -> Tensor {
    var textTokens = [Int](repeating: 0, count: captionBytes)
    for (j, char) in caption.utf8.enumerated() {
      if j >= captionBytes {
        break
      }
      textTokens[j] = Int(char) + vqvae.bottleneck.vocab
    }
    return Tensor(data: textTokens, shape: [1, captionBytes])
  }

  private func sample(prompt: String, cfgScale: Float) -> AsyncThrowingStream<Int, Error> {
    AsyncThrowingStream { [self] continuation in
      let t = Task.detached { [self] in
        do {
          for await x in model.sampleStream(prefixes: captionTensor(prompt), cfgScale: cfgScale) {
            if Task.isCancelled {
              return
            }
            do {
              continuation.yield(try await x.ints()[0])
            } catch {
              continuation.finish(throwing: error)
              return
            }
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in t.cancel() }
    }
  }

}
