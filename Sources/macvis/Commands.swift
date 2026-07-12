import Foundation
import VisionCore
import SemanticEngine

/// Run a request through the shared service and emit it (stdout=data, stderr=error).
func runService(_ req: VisionRequest, format: OutputFormat) async -> Int32 {
    do {
        let result = try await VisionService.handle(req)
        IO.emit(result.value, format: format)
        return result.exitCode
    } catch let e as ServiceError {
        IO.emitError(e.envelope(), format: format)
        return e.exitCode
    } catch {
        IO.warn("error: \(error)")
        return ExitCode.runtimeError.rawValue
    }
}

/// Print a command's usage to stdout and exit 0 — answers `macvis <command> --help`.
private func helpExit(_ command: String) -> Int32 {
    print(CLIHelp.usage(for: command) ?? "usage: macvis \(command)")
    return ExitCode.success.rawValue
}

// MARK: - ocr

enum OCRCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("ocr") }
        let parsed = ArgParser.parse(args, booleanFlags: ["fast", "words", "boxes"])
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "ocr")!)
        }
        let req = VisionRequest(
            op: "ocr", path: path,
            fast: parsed.flag("fast"), words: parsed.flag("words"), boxes: parsed.flag("boxes"),
            minConfidence: try optDouble(parsed, "min-confidence"),
            languages: parsed.option("lang").map { $0.split(separator: ",").map(String.init) },
            page: try optInt(parsed, "page"),
            scale: try optDouble(parsed, "scale"))
        return await runService(req, format: format)
    }
}

// MARK: - find

enum FindCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("find") }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "find")!)
        }
        guard let target = parsed.option("target") else {
            throw CLIError(message: "find requires --target <text>")
        }
        let req = VisionRequest(
            op: "find", path: path, target: target,
            minConfidence: try optDouble(parsed, "min-confidence"),
            languages: parsed.option("lang").map { $0.split(separator: ",").map(String.init) },
            page: try optInt(parsed, "page"),
            scale: try optDouble(parsed, "scale"))
        return await runService(req, format: format)
    }
}

// MARK: - barcode

enum BarcodeCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("barcode") }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "barcode")!)
        }
        let req = VisionRequest(
            op: "barcode", path: path,
            minConfidence: try optDouble(parsed, "min-confidence"),
            page: try optInt(parsed, "page"),
            scale: try optDouble(parsed, "scale"),
            symbologies: parsed.option("symbology").map { $0.split(separator: ",").map(String.init) })
        return await runService(req, format: format)
    }
}

// MARK: - document-ocr

/// Structured document OCR — `RecognizeDocumentsRequest` (title/paragraphs/tables/lists),
/// nested alongside `ocr`'s plain-text path (VisionService.documentOCR). `run` is `async`
/// like `AskCommand` (not `throws`-only sync like `OCRCommand`): the underlying engine call
/// is `async throws`, driven through the same `runService` seam as every other command.
enum DocumentOCRCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("document-ocr") }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "document-ocr")!)
        }
        let req = VisionRequest(
            op: "document-ocr", path: path,
            page: try optInt(parsed, "page"),
            scale: try optDouble(parsed, "scale"))
        return await runService(req, format: format)
    }
}

// MARK: - qr

/// `barcode` restricted to QR only, server-side (see VisionService.qr) — deliberately has
/// no --symbology flag, so there's no argument to parse that could override it.
enum QRCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("qr") }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "qr")!)
        }
        let req = VisionRequest(
            op: "qr", path: path,
            minConfidence: try optDouble(parsed, "min-confidence"),
            page: try optInt(parsed, "page"),
            scale: try optDouble(parsed, "scale"))
        return await runService(req, format: format)
    }
}

// MARK: - make-qr

enum MakeQRCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("make-qr") }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        guard let text = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "make-qr")!)
        }
        let req = VisionRequest(
            op: "make-qr", text: text,
            outPath: parsed.option("out"),
            correctionLevel: parsed.option("correction-level"),
            size: try optInt(parsed, "size"))
        return await runService(req, format: format)
    }
}

// MARK: - document-bounds

enum DocumentBoundsCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("document-bounds") }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "document-bounds")!)
        }
        let req = VisionRequest(
            op: "document-bounds", path: path,
            minConfidence: try optDouble(parsed, "min-confidence"),
            page: try optInt(parsed, "page"),
            scale: try optDouble(parsed, "scale"))
        return await runService(req, format: format)
    }
}

// MARK: - rectify-document

enum RectifyDocumentCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("rectify-document") }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "rectify-document")!)
        }
        let req = VisionRequest(
            op: "rectify-document", path: path,
            minConfidence: try optDouble(parsed, "min-confidence"),
            page: try optInt(parsed, "page"),
            scale: try optDouble(parsed, "scale"),
            outPath: parsed.option("out"))
        return await runService(req, format: format)
    }
}

// MARK: - ask

enum AskCommand {
    static func run(_ args: [String]) async throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("ask") }
        let parsed = ArgParser.parse(args, booleanFlags: ["stream"])
        let format = try resolveFormat(parsed)
        guard let path = parsed.firstPositional else {
            throw CLIError(message: CLIHelp.usage(for: "ask")!)
        }
        guard let prompt = parsed.option("prompt") else {
            throw CLIError(message: "ask requires --prompt <text>")
        }
        let req = VisionRequest(op: "ask", path: path, prompt: prompt,
                                stream: parsed.flag("stream"),
                                page: try optInt(parsed, "page"), scale: try optDouble(parsed, "scale"))
        return await runService(req, format: format)
    }
}

// MARK: - doctor

enum DoctorCommand {
    static func run(_ args: [String]) async -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit("doctor") }
        let parsed = ArgParser.parse(args)
        let format = (try? resolveFormat(parsed)) ?? .yaml
        return await runService(VisionRequest(op: "doctor"), format: format)
    }
}

// MARK: - faces

enum FacesCommand {
    static func run(_ sub: String, _ args: [String]) throws -> Int32 {
        if CLIHelp.wantsHelp(args) { return helpExit(sub) }
        let parsed = ArgParser.parse(args)
        let format = try resolveFormat(parsed)
        // Feature-print distance scale (measured): identical ≈ 0, different people ≈ 1.0+.
        // 0.5 separates clearly-different faces; tune per dataset (distances are in output).
        let threshold = try optDouble(parsed, "threshold").map(Float.init) ?? 0.5
        do {
            let result: YAMLValue
            switch sub {
            case "sort-faces":
                result = try FaceEngine.sortFaces(inputDir: parsed.firstPositional ?? ".",
                                                  outputDir: parsed.option("output-dir"),
                                                  threshold: threshold)
            case "find-person":
                guard let target = parsed.option("target") else {
                    throw CLIError(message: "find-person requires --target <image>")
                }
                result = try FaceEngine.findPerson(targetImage: target,
                                                   inDir: parsed.option("dir") ?? ".",
                                                   threshold: threshold)
            default:
                throw CLIError(message: "unknown faces subcommand: \(sub)")
            }
            IO.emit(result, format: format)
            return ExitCode.success.rawValue
        } catch let error as VisionError {
            IO.emitError(.dict([
                ("error", .string("face_error")),
                ("detail", .string(error.description)),
                ("hint", .string("check the path is a readable image/dir with detectable faces")),
            ]), format: format)
            return ExitCode.runtimeError.rawValue
        }
    }
}

// MARK: - mcp

enum MCPCommand {
    static func run(_ args: [String]) async -> Int32 { await MCPServer.run() }
}

// MARK: - serve

enum ServeCommand {
    static func run(_ args: [String]) async -> Int32 {
        if CLIHelp.wantsHelp(args) {
            print(CLIHelp.usage(for: "serve") ?? "usage: macvis serve [--host H] [--port N]")
            return ExitCode.success.rawValue
        }
        let parsed = ArgParser.parse(args)
        let host = parsed.option("host") ?? "0.0.0.0"
        var rawPort: UInt16 = 9090
        if let portStr = parsed.option("port") {
            guard let p = UInt16(portStr), p != 0 else {
                IO.warn("error: --port must be 1–65535, got: \(portStr)")
                return ExitCode.usage.rawValue
            }
            rawPort = p
        }
        if host == "0.0.0.0" || host == "::" {
            IO.warn("warning: serve is listening on all interfaces with no authentication — " +
                    "restrict access with a firewall or use --host 127.0.0.1 for local-only.")
        }
        return await HTTPServer.run(host: host, port: rawPort)
    }
}
