import Foundation
import CoreML
import CoreVideo
import CoreGraphics

/// The bundled Real-ESRGAN models (converted to Core ML, 256×256 tiles in, 1024×1024 out).
enum AIModel: String, CaseIterable {
    case photo = "TexelAI-Photo"
    case general = "TexelAI-General"
    case anime = "TexelAI-Anime"

    var title: String {
        switch self {
        case .photo: return "Photo · best quality"
        case .general: return "General · fast"
        case .anime: return "Anime & illustration"
        }
    }

    var shortTitle: String {
        switch self {
        case .photo: return "Photo"
        case .general: return "General"
        case .anime: return "Anime"
        }
    }

    var summary: String {
        switch self {
        case .photo: return "Real-ESRGAN x4plus. The largest model: rebuilds fine texture and removes JPEG noise. Slowest."
        case .general: return "Real-ESRGAN general v3 with medium denoise. Several times faster than Photo and keeps natural texture."
        case .anime: return "Real-ESRGAN anime 6B. Keeps flat colours and clean line art."
        }
    }
}

enum AIError: LocalizedError {
    case missing(String)
    case badOutput
    case tooLarge(Int, Int)

    var errorDescription: String? {
        switch self {
        case .missing(let n):
            return "The AI model \(n) isn't inside the app. Rebuild from the folder that has the Models folder."
        case .badOutput:
            return "The AI model returned an unexpected result."
        case .tooLarge(let w, let h):
            return "\(w) × \(h) is larger than AI mode allows on this device (\(AIUpscaler.maxOutputPixels / 1_000_000) MP). Pick a smaller scale."
        }
    }
}

final class AIUpscaler: @unchecked Sendable {
    static let tile = 256          // model input size
    static let pad = 16            // overlap thrown away at tile edges, hides seams
    static let factor = 4          // model scale
    static let maxSide = 16384
    #if os(iOS)
    static let maxOutputPixels = 64_000_000
    #else
    static let maxOutputPixels = 268_000_000
    #endif

    private var cache: [String: MLModel] = [:]
    private let lock = NSLock()

    private enum Location { case compiled(URL), package(URL) }

    func isAvailable(_ m: AIModel) -> Bool { location(m.rawValue) != nil }
    func isAvailable(named name: String) -> Bool { location(name) != nil }

    private func location(_ name: String) -> Location? {
        let b = Bundle.main
        if let u = b.url(forResource: name, withExtension: "mlmodelc") { return .compiled(u) }
        if let u = b.url(forResource: name, withExtension: "mlpackage") { return .package(u) }
        if let u = b.url(forResource: name, withExtension: "mlpackage", subdirectory: "Models") { return .package(u) }
        #if os(macOS)
        // Beside the executable or in ./Models, for runs outside the .app bundle.
        let fm = FileManager.default
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        for dir in [exeDir, cwd.appendingPathComponent("Models")] {
            let u = dir.appendingPathComponent(name + ".mlpackage")
            if fm.fileExists(atPath: u.path) { return .package(u) }
        }
        #endif
        return nil
    }

    /// Loads the model, compiling it once (cached in Application Support) if it ships uncompiled.
    private func load(_ m: AIModel, status: (String) -> Void) throws -> MLModel {
        try loadModel(named: m.rawValue, status: status)
    }

    /// Loads any bundled model by name (the upscalers, or the face restorer).
    func loadModel(named name: String, status: (String) -> Void) throws -> MLModel {
        lock.lock()
        if let cached = cache[name] { lock.unlock(); return cached }
        lock.unlock()

        guard let loc = location(name) else { throw AIError.missing(name) }
        let compiledURL: URL
        switch loc {
        case .compiled(let u):
            compiledURL = u
        case .package(let src):
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
                .appendingPathComponent("Texel/CompiledModels", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            // Key the compiled copy on the package's manifest, which changes whenever the model is
            // replaced (the package folder's own date doesn't when files inside are swapped).
            let manifest = src.appendingPathComponent("Manifest.json")
            let attrs = (try? fm.attributesOfItem(atPath: manifest.path)) ?? (try? fm.attributesOfItem(atPath: src.path))
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            // Stable FNV-1a hash (Swift's own hashValue changes on every launch).
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in (try? Data(contentsOf: manifest)) ?? Data() {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            let stamp = "\(String(hash, radix: 16))-\(size)"
            let target = support.appendingPathComponent("\(name)-\(stamp).mlmodelc")
            if !fm.fileExists(atPath: target.path) {
                status("Preparing the AI model (first use only)…")
                let tmp = try MLModel.compileModel(at: src)
                try? fm.removeItem(at: target)
                do { try fm.moveItem(at: tmp, to: target) } catch { try fm.copyItem(at: tmp, to: target) }
            }
            compiledURL = target
        }
        status("Loading the AI model…")
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let model = try MLModel(contentsOf: compiledURL, configuration: cfg)
        lock.lock()
        cache[name] = model
        lock.unlock()
        return model
    }

    private static func positions(_ n: Int) -> [Int] {
        if n <= tile { return [0] }
        var p: [Int] = []
        var x = 0
        while x + tile < n {
            p.append(x)
            x += tile - 2 * pad
        }
        p.append(n - tile)
        return p
    }

    /// Sample positions and weights in 4×-space for each output pixel along one axis.
    /// Shrinking (ratio ≥ 1) averages the pixels the output pixel covers; enlarging past 4×
    /// interpolates linearly.
    private static func taps(count n: Int, hrCount: Int) -> [[(Int, Float)]] {
        let r = Double(hrCount) / Double(n)
        var all: [[(Int, Float)]] = []
        all.reserveCapacity(n)
        for x in 0..<n {
            var t: [(Int, Float)] = []
            if r >= 1 {
                let a = Double(x) * r, b = a + r
                var i = Int(a.rounded(.down))
                var sum = 0.0
                while Double(i) < b {
                    let w = min(b, Double(i + 1)) - max(a, Double(i))
                    if w > 1e-6 { t.append((min(max(i, 0), hrCount - 1), Float(w))); sum += w }
                    i += 1
                }
                t = t.map { ($0.0, Float(Double($0.1) / sum)) }
            } else {
                let p = (Double(x) + 0.5) * r - 0.5
                let i0 = Int(p.rounded(.down))
                let f = p - Double(i0)
                t = [(min(max(i0, 0), hrCount - 1), Float(1 - f)), (min(max(i0 + 1, 0), hrCount - 1), Float(f))]
            }
            all.append(t)
        }
        return all
    }

    // MARK: low-resolution detection

    /// How many times a pixelated image was blown up (1 = a normal image, leave it alone).
    ///
    /// Only blocky enlargements count: there, every change between neighbouring pixels sits on a
    /// regular grid, one column (and row) in every f. Smooth images, renders and photos — even soft
    /// or smoothly enlarged ones — have no such grid and are never shrunk, because shrinking them
    /// throws away real detail. The old test averaged a reconstruction error over the whole image,
    /// which large smooth areas (skies, studio backdrops) could pass on their own.
    static func effectiveDownscale(_ rgba: [UInt8], width W: Int, height H: Int) -> Int {
        let align = 48
        let cw = min(W, 1536) / align * align, ch = min(H, 1536) / align * align
        guard cw >= 192, ch >= 192 else { return 1 }
        let x0 = (W - cw) / 2 / align * align, y0 = (H - ch) / 2 / align * align
        var Y = [Float](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                let i = ((y0 + y) * W + (x0 + x)) * 4
                Y[y * cw + x] = (Float(rgba[i]) * 77 + Float(rgba[i + 1]) * 150 + Float(rgba[i + 2]) * 29) / 256
            }
        }
        // Mean change between neighbouring pixels, per column and per row.
        var colDiff = [Float](repeating: 0, count: cw - 1)
        var rowDiff = [Float](repeating: 0, count: ch - 1)
        for y in 0..<ch {
            let r = y * cw
            for x in 0..<(cw - 1) { colDiff[x] += abs(Y[r + x + 1] - Y[r + x]) }
            if y < ch - 1 {
                var acc: Float = 0
                for x in 0..<cw { acc += abs(Y[r + cw + x] - Y[r + x]) }
                rowDiff[y] = acc
            }
        }
        var best = 1
        for f in [2, 3, 4, 6, 8, 12, 16] where cw / f >= 24 && ch / f >= 24 {
            if gridRatio(colDiff, f) < 0.5 && gridRatio(rowDiff, f) < 0.5
                && reconstructionError(Y, cw, ch, f) < 3.0 {
                best = f
            }
        }
        return best
    }

    /// Folds per-position changes onto a grid of period f. Returns the strongest off-grid phase
    /// relative to the on-grid one: near 0 for blocky images, near 1 for everything else.
    private static func gridRatio(_ d: [Float], _ f: Int) -> Float {
        let n = d.count / f * f
        guard n >= f else { return 1 }
        var phase = [Float](repeating: 0, count: f)
        for i in 0..<n { phase[i % f] += d[i] }
        guard let k = phase.indices.max(by: { phase[$0] < phase[$1] }), phase[k] > 1e-6 else { return 1 }
        var other: Float = 0
        for i in 0..<f where i != k { other = max(other, phase[i]) }
        return other / phase[k]
    }

    private static func reconstructionError(_ Y: [Float], _ w: Int, _ h: Int, _ f: Int) -> Float {
        let sw = w / f, sh = h / f
        var small = [Float](repeating: 0, count: sw * sh)
        let inv = 1 / Float(f * f)
        for sy in 0..<sh {
            for sx in 0..<sw {
                var acc: Float = 0
                for dy in 0..<f {
                    let row = (sy * f + dy) * w + sx * f
                    for dx in 0..<f { acc += Y[row + dx] }
                }
                small[sy * sw + sx] = acc * inv
            }
        }
        var errNear: Float = 0, errBil: Float = 0
        let ff = Float(f)
        for y in 0..<(sh * f) {
            let py = (Float(y) + 0.5) / ff - 0.5
            let ya = min(max(Int(py.rounded(.down)), 0), sh - 1)
            let yb = min(ya + 1, sh - 1)
            let fy = min(max(py - Float(ya), 0), 1)
            let yn = y / f
            for x in 0..<(sw * f) {
                let v = Y[y * w + x]
                errNear += abs(v - small[yn * sw + x / f])
                let px = (Float(x) + 0.5) / ff - 0.5
                let xa = min(max(Int(px.rounded(.down)), 0), sw - 1)
                let xb = min(xa + 1, sw - 1)
                let fx = min(max(px - Float(xa), 0), 1)
                let top = small[ya * sw + xa] * (1 - fx) + small[ya * sw + xb] * fx
                let bot = small[yb * sw + xa] * (1 - fx) + small[yb * sw + xb] * fx
                errBil += abs(v - (top * (1 - fy) + bot * fy))
            }
        }
        let n = Float(sw * f * sh * f)
        return min(errNear, errBil) / n
    }

    /// Averages each f×f block of pixels into one.
    static func boxShrink(_ rgba: [UInt8], width W: Int, height H: Int, by f: Int) -> [UInt8] {
        let w = W / f, h = H / f
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let n = f * f
        for y in 0..<h {
            for x in 0..<w {
                var r = 0, g = 0, b = 0
                for dy in 0..<f {
                    var i = ((y * f + dy) * W + x * f) * 4
                    for _ in 0..<f {
                        r += Int(rgba[i]); g += Int(rgba[i + 1]); b += Int(rgba[i + 2])
                        i += 4
                    }
                }
                let o = (y * w + x) * 4
                out[o] = UInt8(r / n); out[o + 1] = UInt8(g / n); out[o + 2] = UInt8(b / n)
            }
        }
        return out
    }

    // MARK: upscaling

    struct Result {
        /// The AI output at the requested size.
        let image: CGImage
        /// What fine detail can safely be borrowed from: the original, or for an image that had been
        /// enlarged before, its real-resolution version (so its blocky edges don't come back).
        let detailSource: CGImage
        /// 1 for a normal photo; otherwise how much the source had been enlarged before.
        let rebuiltFrom: Int
    }

    func upscale(_ src: SourceImage, model m: AIModel, outW: Int, outH: Int,
                 progress: @escaping (EngineProgress) -> Void,
                 isCancelled: @escaping () -> Bool) throws -> CGImage {
        try upscaleDetailed(src, model: m, outW: outW, outH: outH, progress: progress, isCancelled: isCancelled).image
    }

    func upscaleDetailed(_ src: SourceImage, model m: AIModel, outW: Int, outH: Int,
                         progress: @escaping (EngineProgress) -> Void,
                         isCancelled: @escaping () -> Bool) throws -> Result {
        let W0 = src.width, H0 = src.height
        guard outW <= AIUpscaler.maxSide, outH <= AIUpscaler.maxSide,
              outW * outH <= AIUpscaler.maxOutputPixels else { throw AIError.tooLarge(outW, outH) }

        progress(EngineProgress(stage: "Loading the AI model…", fraction: 0))
        let model = try load(m) { progress(EngineProgress(stage: $0, fraction: 0)) }
        if isCancelled() { throw EngineError.cancelled }

        // 1. Source as 8-bit straight RGBA.
        var rgba = [UInt8](repeating: 0, count: W0 * H0 * 4)
        let drewOK: Bool = rgba.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: W0, height: H0, bitsPerComponent: 8,
                                      bytesPerRow: W0 * 4, space: src.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(src.cgImage, in: CGRect(x: 0, y: 0, width: W0, height: H0))
            return true
        }
        guard drewOK else { throw AIError.badOutput }

        var alpha: [UInt8] = []
        if src.hasAlpha {
            alpha = [UInt8](repeating: 255, count: W0 * H0)
            for i in 0..<(W0 * H0) {
                let a = rgba[i * 4 + 3]
                alpha[i] = a
                if a > 0 && a < 255 {
                    let s = 255.0 / Double(a)
                    for c in 0..<3 { rgba[i * 4 + c] = UInt8(min(255, (Double(rgba[i * 4 + c]) * s).rounded())) }
                }
            }
        }

        // 2. An image that was enlarged before holds far less detail than its size suggests. Shrink it
        //    back to its real resolution so the AI sees genuine pixels, not big soft squares.
        progress(EngineProgress(stage: "Checking the photo's real resolution…", fraction: 0.005))
        let rebuilt = AIUpscaler.effectiveDownscale(rgba, width: W0, height: H0)
        var cur = rgba, W = W0, H = H0
        if rebuilt > 1 {
            cur = AIUpscaler.boxShrink(rgba, width: W0, height: H0, by: rebuilt)
            W = W0 / rebuilt
            H = H0 / rebuilt
        }
        let detailSource: CGImage
        if rebuilt > 1, let img = AIUpscaler.makeImage(Data(cur), W, H, alpha: false, space: src.colorSpace) {
            detailSource = img
        } else {
            detailSource = src.cgImage
        }

        // 3. Plan AI passes. One pass enlarges up to 4×. Above that (8× asked for, or a photo
        //    rebuilt from a much smaller size), a first pass makes an image a quarter of the final
        //    size and a second AI pass enlarges that by exactly 4×, so every step is real AI detail.
        var sizes: [(Int, Int)] = []
        let f4 = AIUpscaler.factor
        if W * f4 >= outW && H * f4 >= outH {
            sizes = [(outW, outH)]
        } else {
            let mw = min(W * f4, (outW + f4 - 1) / f4), mh = min(H * f4, (outH + f4 - 1) / f4)
            sizes = [(max(W, mw), max(H, mh)), (outW, outH)]
        }
        var inputs: [(Int, Int)] = [(W, H)]
        for s in sizes.dropLast() { inputs.append(s) }
        let tileCounts = inputs.map { AIUpscaler.positions(max($0.0, AIUpscaler.tile)).count * AIUpscaler.positions(max($0.1, AIUpscaler.tile)).count }
        let totalTiles = Double(tileCounts.reduce(0, +))
        var doneTiles = 0.0

        var out = Data()
        for (i, (pw, ph)) in sizes.enumerated() {
            let (iw, ih) = inputs[i]
            let passLabel: String
            if rebuilt > 1 {
                passLabel = sizes.count > 1 ? "Rebuilding from \(W)×\(H) · pass \(i + 1) of \(sizes.count)" : "Rebuilding from \(W)×\(H)"
            } else {
                passLabel = sizes.count > 1 ? "AI upscaling · pass \(i + 1) of \(sizes.count)" : "AI upscaling"
            }
            let base = doneTiles
            out = try runTiles(model: model, rgba: cur, width: iw, height: ih, outW: pw, outH: ph,
                               isCancelled: isCancelled) { done, total in
                progress(EngineProgress(stage: "\(passLabel) · tile \(done) of \(total)",
                                        fraction: 0.01 + 0.96 * (base + Double(done)) / totalTiles))
            }
            doneTiles += Double(tileCounts[i])
            if i < sizes.count - 1 { cur = [UInt8](out) }
        }

        // 4. Alpha, if any, is resized smoothly on its own from the original.
        if src.hasAlpha {
            let kx = Double(outW) / Double(W0), ky = Double(outH) / Double(H0)
            out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Void in
                let o = raw.bindMemory(to: UInt8.self)
                for Y in 0..<outH {
                    let sy = (Double(Y) + 0.5) / ky - 0.5
                    let y0 = max(0, min(H0 - 1, Int(sy.rounded(.down))))
                    let y1 = min(H0 - 1, y0 + 1)
                    let fy = max(0, min(1, sy - Double(y0)))
                    for X in 0..<outW {
                        let sx = (Double(X) + 0.5) / kx - 0.5
                        let x0 = max(0, min(W0 - 1, Int(sx.rounded(.down))))
                        let x1 = min(W0 - 1, x0 + 1)
                        let fx = max(0, min(1, sx - Double(x0)))
                        let a = Double(alpha[y0 * W0 + x0]) * (1 - fx) * (1 - fy) + Double(alpha[y0 * W0 + x1]) * fx * (1 - fy)
                              + Double(alpha[y1 * W0 + x0]) * (1 - fx) * fy + Double(alpha[y1 * W0 + x1]) * fx * fy
                        o[(Y * outW + X) * 4 + 3] = UInt8(max(0, min(255, a.rounded())))
                    }
                }
            }
        }

        progress(EngineProgress(stage: "Finishing", fraction: 0.98))
        guard let image = AIUpscaler.makeImage(out, outW, outH, alpha: src.hasAlpha, space: src.colorSpace) else {
            throw AIError.badOutput
        }
        return Result(image: image, detailSource: detailSource, rebuiltFrom: rebuilt)
    }

    static func makeImage(_ data: Data, _ w: Int, _ h: Int, alpha: Bool, space: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast).rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// One AI pass: runs the model over overlapping tiles of `rgba` (W×H, straight RGBA) and resamples
    /// each tile's 4× output straight into an outW×outH canvas, so the full 4× image never exists.
    private func runTiles(model: MLModel, rgba: [UInt8], width W: Int, height H: Int, outW: Int, outH: Int,
                          isCancelled: () -> Bool, tileDone: (Int, Int) -> Void) throws -> Data {
        let f = AIUpscaler.factor, T = AIUpscaler.tile, P = AIUpscaler.pad
        var out = Data(repeating: 255, count: outW * outH * 4)
        let colTaps = AIUpscaler.taps(count: outW, hrCount: W * f)
        let rowTaps = AIUpscaler.taps(count: outH, hrCount: H * f)
        let kx = Double(outW) / Double(W), ky = Double(outH) / Double(H)

        var pbOut: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, T, T, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { throw AIError.badOutput }

        let Wp = max(W, T), Hp = max(H, T)
        let xs = AIUpscaler.positions(Wp), ys = AIUpscaler.positions(Hp)
        let total = xs.count * ys.count
        var done = 0
        let hrTile = T * f

        for ty in ys {
            for tx in xs { try autoreleasepool {
                if isCancelled() { throw EngineError.cancelled }

                // Fill the tile, repeating edge pixels where it runs past the image.
                CVPixelBufferLockBaseAddress(pb, [])
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                rgba.withUnsafeBufferPointer { s in
                    for y in 0..<T {
                        let sy = min(ty + y, H - 1)
                        let row = base + y * bpr
                        for x in 0..<T {
                            let sx = min(tx + x, W - 1)
                            let i = (sy * W + sx) * 4
                            row[x * 4 + 0] = s[i + 2]
                            row[x * 4 + 1] = s[i + 1]
                            row[x * 4 + 2] = s[i + 0]
                            row[x * 4 + 3] = 255
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, [])

                let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
                let result = try model.prediction(from: input)
                guard let arr = result.featureValue(for: "upscaled")?.multiArrayValue,
                      arr.dataType == .float32, arr.shape.count == 4 else { throw AIError.badOutput }
                let st = arr.strides.map { $0.intValue }
                let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)

                // This tile owns the output pixels whose centres fall in its core (overlap discarded).
                let cx0 = tx == 0 ? 0 : tx + P
                let cx1 = min(tx + T >= Wp ? Wp : tx + T - P, W)
                let cy0 = ty == 0 ? 0 : ty + P
                let cy1 = min(ty + T >= Hp ? Hp : ty + T - P, H)
                let X0 = max(0, Int((Double(cx0) * kx - 0.5).rounded(.up)))
                let X1 = min(outW, Int((Double(cx1) * kx - 0.5).rounded(.up)))
                let Y0 = max(0, Int((Double(cy0) * ky - 0.5).rounded(.up)))
                let Y1 = min(outH, Int((Double(cy1) * ky - 0.5).rounded(.up)))
                let ox = tx * f, oy = ty * f

                if X1 > X0 && Y1 > Y0 {
                    out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Void in
                        let o = raw.bindMemory(to: UInt8.self)
                        for Y in Y0..<Y1 {
                            let ry = rowTaps[Y]
                            for X in X0..<X1 {
                                let rx = colTaps[X]
                                var acc: (Float, Float, Float) = (0, 0, 0)
                                for (gy, wy) in ry {
                                    let ly = min(max(gy - oy, 0), hrTile - 1)
                                    for (gx, wx) in rx {
                                        let lx = min(max(gx - ox, 0), hrTile - 1)
                                        let w = wx * wy
                                        let si = ly * st[2] + lx * st[3]
                                        acc.0 += ptr[si] * w
                                        acc.1 += ptr[st[1] + si] * w
                                        acc.2 += ptr[2 * st[1] + si] * w
                                    }
                                }
                                let di = (Y * outW + X) * 4
                                o[di] = UInt8(max(0, min(255, acc.0.rounded())))
                                o[di + 1] = UInt8(max(0, min(255, acc.1.rounded())))
                                o[di + 2] = UInt8(max(0, min(255, acc.2.rounded())))
                            }
                        }
                    }
                }
                done += 1
                tileDone(done, total)
            } }
        }
        return out
    }
}
