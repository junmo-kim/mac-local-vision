import Testing
@testable import VisionCore

@Suite("ArgParser — dependency-free CLI parsing")
struct ArgParserTests {
    @Test("positionals, options, and valued flags")
    func mixed() {
        let p = ArgParser.parse(["./screen.png", "--target", "결제하기", "--min-confidence", "0.3"])
        #expect(p.firstPositional == "./screen.png")
        #expect(p.option("target") == "결제하기")
        #expect(p.option("min-confidence") == "0.3")
    }

    @Test("boolean flags consume no value")
    func booleanFlags() {
        let p = ArgParser.parse(["img.png", "--fast", "--format", "json"], booleanFlags: ["fast"])
        #expect(p.flag("fast"))
        #expect(p.option("format") == "json")
        #expect(p.firstPositional == "img.png")
    }

    @Test("--key=value form")
    func equalsForm() {
        let p = ArgParser.parse(["--port=8080", "--token=secret"])
        #expect(p.option("port") == "8080")
        #expect(p.option("token") == "secret")
    }

    @Test("trailing option with no value degrades to a flag")
    func danglingOption() {
        let p = ArgParser.parse(["img.png", "--stream"])
        #expect(p.flag("stream"))
        #expect(p.option("stream") == nil)
    }

    @Test("negative-number values are kept, not mistaken for flags")
    func negativeNumberValues() {
        let p = ArgParser.parse(["img.png", "--min-confidence", "-0.3", "--scale", "-1"])
        #expect(p.option("min-confidence") == "-0.3")
        #expect(p.option("scale") == "-1")
    }

    @Test("repeated option: last value wins")
    func repeatedOption() {
        let p = ArgParser.parse(["--lang", "ko-KR", "--lang", "ja-JP"])
        #expect(p.option("lang") == "ja-JP")
    }
}
