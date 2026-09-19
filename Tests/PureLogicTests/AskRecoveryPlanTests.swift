import Testing
import Foundation
@testable import VisionCore

@Suite("AskRecoveryPlan — structured recovery guidance")
struct AskRecoveryPlanTests {
    private let korean = (identifier: "ko-KR", displayName: "Korean (South Korea)")

    @Test("preferred Mac language is normalized to BCP 47 with a display name")
    func macLanguageNormalization() {
        let language = AskRecoveryPlan.macLanguage(
            preferredIdentifier: "ko_KR", displayLocale: Locale(identifier: "en"))
        #expect(language.identifier == "ko-KR")
        #expect(language.displayName == "Korean (South Korea)")
    }

    @Test("model_not_ready names the Mac language and gives ordered setup/download steps")
    func modelNotReady() {
        let plan = AskRecoveryPlan.plan(for: "model_not_ready", macLanguage: korean)
        #expect(plan != nil)
        guard let plan else { return }

        #expect(plan.steps.count == 4)
        #expect(plan.steps[0].action.contains("Korean (South Korea)"))
        #expect(plan.steps[0].action.contains("ko-KR"))
        #expect(plan.steps[0].action.contains("Siri"))
        #expect(plan.steps[0].expected.contains("match"))
        #expect(plan.steps[1].action.lowercased().contains("download progress"))
        #expect(plan.steps[2].action.lowercased().contains("power"))
        #expect(plan.steps[2].action.lowercased().contains("network"))
        #expect(plan.steps[3].action == "Run macvis doctor again.")
        #expect(plan.steps[3].command == "macvis doctor --format json")
        #expect(plan.verify.command == "macvis doctor --format json")
        #expect(plan.verify.success.contains("\"available\""))

        let json = plan.value().render(as: .json)
        #expect(json.contains("\"if_unresolved\""))
        #expect(!json.contains("siri_disabled"))
        #expect(!json.contains("apple_intelligence_language_mismatch"))
    }

    @Test("apple_intelligence_not_enabled has enable, wait, doctor steps in order")
    func appleIntelligenceNotEnabled() {
        let plan = AskRecoveryPlan.plan(
            for: "apple_intelligence_not_enabled", macLanguage: korean)
        #expect(plan?.steps.count == 3)
        #expect(plan?.steps[0].action.contains("Enable Apple Intelligence") == true)
        #expect(plan?.steps[1].action.lowercased().contains("ready") == true)
        #expect(plan?.steps[2].action == "Run macvis doctor again.")
    }

    @Test(arguments: [
        "device_not_eligible",
        "needs_macos_27_for_image_input",
        "model_assets_unavailable",
        "session_busy",
    ])
    func otherKnownReasonsHaveCompletePlans(reason: String) {
        let plan = AskRecoveryPlan.plan(for: reason, macLanguage: korean)
        #expect(plan != nil)
        #expect(plan?.status.isEmpty == false)
        #expect(plan?.steps.isEmpty == false)
        #expect(plan?.steps.allSatisfy {
            !$0.action.isEmpty && !$0.expected.isEmpty
        } == true)
        #expect(plan?.verify.command.isEmpty == false)
        #expect(plan?.verify.success.isEmpty == false)
        #expect(plan?.ifUnresolved.action.isEmpty == false)
        #expect(plan?.ifUnresolved.commands.isEmpty == false)
    }

    @Test("unobserved reasons do not synthesize recovery guidance")
    func unknownReason() {
        #expect(AskRecoveryPlan.plan(for: "siri_disabled", macLanguage: korean) == nil)
        #expect(AskRecoveryPlan.plan(
            for: "apple_intelligence_language_mismatch", macLanguage: korean) == nil)
    }

    @Test("ServiceError recovery is additive and legacy envelope remains unchanged when absent")
    func serviceErrorEnvelope() {
        let plan = AskRecoveryPlan.plan(for: "session_busy", macLanguage: korean)
        let withRecovery = ServiceError(
            name: "ask_unavailable", reason: "session_busy",
            detail: "Another request is using this session.", hint: "Retry shortly.",
            recovery: plan, exitCode: 71)
        let legacy = ServiceError(
            name: "ask_unavailable", reason: "session_busy",
            detail: "Another request is using this session.", hint: "Retry shortly.",
            exitCode: 71)

        #expect(withRecovery.envelope().render(as: .json).contains("\"recovery\""))
        #expect(legacy.envelope() == .dict([
            ("error", .string("ask_unavailable")),
            ("reason", .string("session_busy")),
            ("detail", .string("Another request is using this session.")),
            ("hint", .string("Retry shortly.")),
        ]))
    }
}
