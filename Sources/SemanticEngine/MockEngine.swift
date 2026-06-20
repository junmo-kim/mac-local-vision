import Foundation

/// CI / unit-test engine. Exercises the `ask` plumbing without any model.
public struct MockEngine: SemanticEngine {
    private let response: String

    public init(response: String = "stub-response") {
        self.response = response
    }

    public func ask(imagePath: String, prompt: String, stream: Bool,
                    page: Int, scale: Double) async throws -> AskOutcome {
        AskOutcome(text: response, compute: .onDevice)
    }
}
