import Testing
@testable import VisionCore

@Suite("Segmentation asset download policy")
struct SegmentationAssetPolicyTests {
    actor DownloadCounter {
        private var calls = 0

        func run(returning state: SegmentationAssetState) -> SegmentationAssetState {
            calls += 1
            return state
        }

        func value() -> Int { calls }
    }

    @Test("non-ready states never download without explicit opt-in")
    func noImplicitDownload() async {
        let states: [SegmentationAssetState] = [
            .notReady, .downloading, .failed("asset error"),
        ]
        for state in states {
            let counter = DownloadCounter()
            do {
                try await SegmentationAssetPolicy.prepare(
                    initial: state, downloadAssets: false
                ) {
                    await counter.run(returning: .ready)
                }
                Issue.record("expected assetsNotReady for \(state)")
            } catch SegmentationEngineError.assetsNotReady {
                // Expected.
            } catch {
                Issue.record("unexpected error: \(error)")
            }
            #expect(await counter.value() == 0)
        }
    }

    @Test("opt-in downloads once and requires a ready refresh")
    func explicitDownload() async throws {
        let counter = DownloadCounter()
        try await SegmentationAssetPolicy.prepare(
            initial: .notReady, downloadAssets: true
        ) {
            await counter.run(returning: .ready)
        }
        #expect(await counter.value() == 1)
    }
}
