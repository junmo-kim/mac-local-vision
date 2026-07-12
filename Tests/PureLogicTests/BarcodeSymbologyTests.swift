#if canImport(Vision)
import Testing
import Vision
@testable import VisionCore

/// Pure lookup logic — no Vision session, just static-constant table access, so this
/// belongs in PureLogicTests (tier ①) alongside GeometryTests/ClampedRasterSizeTests.
@Suite("BarcodeEngine — symbology name mapping (pure lookup, no Vision session)")
struct BarcodeSymbologyTests {
    @Test("every known name round-trips through VNBarcodeSymbology and back")
    func roundTrip() throws {
        for name in BarcodeEngine.allSymbologyNames {
            let sym = try #require(BarcodeEngine.symbology(forName: name))
            #expect(BarcodeEngine.name(for: sym) == name)
        }
    }

    @Test("qr resolves to VNBarcodeSymbology.qr")
    func qrMapping() {
        #expect(BarcodeEngine.symbology(forName: "qr") == .qr)
    }

    @Test("code128 resolves to VNBarcodeSymbology.code128")
    func code128Mapping() {
        #expect(BarcodeEngine.symbology(forName: "code128") == .code128)
    }

    @Test("unknown name returns nil")
    func unknownNameReturnsNil() {
        #expect(BarcodeEngine.symbology(forName: "not-a-real-symbology") == nil)
    }

    @Test("exactly 24 known symbologies (SDK-verified set, plan §2.3)")
    func countIsTwentyFour() {
        #expect(BarcodeEngine.allSymbologyNames.count == 24)
    }

    @Test("resolveSymbologies maps known names to VNBarcodeSymbology values in order")
    func resolvesKnownNames() throws {
        let resolved = try BarcodeEngine.resolveSymbologies(["qr", "code128", "ean13"])
        #expect(resolved == [.qr, .code128, .ean13])
    }

    @Test("resolveSymbologies throws bad_request/unknown_symbology for an unrecognized name")
    func throwsOnUnknownName() {
        do {
            _ = try BarcodeEngine.resolveSymbologies(["qr", "not-real"])
            Issue.record("expected throw")
        } catch {
            let se = error as? ServiceError
            #expect(se?.name == "bad_request")
            #expect(se?.reason == "unknown_symbology")
            #expect(se?.detail == "not-real")
        }
    }

    @Test("resolveSymbologies of an empty list returns an empty list")
    func emptyListResolves() throws {
        #expect(try BarcodeEngine.resolveSymbologies([]) == [])
    }
}
#endif
