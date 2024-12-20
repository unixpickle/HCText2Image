import Cocoa
import Foundation
import Honeycrisp

@main
struct Main {
  static func main() async {
    if CommandLine.arguments.count < 2 {
      printHelp()
      return
    }
    let commands = [
      "vqvae": CommandVQVAE.init,
      "transformer": CommandTransformer.init,
      "tokenize": CommandTokenize.init,
      "server": CommandServer.init,
    ]
    guard let command = commands[CommandLine.arguments[1]] else {
      print("Unrecognized subcommand: \(CommandLine.arguments[1])")
      printHelp()
      return
    }
    do {
      let runner = try command(Array(CommandLine.arguments[2...]))
      try await runner.run()
    } catch {
      print("ERROR: \(error)")
    }
  }

  static func printHelp() {
    print("Usage: Text2Image <subcommand> ...")
    print("Subcommands:")
    print("    vqvae <image_dir> <state_path>")
    print("    tokenize <image_dir> <vqvae_path> <output_dir>")
    print("    transformer <data_dir> <vqvae_path> <state_path>")
    print("    server <vqvae_path> <save_path> [port]")
  }
}

func formatFloat(_ x: Float) -> String {
  String(format: "%.5f", x)
}
