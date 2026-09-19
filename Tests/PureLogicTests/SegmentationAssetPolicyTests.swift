import Testing
import Foundation
import Vision
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

    @Test("unknown status permits local inference without downloading")
    func unknownStatusDoesNotBlockLocalAssets() async throws {
        let counter = DownloadCounter()
        try await SegmentationAssetPolicy.prepare(
            initial: .notReady, downloadAssets: false
        ) {
            await counter.run(returning: .ready)
        }
        #expect(await counter.value() == 0)
    }

    @Test("unavailable states never download without explicit opt-in")
    func noImplicitDownload() async {
        let states: [SegmentationAssetState] = [
            .downloading, .failed("asset error"),
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

    @Test("ready assets and later calls never reuse download permission")
    func noRetainedConsent() async throws {
        let counter = DownloadCounter()
        for (state, consent) in [(SegmentationAssetState.ready, true), (.notReady, true), (.notReady, false)] {
            try await SegmentationAssetPolicy.prepare(initial: state, downloadAssets: consent) {
                await counter.run(returning: .ready)
            }
        }
        #expect(await counter.value() == 1)
    }

    @Test("download failure and incomplete preparation remain unavailable")
    func unsuccessfulDownload() async {
        do {
            try await SegmentationAssetPolicy.prepare(initial: .notReady, downloadAssets: true) {
                throw NSError(domain: "test-download", code: 1)
            }
            Issue.record("expected assetDownloadFailed")
        } catch SegmentationEngineError.assetDownloadFailed {
        } catch {
            Issue.record("unexpected download error: \(error)")
        }
        do {
            try await SegmentationAssetPolicy.prepare(initial: .notReady, downloadAssets: true) { .downloading }
            Issue.record("expected assetsNotReady")
        } catch SegmentationEngineError.assetsNotReady {
        } catch {
            Issue.record("unexpected preparation error: \(error)")
        }
    }

    @Test("diagnostics distinguish unknown, downloading, and failed assets")
    func diagnosticStates() {
        #expect(SegmentationAssetState.notReady.diagnosticStatus == "unknown: assets_not_ready")
        #expect(SegmentationAssetState.downloading.diagnosticStatus == "unavailable: assets_downloading")
        #expect(SegmentationAssetState.failed("error").diagnosticStatus == "unavailable: asset_error")
        #expect(SegmentationAssetState.ready.diagnosticStatus == "available")
        #expect(SegmentationAssetState.needsMacOS27.diagnosticStatus == "unavailable: needs_macos_27")
    }

    @available(macOS 27, *)
    @Test("missing and corrupted native resources request explicit asset recovery")
    func missingResources() {
        for code in [VNErrorCode.resourceUnavailable, .resourceCorrupted] {
            let error = NSError(domain: VNErrorDomain, code: code.rawValue)
            guard case .assetsNotReady = SegmentationEngine.requestError(error) else {
                Issue.record("expected asset recovery for \(code)"); continue
            }
        }
        let unrelated = NSError(domain: "other", code: VNErrorCode.resourceUnavailable.rawValue)
        guard case .requestFailed = SegmentationEngine.requestError(unrelated) else {
            Issue.record("unrelated errors must remain request failures"); return
        }
        let invalidImage = NSError(domain: VNErrorDomain, code: VNErrorCode.invalidImage.rawValue)
        guard case .requestFailed = SegmentationEngine.requestError(invalidImage) else {
            Issue.record("invalid image must not be misreported as missing assets"); return
        }
    }
}
