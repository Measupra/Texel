import Foundation
import CoreML
import CoreVideo
import CoreGraphics
import Vision

/// One face, restored by the AI at 512×512, plus where it sits in the image it came from.
struct RestoredFace: @unchecked Sendable {
    /// 512×512 straight RGBA.
    let pixels: [UInt8]
    /// Maps a pixel position in the source image (top-left origin) to the 512×512 face.
    let toFace: CGAffineTransform
    /// Size of the image the face was found in, to scale onto larger results.
    let sourceWidth: Int
    let sourceHeight: Int
}

/// Finds faces with Apple's Vision framework, lines each one up the way GFPGAN expects (eyes, nose
/// and mouth corners on fixed points), lets GFPGAN v1.4 redraw it at 512×512, and later blends the
/// result back into the upscaled image with soft edges.
final class FaceRestorer: @unchecked Sendable {
    static let modelName = "TexelAI-Faces"
    static let size = 512
    /// Where GFPGAN expects the five landmarks in its 512×512 face: eyes, nose tip, mouth corners
    /// (image left before image right).
    private static let template: [CGPoint] = [
        CGPoint(x: 192.98138, y: 239.94708), CGPoint(x: 318.90277, y: 240.1936),
        CGPoint(x: 256.63416, y: 314.01935),
        CGPoint(x: 201.26117, y: 371.41043), CGPoint(x: 313.08905, y: 371.15118),
    ]
    /// Faces with eyes closer than this (in source pixels) are left alone: too little to go on.
    private static let minEyeDistance: CGFloat = 6
    private static let maxFaces = 12

    private let models: AIUpscaler

    init(models: AIUpscaler) { self.models = models }

    var isAvailable: Bool { models.isAvailable(named: FaceRestorer.modelName) }

    // MARK: finding and restoring

    func restore(_ source: CGImage, progress: (String) -> Void, isCancelled: () -> Bool) throws -> [RestoredFace] {
        let W = source.width, H = source.height
        progress("Looking for faces…")
        let landmarks = try FaceRestorer.findFaces(in: source)
        guard !landmarks.isEmpty else { return [] }
        if isCancelled() { throw EngineError.cancelled }

        let model = try models.loadModel(named: FaceRestorer.modelName, status: progress)
        let rgba = FaceRestorer.pixels(of: source)
        let N = FaceRestorer.size

        var pbOut: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, N, N, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { throw AIError.badOutput }

        var faces: [RestoredFace] = []
        for (n, pts) in landmarks.enumerated() {
            if isCancelled() { throw EngineError.cancelled }
            progress(landmarks.count == 1 ? "Restoring the face…" : "Restoring faces · \(n + 1) of \(landmarks.count)")
            let toFace = FaceRestorer.similarity(from: pts, to: FaceRestorer.template)
            let fromFace = toFace.inverted()

            // Cut the face out, lined up on the template.
            CVPixelBufferLockBaseAddress(pb, [])
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            rgba.withUnsafeBufferPointer { s in
                for v in 0..<N {
                    let row = base + v * bpr
                    for u in 0..<N {
                        let p = CGPoint(x: u, y: v).applying(fromFace)
                        let c = FaceRestorer.sample(s, W, H, Float(p.x), Float(p.y))
                        row[u * 4 + 0] = c.2
                        row[u * 4 + 1] = c.1
                        row[u * 4 + 2] = c.0
                        row[u * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            let out = try autoreleasepool { () throws -> [UInt8] in
                let input = try MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: pb)])
                let result = try model.prediction(from: input)
                guard let arr = result.featureValue(for: "restored")?.multiArrayValue, arr.shape.count == 4
                else { throw AIError.badOutput }
                return FaceRestorer.rgba(from: arr, N)
            }
            faces.append(RestoredFace(pixels: out, toFace: toFace, sourceWidth: W, sourceHeight: H))
        }
        return faces
    }

    /// Five landmarks per face (eyes, nose tip, mouth corners), in source pixels, top-left origin.
    private static func findFaces(in image: CGImage) throws -> [[CGPoint]] {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: W, height: H)
        var found: [(area: CGFloat, pts: [CGPoint])] = []
        for face in request.results ?? [] {
            guard let lm = face.landmarks else { continue }
            func points(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                // Vision: bottom-left origin, pixel edges. Here: top-left origin, pixel centres.
                (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x - 0.5, y: H - $0.y - 0.5) }
            }
            func centre(_ p: [CGPoint]) -> CGPoint? {
                guard !p.isEmpty else { return nil }
                return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
            }
            guard let e1 = centre(points(lm.leftPupil)) ?? centre(points(lm.leftEye)),
                  let e2 = centre(points(lm.rightPupil)) ?? centre(points(lm.rightEye)) else { continue }
            let (eyeL, eyeR) = e1.x <= e2.x ? (e1, e2) : (e2, e1)
            let ex = eyeR.x - eyeL.x, ey = eyeR.y - eyeL.y
            let dist = (ex * ex + ey * ey).squareRoot()
            guard dist >= minEyeDistance else { continue }
            let across = CGPoint(x: ex / dist, y: ey / dist)      // left eye → right eye
            let down = CGPoint(x: -across.y, y: across.x)          // towards the mouth

            let lips = points(lm.outerLips)
            guard lips.count >= 2 else { continue }
            let proj = { (p: CGPoint, d: CGPoint) in p.x * d.x + p.y * d.y }
            let mouthL = lips.min { proj($0, across) < proj($1, across) }!
            let mouthR = lips.max { proj($0, across) < proj($1, across) }!

            // The nose tip: the lowest point of the nose ridge, or the middle of the nose outline.
            let crest = points(lm.noseCrest)
            let nose = crest.max { proj($0, down) < proj($1, down) } ?? centre(points(lm.nose))
            guard let nose else { continue }

            let box = face.boundingBox
            found.append((box.width * box.height, [eyeL, eyeR, nose, mouthL, mouthR]))
        }
        return found.sorted { $0.area > $1.area }.prefix(maxFaces).map(\.pts)
    }

    // MARK: putting faces back

    /// Blends restored faces into `image` (which may be a larger version of the image they came from).
    /// `strength` 0…1: how much of the restored face replaces the original.
    static func paste(_ faces: [RestoredFace], onto image: CGImage, strength: Double) -> CGImage {
        guard !faces.isEmpty, strength > 0.001 else { return image }
        let w = image.width, h = image.height
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let info = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        var a = [UInt8](repeating: 255, count: w * h * 4)
        let drew = a.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return image }

        let N = Float(size)
        let amount = Float(min(1, strength))
        for face in faces {
            let kx = Double(w) / Double(face.sourceWidth), ky = Double(h) / Double(face.sourceHeight)
            // Output pixel → source position → face position.
            // (pixel centres line up: source = (X + 0.5) / k − 0.5)
            let t = CGAffineTransform(scaleX: 1 / kx, y: 1 / ky)
                .concatenating(CGAffineTransform(translationX: 0.5 / kx - 0.5, y: 0.5 / ky - 0.5))
                .concatenating(face.toFace)
            // Only visit output pixels inside the face square.
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: CGFloat(N), y: 0),
                           CGPoint(x: 0, y: CGFloat(N)), CGPoint(x: CGFloat(N), y: CGFloat(N))]
                .map { $0.applying(t.inverted()) }
            let x0 = max(0, Int(corners.map(\.x).min()!.rounded(.down)) - 1)
            let x1 = min(w, Int(corners.map(\.x).max()!.rounded(.up)) + 1)
            let y0 = max(0, Int(corners.map(\.y).min()!.rounded(.down)) - 1)
            let y1 = min(h, Int(corners.map(\.y).max()!.rounded(.up)) + 1)
            guard x1 > x0, y1 > y0 else { continue }

            a.withUnsafeMutableBufferPointer { ap in
                face.pixels.withUnsafeBufferPointer { fp in
                    for Y in y0..<y1 {
                        for X in x0..<x1 {
                            let p = CGPoint(x: X, y: Y).applying(t)
                            let u = Float(p.x), v = Float(p.y)
                            // Soft square mask: fades out over the outer part of the face square.
                            let edge = min(min(u, N - 1 - u), min(v, N - 1 - v))
                            guard edge > 16 else { continue }
                            let m = smoothstep(16, 80, edge) * amount
                            let c = sample(fp, size, size, u, v)
                            let i = (Y * w + X) * 4
                            let alpha: Float = hasAlpha ? Float(ap[i + 3]) / 255 : 1
                            let src = (Float(c.0) * alpha, Float(c.1) * alpha, Float(c.2) * alpha)
                            ap[i] = UInt8(max(0, min(255, (Float(ap[i]) + m * (src.0 - Float(ap[i]))).rounded())))
                            ap[i + 1] = UInt8(max(0, min(255, (Float(ap[i + 1]) + m * (src.1 - Float(ap[i + 1]))).rounded())))
                            ap[i + 2] = UInt8(max(0, min(255, (Float(ap[i + 2]) + m * (src.2 - Float(ap[i + 2]))).rounded())))
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(a) as CFData),
              let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return out
    }

    // MARK: helpers

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Least-squares rotation + uniform scale + shift taking `src` points onto `dst`.
    private static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var a: CGFloat = 0, b: CGFloat = 0, norm: CGFloat = 0
        for (p, q) in zip(src, dst) {
            let sx = p.x - ms.x, sy = p.y - ms.y, tx = q.x - md.x, ty = q.y - md.y
            a += sx * tx + sy * ty
            b += sx * ty - sy * tx
            norm += sx * sx + sy * sy
        }
        let c = a / max(norm, 1e-9), s = b / max(norm, 1e-9)   // scale·cos, scale·sin
        let tx = md.x - (c * ms.x - s * ms.y), ty = md.y - (s * ms.x + c * ms.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }

    /// Bilinear sample of straight RGBA pixels at pixel position (x, y), edges repeated.
    private static func sample(_ s: UnsafeBufferPointer<UInt8>, _ W: Int, _ H: Int, _ x: Float, _ y: Float)
        -> (UInt8, UInt8, UInt8) {
        let fx0 = x.rounded(.down), fy0 = y.rounded(.down)
        let fx = x - fx0, fy = y - fy0
        let xa = min(max(Int(fx0), 0), W - 1), xb = min(max(Int(fx0) + 1, 0), W - 1)
        let ya = min(max(Int(fy0), 0), H - 1), yb = min(max(Int(fy0) + 1, 0), H - 1)
        let i00 = (ya * W + xa) * 4, i01 = (ya * W + xb) * 4, i10 = (yb * W + xa) * 4, i11 = (yb * W + xb) * 4
        func ch(_ c: Int) -> UInt8 {
            let top = Float(s[i00 + c]) * (1 - fx) + Float(s[i01 + c]) * fx
            let bot = Float(s[i10 + c]) * (1 - fx) + Float(s[i11 + c]) * fx
            return UInt8(max(0, min(255, (top * (1 - fy) + bot * fy).rounded())))
        }
        return (ch(0), ch(1), ch(2))
    }

    /// The image as straight (un-premultiplied) 8-bit RGBA in sRGB.
    private static func pixels(of image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Void in
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// Model output (1×3×N×N, 0…255) as straight RGBA.
    private static func rgba(from arr: MLMultiArray, _ N: Int) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: N * N * 4)
        let st = arr.strides.map { $0.intValue }
        if arr.dataType == .float32 {
            let p = arr.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<N {
                for x in 0..<N {
                    let si = y * st[2] + x * st[3], di = (y * N + x) * 4
                    for c in 0..<3 { out[di + c] = UInt8(max(0, min(255, p[c * st[1] + si].rounded()))) }
                }
            }
        } else {
            for y in 0..<N {
                for x in 0..<N {
                    let di = (y * N + x) * 4
                    for c in 0..<3 {
                        let v = arr[[0, c, y, x] as [NSNumber]].floatValue
                        out[di + c] = UInt8(max(0, min(255, v.rounded())))
                    }
                }
            }
        }
        return out
    }
}
