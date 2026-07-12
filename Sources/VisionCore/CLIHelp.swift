import Foundation

/// Single source of truth for per-command usage strings, shared by `--help` and the
/// "missing argument" error paths so the two can never drift. The skill / README point
/// agents at `macvis <command> --help` as the canonical flag reference, so this must
/// actually answer.
public enum CLIHelp {
    /// True when the user asked for help (`--help` / `-h`) anywhere in the args.
    public static func wantsHelp(_ args: [String]) -> Bool {
        args.contains("--help") || args.contains("-h")
    }

    private static let usages: [String: String] = [
        "ocr": "usage: macvis ocr <image|pdf> [--boxes] [--words] [--fast] [--min-confidence N] [--lang ko,en] [--page N] [--scale S] [--format yaml|json]",
        "find": "usage: macvis find <image|pdf> --target <text> [--min-confidence N] [--lang ko,en] [--page N] [--scale S] [--format yaml|json]",
        "barcode": "usage: macvis barcode <image|pdf> [--symbology qr,code128,...] [--min-confidence N] [--page N] [--scale S] [--format yaml|json]",
        "make-qr": "usage: macvis make-qr <text> [--out <path>] [--correction-level L|M|Q|H] [--size N] [--format yaml|json]",
        "ask": "usage: macvis ask <image|pdf> --prompt <text> [--stream] [--page N] [--scale S] [--format yaml|json]   (Beta — needs macOS 27)",
        "sort-faces": "usage: macvis sort-faces <dir> [--output-dir DIR] [--threshold F] [--format yaml|json]",
        "find-person": "usage: macvis find-person --target <image> [--dir DIR] [--threshold F] [--format yaml|json]",
        "doctor": "usage: macvis doctor [--format yaml|json]",
        "serve": "usage: macvis serve [--host H] [--port N]   (HTTP MCP server for remote nodes; default 0.0.0.0:9090)",
    ]

    /// Usage string for a command, or nil if the command has none.
    public static func usage(for command: String) -> String? { usages[command] }
}
