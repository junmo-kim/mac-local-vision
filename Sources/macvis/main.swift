import Foundation
import VisionCore
import SemanticEngine

let version = "0.1.0"

func printUsage() {
    let usage = """
    macvis \(version) — Mac Local Vision (Zero-Token OCR / E2E targeting / on-device vision)

    USAGE:
      macvis <command> [options]

    VISION COMMANDS (macOS 26+, no Apple Intelligence required):
      Input: png/jpg/heic/tiff/... (ImageIO) or PDF (rasterized; --page N, --scale 2.0)
      ocr <image|pdf>             Extract text (coords opt-in)     [--boxes] [--words] [--fast] [--min-confidence N] [--lang ko,en] [--page N] [--scale S] [--format yaml|json]
      find <image|pdf> --target T Pixel-center of a word for E2E   [--min-confidence N] [--lang ko,en] [--page N] [--scale S] [--format yaml|json]
      sort-faces <dir>            Cluster photos by person          [--output-dir DIR] [--threshold F]
      find-person --target FACE   Index photos matching a face      [--dir DIR] [--threshold F]

    SEMANTIC COMMAND (Beta — needs macOS 27 (Beta) + an Apple-Intelligence-eligible Mac):
      ask <image> --prompt P      On-device multimodal reasoning (Beta)  [--stream] [--format yaml|json]

    AGENT INTERFACE:
      mcp                         MCP server over stdio (JSON-RPC) — ocr/find/doctor tools (+ask on macOS 27 builds)

    UTILITY:
      doctor                      Report which modes are available here
      --version | --help

    Run `macvis <command> --help` for a single command's flags.
    Output is YAML by default; data on stdout, errors on stderr.
    """
    print(usage)
}

let arguments = Array(CommandLine.arguments.dropFirst())

func dispatch(_ args: [String]) async -> Int32 {
    guard let sub = args.first else {
        printUsage()
        return ExitCode.usage.rawValue
    }
    let rest = Array(args.dropFirst())
    do {
        switch sub {
        case "ocr":                    return try await OCRCommand.run(rest)
        case "find":                   return try await FindCommand.run(rest)
        case "ask":                    return try await AskCommand.run(rest)
        case "sort-faces", "find-person": return try FacesCommand.run(sub, rest)
        case "doctor":                 return await DoctorCommand.run(rest)
        case "mcp":                    return await MCPCommand.run(rest)
        case "help", "-h", "--help":   printUsage(); return ExitCode.success.rawValue
        case "version", "--version":   print("macvis \(version)"); return ExitCode.success.rawValue
        default:
            IO.warn("error: unknown command '\(sub)' (try: macvis --help)")
            return ExitCode.usage.rawValue
        }
    } catch let error as CLIError {
        IO.warn("error: \(error.message)")
        return error.exitCode.rawValue
    } catch {
        IO.warn("error: \(error)")
        return ExitCode.runtimeError.rawValue
    }
}

let code = await dispatch(arguments)
exit(code)
