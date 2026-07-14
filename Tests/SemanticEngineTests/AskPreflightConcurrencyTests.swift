#if canImport(FoundationModels)
import Testing
import Foundation
import FoundationModels
import os
@testable import SemanticEngine

/// Concurrency regression for `ask`'s synchronous pre-flight calls — runnable without
/// macOS 27 hardware, unlike the rest of `ask` (both APIs below are macOS 26+; only the
/// multimodal `Attachment`/`Prompt` image path needs `MACVIS_ASK_IMAGE` + the macOS 27 SDK).
///
/// Background (ask-schema plan's concurrency-safety risk item, 2026-07-14): `AFMEngine.ask()`
/// calls `probeAskAvailability()` (reads the plain synchronous `SystemLanguageModel.availability`
/// property) and constructs `LanguageModelSession()` (a plain synchronous `init`) directly
/// inside its `async` body — with no `VisionSerialQueue`-style suspend-not-block wrapper,
/// unlike every Vision engine (`OCREngine`/`FaceEngine`/`BarcodeEngine`/`DocumentEngine`),
/// all of which route their own synchronous, possibly-blocking Apple-framework calls through
/// exactly that pattern after a real deadlock was found and fixed (see `VisionSerialQueue`'s
/// doc comment). `ask` is reachable via `macvis serve`'s per-connection `Task` model the same
/// way those engines are, so the same risk *class* — an ordinary-looking synchronous system
/// API secretly blocking on IPC while called from Swift concurrency's cooperative pool —
/// plausibly applies here too, though it has never been tested.
///
/// This suite is a **preflight-only** regression test: it does NOT exercise the actual model
/// call (`respond`/`streamResponse`), which needs the macOS 27 multimodal `Attachment` API and
/// isn't reachable on this development machine. A clean pass here doesn't clear `ask` overall
/// (the higher-risk `Prompt`/`Attachment` construction — the one spot a real SIGSEGV crash
/// report confirms touches FoundationModels' XPC layer — still needs real macOS 27 hardware to
/// verify) but does answer, for the two calls it *can* reach: do these deadlock under
/// concurrent Task load on this OS/hardware, right now, with zero macOS 27 dependency.
@Suite("ask preflight — concurrency regression (probeAskAvailability + LanguageModelSession init)",
       .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil,
                "needs real FoundationModels/Apple Intelligence state; runs locally, not on CI runners."))
struct AskPreflightConcurrencyTests {
    /// Runs `concurrency` `Task`s of `body`, racing a `timeoutSeconds` wall-clock deadline.
    /// Mirrors `VisionTests/ConcurrencyTests.assertNoDeadlock` exactly — duplicated rather
    /// than shared across test targets for a single ~20-line helper (Tidy First: not worth
    /// a cross-target dependency for this).
    static func assertNoDeadlock(
        concurrency: Int, timeoutSeconds: Double, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async throws -> Void
    ) async {
        let completedBox = OSAllocatedUnfairLock(initialState: 0)
        let allCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { inner in
                        for _ in 0..<concurrency {
                            inner.addTask {
                                try await body()
                                completedBox.withLock { $0 += 1 }
                            }
                        }
                        for try await _ in inner {}
                    }
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(allCompleted, "timed out or threw before all \(concurrency) concurrent calls completed",
                sourceLocation: sourceLocation)
        #expect(completedBox.withLock { $0 } == concurrency, sourceLocation: sourceLocation)
    }

    @Test("probeAskAvailability(): 25 concurrent calls all complete")
    func probeAvailabilityConcurrencyDoesNotDeadlock() async {
        await Self.assertNoDeadlock(concurrency: 25, timeoutSeconds: 20) {
            _ = probeAskAvailability()
        }
    }

    @Test("LanguageModelSession(): 25 concurrent constructions all complete")
    func sessionInitConcurrencyDoesNotDeadlock() async {
        await Self.assertNoDeadlock(concurrency: 25, timeoutSeconds: 20) {
            _ = LanguageModelSession()
        }
    }

    @Test("probeAskAvailability() + LanguageModelSession() interleaved: 25 concurrent pairs all complete")
    func interleavedConcurrencyDoesNotDeadlock() async {
        await Self.assertNoDeadlock(concurrency: 25, timeoutSeconds: 20) {
            if case .available = probeAskAvailability() {
                _ = LanguageModelSession()
            }
        }
    }
}
#endif
