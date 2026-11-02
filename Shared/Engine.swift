import Foundation
import Metal
import CoreGraphics

// MARK: - Settings

struct UpscaleSettings: Equatable {
    enum Method: String, CaseIterable, Identifiable {
        case edge, lanczos, bicubic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .edge: return "Edge-directed (FSR 1 EASU)"
            case .lanczos: return "Lanczos-3"
            case .bicubic: return "Bicubic (Catmull-Rom)"
            }
        }
    }

    var scale: Double = 2
    var method: Method = .edge
    var progressive = true          // reach large scales in 2x steps
    var linearLight = true          // resample in sigmoidal linear light
    var refineIterations = 14       // back-projection passes
    var denoise: Double = 0         // 0...1, bilateral pre-filter
    var sharpen: Double = 0.25      // 0...1, RCAS
    var antiRinging = true          // Lanczos / bicubic halo clamp
    var sixteenBit = false          // 16 bits per channel output
}

enum Preset: String, CaseIterable, Identifiable {
    case fast = "Fast", balanced = "Balanced", best = "Best", custom = "Custom"
    var id: String { rawValue }

    var summary: String {
        switch self {
        case .fast: return "One edge-directed pass in gamma space. Instant."
        case .balanced: return "2× steps in linear light, then 6 back-projection passes."
        case .best: return "2× steps in linear light, then 14 back-projection passes. Takes longest, sharpest result."
        case .custom: return "Your own combination from Advanced."
        }
    }

    func apply(to s: inout UpscaleSettings) {
        switch self {
        case .fast:
            s.method = .edge; s.progressive = false; s.linearLight = false
            s.refineIterations = 0; s.sharpen = 0.2; s.antiRinging = true
        case .balanced:
            s.method = .edge; s.progressive = true; s.linearLight = true
            s.refineIterations = 6; s.sharpen = 0.2; s.antiRinging = true
        case .best:
            s.method = .edge; s.progressive = true; s.linearLight = true
            s.refineIterations = 14; s.sharpen = 0.25; s.antiRinging = true
        case .custom:
            break
        }
    }
}

struct EngineProgress {
    var stage: String
    var fraction: Double
}

enum EngineError: LocalizedError {
    case noGPU
    case shader(String)
    case outOfMemory(Int, Int)
    case tooLarge(Int, Int, Int)
    case cancelled
    case gpu(String)

    var errorDescription: String? {
        switch self {
        case .noGPU: return "No Metal GPU was found on this Mac."
        case .shader(let n): return "The GPU shader \(n) failed to load."
        case .outOfMemory(let w, let h): return "The GPU ran out of memory for a \(w) × \(h) image. Try a smaller scale."
        case .tooLarge(let w, let h, let m): return "\(w) × \(h) is larger than this GPU allows (\(m) px per side). Try a smaller scale."
        case .cancelled: return "Cancelled."
        case .gpu(let m): return "The GPU reported an error: \(m)"
        }
    }
}

// MARK: - Engine

final class Engine: @unchecked Sendable {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]
    let maxSide = 16384

    var gpuName: String { device.name }

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw EngineError.noGPU }
        device = d
        queue = q
        let library = try d.makeLibrary(source: Shaders.source, options: MTLCompileOptions())
        for name in ["k_denoise", "k_prep", "k_easu", "k_lanczos", "k_bicubic",
                     "k_toRef", "k_residual", "k_backproject", "k_display", "k_rcas"] {
            guard let f = library.makeFunction(name: name) else { throw EngineError.shader(name) }
            pipelines[name] = try d.makeComputePipelineState(function: f)
        }
    }

    static func outputSize(width: Int, height: Int, scale: Double) -> (Int, Int) {
        (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    // MARK: helpers

    private enum Arg { case i(Int32), f(Float) }

    private func texture(_ w: Int, _ h: Int, _ format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw EngineError.outOfMemory(w, h) }
        return t
    }

    private func commandBuffer() throws -> MTLCommandBuffer {
        guard let cb = queue.makeCommandBuffer() else { throw EngineError.gpu("could not create a command buffer") }
        return cb
    }

    private func finish(_ cb: MTLCommandBuffer) throws {
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw EngineError.gpu(e.localizedDescription) }
    }

    private func run(_ cb: MTLCommandBuffer, _ name: String, _ textures: [MTLTexture],
                     grid: (Int, Int), _ args: [Arg] = []) {
        guard let p = pipelines[name], let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(p)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        for (i, a) in args.enumerated() {
            switch a {
            case .i(var v): enc.setBytes(&v, length: MemoryLayout<Int32>.size, index: i)
            case .f(var v): enc.setBytes(&v, length: MemoryLayout<Float>.size, index: i)
            }
        }
        let tw = p.threadExecutionWidth
        let th = max(1, min(16, p.maxTotalThreadsPerThreadgroup / tw))
        enc.dispatchThreads(MTLSize(width: grid.0, height: grid.1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }

    /// Bytes moved per blit, so huge images never need one giant staging buffer.
    private let stripBytes = 128 << 20

    private func upload(_ data: Data, width: Int, height: Int, to tex: MTLTexture, bytesPerPixel: Int) throws {
        let rowBytes = width * bytesPerPixel
        let rowsPer = max(1, min(height, stripBytes / rowBytes))
        guard let staging = device.makeBuffer(length: rowBytes * rowsPer, options: .storageModeShared) else {
            throw EngineError.outOfMemory(width, height)
        }
        var y = 0
        while y < height {
            let rows = min(rowsPer, height - y)
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Void in
                _ = memcpy(staging.contents(), src.baseAddress! + y * rowBytes, rows * rowBytes)
            }
            let cb = try commandBuffer()
            guard let blit = cb.makeBlitCommandEncoder() else { throw EngineError.gpu("blit encoder") }
            blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                      sourceBytesPerImage: rowBytes * rows,
                      sourceSize: MTLSize(width: width, height: rows, depth: 1),
                      to: tex, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: y, z: 0))
            blit.endEncoding()
            try finish(cb)
            y += rows
        }
    }

    private func download(_ tex: MTLTexture, bytesPerPixel: Int) throws -> Data {
        let width = tex.width, height = tex.height
        let rowBytes = width * bytesPerPixel
        var out = Data(count: rowBytes * height)
        let rowsPer = max(1, min(height, stripBytes / rowBytes))
        guard let staging = device.makeBuffer(length: rowBytes * rowsPer, options: .storageModeShared) else {
            throw EngineError.outOfMemory(width, height)
        }
        var y = 0
        while y < height {
            let rows = min(rowsPer, height - y)
            let cb = try commandBuffer()
            guard let blit = cb.makeBlitCommandEncoder() else { throw EngineError.gpu("blit encoder") }
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: y, z: 0),
                      sourceSize: MTLSize(width: width, height: rows, depth: 1),
                      to: staging, destinationOffset: 0,
                      destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * rows)
            blit.endEncoding()
            try finish(cb)
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Void in
                _ = memcpy(dst.baseAddress! + y * rowBytes, staging.contents(), rows * rowBytes)
            }
            y += rows
        }
        return out
    }

    // MARK: pipeline

    func upscale(_ src: SourceImage, settings s: UpscaleSettings,
                 progress: @escaping (EngineProgress) -> Void,
                 isCancelled: @escaping () -> Bool) throws -> CGImage {
        let W = src.width, H = src.height
        let (outW, outH) = Engine.outputSize(width: W, height: H, scale: s.scale)
        guard outW <= maxSide, outH <= maxSide else { throw EngineError.tooLarge(outW, outH, maxSide) }

        let mode: Int32 = s.linearLight ? 1 : 0
        let upscaling = outW != W || outH != H
        let iterations = upscaling ? max(0, s.refineIterations) : 0

        // Rough work units so the progress bar moves evenly.
        var upSteps: [(Int, Int)] = []
        if s.method == .edge {
            if s.progressive {
                var w = W, h = H
                while w * 2 <= outW && h * 2 <= outH { w *= 2; h *= 2; upSteps.append((w, h)) }
            }
            if upSteps.last.map({ $0.0 != outW || $0.1 != outH }) ?? true { upSteps.append((outW, outH)) }
        }
        let totalUnits = Double(2 + max(1, upSteps.count) + iterations * 2 + 2)
        var done = 0.0
        func step(_ label: String, _ units: Double = 1) throws {
            if isCancelled() { throw EngineError.cancelled }
            done += units
            progress(EngineProgress(stage: label, fraction: min(1, done / totalUnits)))
        }

        // 1. Upload source pixels (16-bit premultiplied RGBA).
        progress(EngineProgress(stage: "Sending pixels to the GPU", fraction: 0))
        let srcTex = try texture(W, H, .rgba16Unorm)
        try upload(src.pixels, width: W, height: H, to: srcTex, bytesPerPixel: 8)

        // 2. Denoise, then convert to working spaces.
        var cb = try commandBuffer()
        var base: MTLTexture = srcTex
        if s.denoise > 0.001 {
            let d = try texture(W, H)
            run(cb, "k_denoise", [srcTex, d], grid: (W, H), [.f(Float(s.denoise))])
            base = d
        }
        let up0 = try texture(W, H)
        let lrRef = try texture(W, H)
        run(cb, "k_prep", [base, up0, lrRef], grid: (W, H), [.i(mode)])
        try finish(cb)
        try step(s.denoise > 0.001 ? "Denoised source" : "Prepared source", 2)

        // 3. Upscale.
        var cur: MTLTexture = up0
        switch s.method {
        case .edge:
            for (i, (w, h)) in upSteps.enumerated() {
                let next = try texture(w, h)
                cb = try commandBuffer()
                run(cb, "k_easu", [cur, next], grid: (w, h))
                try finish(cb)
                cur = next
                try step("Edge-directed upscale \(i + 1) of \(upSteps.count) · \(w) × \(h)")
            }
        case .lanczos:
            let mid = try texture(outW, H)
            let out = try texture(outW, outH)
            let ar: Int32 = s.antiRinging ? 1 : 0
            cb = try commandBuffer()
            run(cb, "k_lanczos", [cur, mid], grid: (outW, H), [.i(0), .i(ar)])
            run(cb, "k_lanczos", [mid, out], grid: (outW, outH), [.i(1), .i(ar)])
            try finish(cb)
            cur = out
            try step("Lanczos-3 upscale")
        case .bicubic:
            let out = try texture(outW, outH)
            cb = try commandBuffer()
            run(cb, "k_bicubic", [cur, out], grid: (outW, outH), [.i(s.antiRinging ? 1 : 0)])
            try finish(cb)
            cur = out
            try step("Bicubic upscale")
        }

        var hr = try texture(outW, outH)
        cb = try commandBuffer()
        run(cb, "k_toRef", [cur, hr], grid: (outW, outH), [.i(mode)])
        try finish(cb)

        // 4. Iterative back-projection: make the result agree with the source when shrunk.
        if iterations > 0 {
            let err = try texture(W, H)
            var hr2 = try texture(outW, outH)
            for it in 0..<iterations {
                cb = try commandBuffer()
                run(cb, "k_residual", [lrRef, hr, err], grid: (W, H))
                run(cb, "k_backproject", [hr, err, lrRef, hr2], grid: (outW, outH), [.f(1.0), .i(mode)])
                try finish(cb)
                swap(&hr, &hr2)
                try step("Refining detail · pass \(it + 1) of \(iterations)", 2)
            }
        }

        // 5. Back to sRGB, sharpen, write final pixels.
        let shown = try texture(outW, outH)
        let outTex = try texture(outW, outH, s.sixteenBit ? .rgba16Unorm : .rgba8Unorm)
        cb = try commandBuffer()
        run(cb, "k_display", [hr, shown], grid: (outW, outH), [.i(mode)])
        run(cb, "k_rcas", [shown, outTex], grid: (outW, outH), [.f(Float(s.sharpen))])
        try finish(cb)
        try step(s.sharpen > 0 ? "Sharpened" : "Encoded")

        // 6. Read back.
        let bpp = s.sixteenBit ? 8 : 4
        let data = try download(outTex, bytesPerPixel: bpp)
        try step("Done")

        guard let provider = CGDataProvider(data: data as CFData) else { throw EngineError.outOfMemory(outW, outH) }
        let alpha: CGImageAlphaInfo = src.hasAlpha ? .last : .noneSkipLast
        var info = CGBitmapInfo(rawValue: alpha.rawValue)
        if s.sixteenBit { info.insert(.byteOrder16Little) }
        guard let image = CGImage(width: outW, height: outH,
                                  bitsPerComponent: s.sixteenBit ? 16 : 8,
                                  bitsPerPixel: bpp * 8,
                                  bytesPerRow: outW * bpp,
                                  space: src.colorSpace,
                                  bitmapInfo: info,
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw EngineError.gpu("could not build the output image")
        }
        return image
    }
}
