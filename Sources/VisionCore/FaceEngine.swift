import Foundation

#if canImport(Vision)
import Vision
import CoreGraphics
import ImageIO

/// One detected face: its source file, index within that image, pixel box, and the
/// feature-print used for similarity.
///
/// `@unchecked Sendable`: `VNFeaturePrintObservation` itself isn't `Sendable` (a mutable
/// Vision class type), so this can't get automatic conformance. It's safe here by
/// construction rather than by the type system: every `FaceInstance` is built entirely
/// inside `detectFacePrints`' `VisionSerialQueue.run` closure (one dedicated background
/// thread), then handed across a single `await` suspension to the calling `Task` — at
/// that point full ownership transfers and nothing else touches it concurrently.
/// `sortFaces`/`findPerson` (this type's only two call sites) both consume `FaceInstance`s
/// from a single sequential `for` loop, never from concurrent `Task`s racing the same
/// instance.
public struct FaceInstance: @unchecked Sendable {
    public let file: String
    public let faceIndex: Int
    public let rect: PixelRect
    let print: VNFeaturePrintObservation
}

/// Local, upload-free face grouping (architecture §4 goal 4).
///
/// Apple exposes no public face-embedding API (`VNGenerateFaceFeaturePrintRequest`
/// does not exist in the macOS 26 SDK — verified 2026-06-16). So we approximate:
/// detect faces (`VNDetectFaceRectanglesRequest`), crop each, and take an image
/// feature print (`VNGenerateImageFeaturePrintRequest`), then cluster by
/// `computeDistance`. Good for grouping near-duplicate/similar faces; less robust
/// than a true face embedding across large pose/lighting changes. Tune `threshold`
/// per dataset — distances are surfaced in the output for calibration.
public enum FaceEngine {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]

    /// Every `.perform()` call this engine makes — both the face-rectangle detection and the
    /// per-face feature-print generation inside `detectFacePrints`' loop below — funnels
    /// through this one dedicated queue (see `VisionSerialQueue`'s type doc for why). Both
    /// calls for one image are wrapped in a *single* `run` closure rather than one `run` per
    /// `.perform()` call: they're already sequential within one image (the feature print
    /// needs the face rectangles first), so there's no correctness difference, and it avoids
    /// N+1 queue hops per image. Tradeoff: a photo with many faces holds this queue for the
    /// full detect-then-print-every-face duration, so a concurrent single-face request queues
    /// behind it — a throughput/fairness cost, not a correctness one.
    private static let visionQueue = VisionSerialQueue(label: "mac-local-vision.face")

    /// Detect faces in one image and return a feature print per face.
    public static func detectFacePrints(path: String) async throws -> [FaceInstance] {
        // Shared oriented loader — applies EXIF orientation so sideways phone photos
        // don't feed rotated faces into the feature print. Pure CoreGraphics decode, no
        // Vision request — doesn't need the queue.
        guard let img = OCREngine.loadOriented(path: path) else {
            throw VisionError.imageLoadFailed(path)
        }
        return try await visionQueue.run {
            let det = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: img, options: [:]).perform([det])

            let W = img.width, H = img.height
            var out: [FaceInstance] = []
            for (i, face) in (det.results ?? []).enumerated() {
                let bb = face.boundingBox // normalized, bottom-left
                // Expand 20% so the crop carries a bit of context (helps the descriptor).
                let mx = bb.size.width * 0.2, my = bb.size.height * 0.2
                let nx = max(0, bb.origin.x - mx)
                let nyBottom = max(0, bb.origin.y - my)
                let nw = min(1 - nx, bb.size.width + 2 * mx)
                let nh = min(1 - nyBottom, bb.size.height + 2 * my)
                let x = Int(nx * Double(W)), w = Int(nw * Double(W))
                let yTop = Int((1 - nyBottom - nh) * Double(H)), h = Int(nh * Double(H))
                guard w > 8, h > 8, let crop = img.cropping(to: CGRect(x: x, y: yTop, width: w, height: h)) else { continue }

                let fp = VNGenerateImageFeaturePrintRequest()
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([fp])
                guard let obs = fp.results?.first else { continue }
                out.append(FaceInstance(file: path, faceIndex: i,
                                        rect: PixelRect(x: x, y: yTop, width: w, height: h), print: obs))
            }
            return out
        }
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = 0
        do { try a.computeDistance(&d, to: b) } catch { return .greatestFiniteMagnitude }
        return d
    }

    static func listImages(_ dir: String) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw VisionError.imageLoadFailed(dir)
        }
        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        return entries
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    /// Cluster all faces in `inputDir` by person. If `outputDir` is given, write
    /// `person_N/` folders of symlinks to the source images.
    public static func sortFaces(inputDir: String, outputDir: String?, threshold: Float) async throws -> YAMLValue {
        let files = try listImages(inputDir)
        var instances: [FaceInstance] = []
        for f in files {
            if let fps = try? await detectFacePrints(path: f) { instances.append(contentsOf: fps) }
        }

        // Greedy clustering: assign to the nearest representative under threshold, else new.
        var clusters: [[FaceInstance]] = []
        for inst in instances {
            var best = -1
            var bestD = Float.greatestFiniteMagnitude
            for (i, c) in clusters.enumerated() {
                let d = distance(inst.print, c[0].print)
                if d < bestD { bestD = d; best = i }
            }
            if best >= 0, bestD < threshold { clusters[best].append(inst) } else { clusters.append([inst]) }
        }

        if let outputDir { try writeClusters(clusters, to: outputDir) }

        let clusterVals = clusters.enumerated().map { idx, members -> YAMLValue in
            let rep = members[0].print
            let mem = members.map { m -> YAMLValue in
                // distance to the cluster representative — surfaced for threshold tuning.
                .dict([("file", .string(m.file)), ("face", .int(m.faceIndex)),
                       ("distance", .double(Double(distance(m.print, rep))))])
            }
            return .dict([("person", .int(idx + 1)), ("count", .int(members.count)), ("members", .array(mem))])
        }
        return .dict([
            ("threshold", .double(Double(threshold))),
            ("images_scanned", .int(files.count)),
            ("faces_found", .int(instances.count)),
            ("cluster_count", .int(clusters.count)),
            ("clusters", .array(clusterVals)),
        ] + (outputDir.map { [("output_dir", YAMLValue.string($0))] } ?? []))
    }

    /// Find images in `inDir` whose faces match the first face in `targetImage`.
    public static func findPerson(targetImage: String, inDir: String, threshold: Float) async throws -> YAMLValue {
        guard let target = try await detectFacePrints(path: targetImage).first else {
            throw VisionError.noFace(targetImage)
        }
        let files = try listImages(inDir)
        var matches: [(file: String, distance: Float)] = []
        for f in files {
            let fps = (try? await detectFacePrints(path: f)) ?? []
            var best = Float.greatestFiniteMagnitude
            for fp in fps { best = min(best, distance(target.print, fp.print)) }
            if best < threshold { matches.append((f, best)) }
        }
        matches.sort { $0.distance < $1.distance }
        let arr = matches.map { YAMLValue.dict([("file", .string($0.file)), ("distance", .double(Double($0.distance)))]) }
        return .dict([
            ("target", .string(targetImage)),
            ("threshold", .double(Double(threshold))),
            ("images_scanned", .int(files.count)),
            ("match_count", .int(matches.count)),
            ("matches", .array(arr)),
        ])
    }

    private static func writeClusters(_ clusters: [[FaceInstance]], to outputDir: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        for (idx, members) in clusters.enumerated() {
            let personDir = (outputDir as NSString).appendingPathComponent("person_\(idx + 1)")
            try fm.createDirectory(atPath: personDir, withIntermediateDirectories: true)
            for (j, m) in members.enumerated() {
                let base = (m.file as NSString).lastPathComponent
                let link = (personDir as NSString).appendingPathComponent("\(j)_\(base)")
                // Idempotent re-run: only replace a pre-existing *symlink*. Never delete a
                // real file that happens to collide (safe-ops — don't destroy what we didn't create).
                if let type = (try? fm.attributesOfItem(atPath: link))?[.type] as? FileAttributeType,
                   type == .typeSymbolicLink {
                    try? fm.removeItem(atPath: link)
                }
                try? fm.createSymbolicLink(atPath: link, withDestinationPath: m.file)
            }
        }
    }
}
#endif
