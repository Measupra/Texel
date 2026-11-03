import Foundation
import CoreGraphics
import Vision

/// What Auto Fix found in an image.
struct ImageReport: Sendable {
    /// How many times a pixelated image was blown up (1 = not pixelated).
    var pixelated = 1
    /// Estimated noise, as a standard deviation in 0…255 levels. Clean photos: under 2.
    var noise: Float = 0
    /// Edge steepness: about 0.5 or more for sharp images, down to 0.33 for very blurry ones.
    var sharpness: Float = 0.5
    /// JPEG 8×8 block strength: under 0.12 clean, 0.3+ visible blocks, 0.8+ heavy.
    var jpeg: Float = 0
    var faces = 0
    /// Width of the largest face, in image pixels.
    var largestFace: CGFloat = 0
    var drawing = false
    var dark = false, bright = false, lowContrast = false, colourCast = false

    /// 0 (sharp) … 1 (very blurry)
    var blur: Float { max(0, min(1, (0.50 - sharpness) / 0.15)) }
    /// 0 (clean) … 1 (very noisy)
    var noisiness: Float { max(0, min(1, (noise - 1.8) / 5)) }
    /// 0 (no JPEG blocks) … 1 (heavy)
    var blockiness: Float { max(0, min(1, (jpeg - 0.15) / 0.5)) }

    /// Plain-language list of what's wrong (empty if nothing is).
    var problems: [String] {
        var p: [String] = []
        if pixelated > 1 { p.append("pixelated") }
        if blur > 0.25 { p.append(blur > 0.65 ? "very blurry" : "a little blurry") }
        if noisiness > 0.15 { p.append("grainy") }
        if blockiness > 0.15 { p.append("JPEG blocks") }
        if dark { p.append("dark") }
        if bright { p.append("washed out") }
        if lowContrast && !bright { p.append("flat contrast") }
        if colourCast { p.append("colour cast") }
        return p
    }
}

/// The settings Auto Fix chose.
struct AutoPlan: Sendable {
    var model: AIModel
    var scale: Double
    var strength: Double
    var detail: Double, smooth: Double, sharpen: Double
    var restoreFaces: Bool, faceStrength: Double
    var autoEnhance: Bool, enhanceAmount: Double
    var summary: String
}

/// Looks at an image and works out what's wrong with it, using measurements calibrated on photos
/// with known amounts of blur, noise, JPEG compression and pixelation.
enum ImageAnalyzer {

    static func analyze(_ image: CGImage) -> ImageReport {
        var r = ImageReport()
        let W = image.width, H = image.height

        // 1. Fine-detail measurements on an unscaled centre crop (scaling would hide noise and blur).
        let align = 48
        let cw = min(W, 1056) / align * align, ch = min(H, 1056) / align * align
        if cw >= 192, ch >= 192 {
            let x0 = (W - cw) / 2 / align * align, y0 = (H - ch) / 2 / align * align
            if let crop = image.cropping(to: CGRect(x: x0, y: y0, width: cw, height: ch)),
               let rgba = rgbaPixels(crop, cw, ch) {
                r.pixelated = AIUpscaler.effectiveDownscale(rgba, width: cw, height: ch)
                var Y = [Float](repeating: 0, count: cw * ch)
                for i in 0..<(cw * ch) {
                    Y[i] = (Float(rgba[i * 4]) * 77 + Float(rgba[i * 4 + 1]) * 150 + Float(rgba[i * 4 + 2]) * 29) / 256
                }
                if r.pixelated == 1 {
                    r.noise = noise(Y, cw, ch)
                    r.sharpness = sharpness(Y, cw, ch)
                    r.jpeg = jpegBlocks(Y, cw, ch)
                }
            }
        }

        // 2. Light and colour, on a small copy of the whole image.
        let k = min(1, 256 / Double(max(W, H)))
        let sw = max(1, Int(Double(W) * k)), sh = max(1, Int(Double(H) * k))
        if let small = rgbaPixels(image, sw, sh) {
            var hist = [Int](repeating: 0, count: 256)
            var sumRG: Double = 0, sumBG: Double = 0, mids = 0
            for i in 0..<(sw * sh) {
                let R = Int(small[i * 4]), G = Int(small[i * 4 + 1]), B = Int(small[i * 4 + 2])
                let y = (R * 77 + G * 150 + B * 29) >> 8
                hist[y] += 1
                if y > 60 && y < 200 { sumRG += Double(R - G); sumBG += Double(B - G); mids += 1 }
            }
            let n = sw * sh
            func percentile(_ p: Double) -> Int {
                var acc = 0
                for v in 0..<256 { acc += hist[v]; if Double(acc) >= p * Double(n) { return v } }
                return 255
            }
            let mean = Double((0..<256).reduce(0) { $0 + $1 * hist[$1] }) / Double(n)
            let lo = percentile(0.02), hi = percentile(0.98)
            r.dark = mean < 70 || hi < 150
            r.bright = mean > 195 && lo > 80
            r.lowContrast = hi - lo < 140
            if mids > n / 10 {
                let rg = sumRG / Double(mids), bg = sumBG / Double(mids)
                r.colourCast = (rg * rg + bg * bg).squareRoot() > 22
            }
        }

        // 3. Faces, and whether it's a drawing (Apple's built-in classifiers).
        // Run separately, so one failing (the classifier can be unavailable, e.g. in the Simulator)
        // doesn't lose the other.
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let classify = VNClassifyImageRequest()
        try? handler.perform([faces])
        try? handler.perform([classify])
        let found = faces.results ?? []
        r.faces = found.count
        r.largestFace = found.map { $0.boundingBox.width * CGFloat(W) }.max() ?? 0
        let drawingWords = ["cartoon", "illustration", "drawing", "anime", "comic", "animation", "clip_art"]
        r.drawing = (classify.results ?? []).contains { obs in
            obs.confidence > 0.4 && drawingWords.contains { obs.identifier.lowercased().contains($0) }
        }
        return r
    }

    static func plan(for r: ImageReport, width: Int, height: Int) -> AutoPlan {
        let blur = Double(r.blur), noisy = Double(r.noisiness), blocky = Double(r.blockiness)
        let dirt = max(noisy, blocky)
        let issues = max(blur, dirt, r.pixelated > 1 ? 1 : 0)

        // Size: keep it ("identical, but better"), except small images, which are worth enlarging.
        let longSide = max(width, height)
        let scale: Double = (r.pixelated == 1 && longSide < 1000) ? 2 : 1

        // How much of the AI to use: a clean image only needs a light touch, so it stays faithful.
        let strength = 0.6 + 0.4 * issues
        let detail = r.drawing ? 0.1 : 0.3 * (1 - dirt)
        let smooth = 0.1 + 0.5 * dirt
        let sharpen = max(0.1, 0.15 + 0.45 * blur - 0.2 * noisy)

        // Faces: small or blurry faces need more help; large sharp ones get a light touch so the
        // person still looks exactly like themselves. Never on drawings (it would make them real).
        let faces = r.faces > 0 && !r.drawing
        var faceStrength = r.largestFace < 96 ? 0.8 : r.largestFace < 256 ? 0.65 : 0.45
        faceStrength = min(0.9, faceStrength + 0.2 * blur)

        let lightIssues = [r.dark, r.bright, r.lowContrast, r.colourCast].filter { $0 }.count
        let enhanceAmount = min(0.75, 0.3 + 0.15 * Double(lightIssues))

        var found = r.problems
        if r.faces > 0 { found.append(r.faces == 1 ? "1 face" : "\(r.faces) faces") }
        if r.drawing { found.append("drawing") }
        let what = found.isEmpty ? "Looks clean: light touch" : found.joined(separator: " · ").capitalizedFirst
        let size = scale == 1 ? "same size" : "2× (small image)"
        return AutoPlan(model: r.drawing ? .anime : .photo, scale: scale, strength: strength,
                        detail: detail, smooth: smooth, sharpen: sharpen,
                        restoreFaces: faces, faceStrength: faceStrength,
                        autoEnhance: true, enhanceAmount: enhanceAmount,
                        summary: "\(what) → \(size)")
    }

    // MARK: measurements

    private static func rgbaPixels(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = (w == image.width && h == image.height) ? .none : .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    /// Sobel gradient size (|gx| + |gy|) for interior pixels, indexed like the image.
    private static func gradient(_ Y: [Float], _ w: Int, _ h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (Y[i - w + 1] + 2 * Y[i + 1] + Y[i + w + 1]) - (Y[i - w - 1] + 2 * Y[i - 1] + Y[i + w - 1])
                let gy = (Y[i + w - 1] + 2 * Y[i + w] + Y[i + w + 1]) - (Y[i - w - 1] + 2 * Y[i - w] + Y[i - w + 1])
                g[i] = abs(gx) + abs(gy)
            }
        }
        return g
    }

    /// Value below which fraction `p` of the interior values fall.
    private static func percentile(_ v: [Float], _ w: Int, _ h: Int, _ p: Float) -> Float {
        var hist = [Int](repeating: 0, count: 2048)
        var n = 0
        for y in 1..<(h - 1) { for x in 1..<(w - 1) { hist[min(2047, Int(v[y * w + x]))] += 1; n += 1 } }
        var acc = 0
        for b in 0..<2048 { acc += hist[b]; if Float(acc) >= p * Float(n) { return Float(b) } }
        return 2047
    }

    /// Immerkær's noise estimate, measured on the flatter half of the image so texture doesn't count.
    private static func noise(_ Y: [Float], _ w: Int, _ h: Int) -> Float {
        let g = gradient(Y, w, h)
        let limit = percentile(g, w, h, 0.5)
        var sum: Double = 0, n = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard g[i] <= limit else { continue }
                let l = (Y[i - w - 1] - 2 * Y[i - w] + Y[i - w + 1]) - 2 * (Y[i - 1] - 2 * Y[i] + Y[i + 1])
                      + (Y[i + w - 1] - 2 * Y[i + w] + Y[i + w + 1])
                sum += Double(abs(l)); n += 1
            }
        }
        guard n > 0 else { return 0 }
        return Float((Double.pi / 2).squareRoot() / 6 * sum / Double(n))
    }

    /// On the strongest edges: how much of a 3-pixel step happens within one pixel.
    private static func sharpness(_ Y: [Float], _ w: Int, _ h: Int) -> Float {
        let g = gradient(Y, w, h)
        let limit = percentile(g, w, h, 0.97)
        var sum: Double = 0, n = 0
        for y in 1..<(h - 1) {
            for x in 0..<(w - 3) {
                guard g[y * w + x + 1] >= limit else { continue }
                let d3 = abs(Y[y * w + x + 3] - Y[y * w + x])
                guard d3 > 20 else { continue }
                sum += Double(abs(Y[y * w + x + 1] - Y[y * w + x]) / d3); n += 1
            }
        }
        return n < 50 ? 0.5 : Float(sum / Double(n))
    }

    /// Extra change across JPEG's 8-pixel block borders compared with everywhere else.
    private static func jpegBlocks(_ Y: [Float], _ w: Int, _ h: Int) -> Float {
        var col = [Double](repeating: 0, count: 8), row = [Double](repeating: 0, count: 8)
        for y in 0..<h {
            for x in 0..<(w - 1) { col[x % 8] += Double(abs(Y[y * w + x + 1] - Y[y * w + x])) }
        }
        for y in 0..<(h - 1) {
            var acc: Double = 0
            for x in 0..<w { acc += Double(abs(Y[(y + 1) * w + x] - Y[y * w + x])) }
            row[y % 8] += acc
        }
        func ratio(_ ph: [Double]) -> Double {
            let others = (ph.reduce(0, +) - ph[7]) / 7
            return others > 0 ? ph[7] / others - 1 : 0
        }
        return Float(max(0, min(ratio(col), ratio(row))))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
