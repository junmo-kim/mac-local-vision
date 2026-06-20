import Testing
@testable import VisionCore

@Suite("CLIHelp — per-command --help source of truth")
struct CLIHelpTests {
    @Test("--help and -h are detected anywhere in the args")
    func wantsHelp() {
        #expect(CLIHelp.wantsHelp(["--help"]))
        #expect(CLIHelp.wantsHelp(["-h"]))
        #expect(CLIHelp.wantsHelp(["shot.png", "--help"]))
        #expect(!CLIHelp.wantsHelp(["shot.png", "--target", "Submit"]))
        #expect(!CLIHelp.wantsHelp([]))
    }

    @Test("every dispatchable command with flags has a usage string")
    func usageCoverage() {
        for cmd in ["ocr", "find", "ask", "sort-faces", "find-person", "doctor"] {
            let u = CLIHelp.usage(for: cmd)
            #expect(u != nil, "missing usage for \(cmd)")
            #expect(u?.contains("macvis \(cmd)") == true, "usage for \(cmd) should name the command")
        }
        #expect(CLIHelp.usage(for: "nonsense") == nil)
    }
}
