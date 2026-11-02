import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers
import Accelerate
#if os(macOS)
import AppKit
#endif

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class AppState: ObservableObject {
    @Published var source: SourceImage?
    @Published var result: CGImage?
    @Published var scale: Double = 2
    @Published var useAI = true
    @Published var aiModel: AIModel = .photo
    @Published var preset: Preset = .best
    @Published var isRunning = false
    @Published var isLoading = false
    @Published var isExporting = false
    @Published var progress = 0.0
    @Published var stage = ""
    @Published var startedAt = Date()
    @Published var lastDuration: TimeInterval?
    @Published var resultLabel = ""
    @Published var viewMode: ViewMode = .split
    /// How much of a Lanczos enlargement of the original is mixed into the AI result (0 = pure AI).
    @Published var detail: Double = 0.35
    /// Unsharp-mask strength applied after the AI (0 = none).
    @Published var sharpen: Double = 0.25
    /// Edge-preserving smoothing applied after the AI (0 = none). Evens out blockiness and noise.
    @Published var smooth: Double = 0.35
    @Published var isBlending = false
    /// True once the current result has been saved to Photos or shared.
    @Published var isSaved = false
    /// Counts finished runs; the UI plays a success haptic each time it changes.
    @Published var completedRuns = 0
    @Published var split = 0.5
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var toastIcon = "checkmark.circle.fill"
    @Published var shareItem: ShareItem?
    @Published private(set) var engine: Engine?

    let ai = AIUpscaler()
    /// The unblended AI output, kept so the Detail slider can re-blend without re-running the AI.
    private var aiRaw: CGImage?
    /// Where Detail borrows texture from (the original, or its real-resolution version).
    private var detailSource: CGImage?
    /// Bumped by each run and by goHome(), so a finished or cancelled run never touches a newer state.
    private var runID = 0
    private var cancelFlag = CancelFlag()
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Classic mode keeps several full-size GPU buffers, so it gets a lower limit on a phone.
    static let classicMaxPixels = 16_000_000
    #else
    static let classicMaxPixels = 120_000_000
    #endif

    /// "Mac", "iPhone" or "iPad", for messages.
    static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    init() {
        Task.detached(priority: .utility) {
            if let e = try? Engine() {
                await MainActor.run { self.engine = e }
            }
        }
    }

    // MARK: derived

    var outputSize: (Int, Int)? {
        guard let s = source else { return nil }
        return Engine.outputSize(width: s.width, height: s.height, scale: scale)
    }

    /// A reason the current settings can't run, if there is one.
    var blocker: String? {
        guard let size = outputSize else { return nil }
        let w = size.0, h = size.1
        if useAI {
            if !ai.isAvailable(aiModel) { return "This AI model is missing from the app." }
            if w > AIUpscaler.maxSide || h > AIUpscaler.maxSide || w * h > AIUpscaler.maxOutputPixels {
                return "\(w) × \(h) is too large for this \(AppState.deviceName). Pick a smaller scale."
            }
        } else {
            if engine == nil { return "The GPU is still getting ready." }
            if w * h > AppState.classicMaxPixels { return "\(w) × \(h) is too large for Classic on this \(AppState.deviceName). Use AI or a smaller scale." }
        }
        return nil
    }

    // MARK: loading

    func load(item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "That photo couldn't be read."
                return
            }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).\(ext)")
            try data.write(to: url)
            try await open(url: url, name: "Photo.\(ext)")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(fileURL: URL) async {
        isLoading = true
        defer { isLoading = false }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("source-\(UUID().uuidString)-\(fileURL.lastPathComponent)")
            try FileManager.default.copyItem(at: fileURL, to: copy)
            try await open(url: copy, name: fileURL.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(url: URL, name: String) async throws {
        let img = try await Task.detached(priority: .userInitiated) { () throws -> SourceImage in
            let loaded = try ImageFiles.load(url: url)
            return SourceImage(url: url, name: name, cgImage: loaded.cgImage, width: loaded.width,
                               height: loaded.height, colorSpace: loaded.colorSpace,
                               hasAlpha: loaded.hasAlpha, pixels: loaded.pixels)
        }.value
        source = img
        result = nil
        aiRaw = nil
        detailSource = nil
        lastDuration = nil
        resultLabel = ""
        viewMode = .split
        split = 0.5
    }

    // MARK: running

    func run() {
        guard let src = source, !isRunning, blocker == nil, let size = outputSize else { return }
        let outW = size.0, outH = size.1
        let useAI = self.useAI, model = aiModel, ai = self.ai, engine = self.engine
        let detail = self.detail, sharpen = self.sharpen, smooth = self.smooth
        var settings = UpscaleSettings()
        preset.apply(to: &settings)
        settings.scale = scale
        let label = useAI ? "AI \(model.shortTitle) \(scaleText(scale))" : "\(preset.rawValue) \(scaleText(scale))"
        let flag = CancelFlag()
        cancelFlag = flag
        runID += 1
        let id = runID
        isRunning = true
        progress = 0
        stage = "Starting…"
        startedAt = Date()
        let start = startedAt
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Upscale") { flag.set() }
        #endif

        Task.detached(priority: .userInitiated) {
            do {
                let report: (EngineProgress) -> Void = { p in
                    Task { @MainActor in
                        guard self.isRunning else { return }
                        self.progress = p.fraction
                        self.stage = p.stage
                    }
                }
                let image: CGImage
                var raw: CGImage?
                var detailSrc: CGImage?
                var rebuiltFrom = 1
                if useAI {
                    let r = try ai.upscaleDetailed(src, model: model, outW: outW, outH: outH,
                                                   progress: report, isCancelled: { flag.isSet })
                    raw = r.image
                    detailSrc = r.detailSource
                    rebuiltFrom = r.rebuiltFrom
                    report(EngineProgress(stage: "Finishing: detail, smoothing, sharpening", fraction: 0.99))
                    image = Finisher.apply(ai: r.image, detailSource: r.detailSource,
                                           detail: detail, sharpen: sharpen, smooth: smooth)
                } else if let engine {
                    image = try engine.upscale(src, settings: settings, progress: report, isCancelled: { flag.isSet })
                } else {
                    throw EngineError.noGPU
                }
                let took = Date().timeIntervalSince(start)
                let rawResult = raw, detailResult = detailSrc, rebuilt = rebuiltFrom
                let srcSize = (src.width, src.height)
                await MainActor.run {
                    guard self.runID == id else { return }
                    self.finish()
                    self.result = image
                    self.isSaved = false
                    self.aiRaw = rawResult
                    self.detailSource = detailResult
                    self.lastDuration = took
                    self.resultLabel = label
                    self.viewMode = .split
                    self.completedRuns += 1
                    self.revealResult()
                    if rebuilt > 1 {
                        self.showToast("Low-res photo detected. Rebuilt from \(srcSize.0 / rebuilt)×\(srcSize.1 / rebuilt)", icon: "wand.and.stars")
                    }
                }
            } catch EngineError.cancelled {
                await MainActor.run {
                    guard self.runID == id else { return }
                    self.finish()
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    guard self.runID == id else { return }
                    self.finish()
                    self.errorMessage = msg
                }
            }
        }
    }

    /// Wipes the result in from the right, settling the divider in the middle.
    private func revealResult() {
        let id = runID
        let start = Date()
        split = 1
        Task { @MainActor in
            while self.runID == id {
                let t = min(1, Date().timeIntervalSince(start) / 0.9)
                let eased = 1 - pow(1 - t, 3)
                self.split = 1 - 0.5 * eased
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func cancel() {
        cancelFlag.set()
        stage = "Cancelling…"
    }

    /// Stops any upscale in progress and returns to the start screen.
    func goHome() {
        if isRunning {
            cancelFlag.set()
            finish()
        }
        runID += 1
        source = nil
        result = nil
        aiRaw = nil
        detailSource = nil
        isSaved = false
        lastDuration = nil
        resultLabel = ""
        viewMode = .split
        split = 0.5
        progress = 0
        stage = ""
    }

    func markSaved() { isSaved = true }

    private func finish() {
        isRunning = false
        stage = ""
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        #endif
    }

    // MARK: finishing (detail + sharpen)

    /// Re-applies Detail and Sharpen to the last AI result, without running the AI again.
    func applyDetail() {
        guard let raw = aiRaw, let detailSrc = detailSource, !isRunning, !isBlending else { return }
        let detail = self.detail, sharpen = self.sharpen, smooth = self.smooth
        isBlending = true
        Task.detached(priority: .userInitiated) {
            let image = Finisher.apply(ai: raw, detailSource: detailSrc,
                                       detail: detail, sharpen: sharpen, smooth: smooth)
            await MainActor.run {
                self.isBlending = false
                // Ignore the result if a new image or run replaced the one it came from.
                if self.aiRaw === raw {
                    self.result = image
                    self.isSaved = false
                }
                if abs(self.detail - detail) > 0.001 || abs(self.sharpen - sharpen) > 0.001
                    || abs(self.smooth - smooth) > 0.001 { self.applyDetail() }
            }
        }
    }

    // MARK: exporting

    private func writeResult(_ format: ExportFormat, quality: Double) async throws -> URL {
        guard let image = result, let src = source else { throw ImageFileError.writeFailed("image") }
        let base = (src.name as NSString).deletingPathExtension
        let name = "\(base)-texel-\(scaleText(scale).replacingOccurrences(of: "×", with: "x")).\(format.fileExtension)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) {
            try ImageFiles.save(image, to: url, format: format, quality: quality)
        }.value
        return url
    }

    #if os(macOS)
    /// Mac: asks where to save (Downloads by default), then writes the file there.
    /// `then` runs only if the file was saved.
    func share(_ format: ExportFormat, then: (() -> Void)? = nil) {
        guard let image = result, let src = source, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let base = (src.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base)-texel-\(scaleText(scale).replacingOccurrences(of: "×", with: "x")).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.isExporting = true
                defer { self.isExporting = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ImageFiles.save(image, to: url, format: format, quality: 0.92)
                    }.value
                    self.isSaved = true
                    self.showToast("Saved \(url.lastPathComponent)")
                    then?()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    #else
    func share(_ format: ExportFormat) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await writeResult(format, quality: 0.92)
                shareItem = ShareItem(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif

    /// Saves the result to Photos. `then` runs only if the save succeeded.
    func saveToPhotos(then: (() -> Void)? = nil) {
        guard !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                errorMessage = "Texel can't add to your library. Allow it in Settings › Privacy & Security › Photos › Texel."
                return
            }
            do {
                let url = try await writeResult(.heic, quality: 0.95)
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: url, options: nil)
                }
                isSaved = true
                showToast("Saved to Photos")
                then?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func showToast(_ text: String, icon: String = "checkmark.circle.fill") {
        toast = text
        toastIcon = icon
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == text { toast = nil }
        }
    }
}

// MARK: - Finishing

/// Runs after the AI: adds back the original's fine texture (only its fine detail, so it never blurs
/// the result) and sharpens. CPU work with Accelerate; about a second on a large image.
enum Finisher {
    static func apply(ai: CGImage, detailSource: CGImage, detail: Double, sharpen: Double, smooth: Double) -> CGImage {
        guard detail > 0.001 || sharpen > 0.001 || smooth > 0.001 else { return ai }
        let w = ai.width, h = ai.height, rowBytes = w * 4
        let space = ai.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let hasAlpha: Bool
        switch ai.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let info = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue

        var a = [UInt8](repeating: 255, count: rowBytes * h)
        guard draw(ai, into: &a, w, h, space, info) else { return ai }
        // How much bigger the result is than the detail it can trust.
        let ratio = Double(w) / Double(max(1, detailSource.width))

        // Detail: the original's high-frequency texture, enlarged with Lanczos.
        if detail > 0.001 {
            var s = [UInt8](repeating: 255, count: detailSource.width * detailSource.height * 4)
            if draw(detailSource, into: &s, detailSource.width, detailSource.height, space, info) {
                var l = [UInt8](repeating: 255, count: rowBytes * h)
                let scaled = scale(&s, detailSource.width, detailSource.height, into: &l, w, h)
                s = []
                if scaled {
                    var k = Int(ratio.rounded()) * 2 + 1
                    k = max(3, min(k, 15))
                    var lb = [UInt8](repeating: 255, count: rowBytes * h)
                    if tent(&l, into: &lb, w, h, size: k) {
                        // At big enlargements the original's "texture" is really its pixel grid and
                        // compression blocks, so add much less of it: full at 2×, about 1/8 at 8×.
                        let gain = Float(detail * 1.5 * min(1, pow(2 / max(ratio, 1), 1.5)))
                        combine(&a, plus: l, minus: lb, gain: gain, hasAlpha: hasAlpha)
                    }
                }
            }
        }

        // Smooth: blend towards a soft copy, except across strong edges.
        if smooth > 0.001 {
            var k = Int((ratio * 1.5).rounded())
            if k % 2 == 0 { k += 1 }
            k = max(3, min(k, 15))
            var b = [UInt8](repeating: 255, count: rowBytes * h)
            if tent(&a, into: &b, w, h, size: k) {
                smoothBlend(&a, toward: b, amount: Float(min(1, smooth)), edge: 80)
            }
        }

        // Sharpen: unsharp mask on the result.
        if sharpen > 0.001 {
            var b = [UInt8](repeating: 255, count: rowBytes * h)
            if tent(&a, into: &b, w, h, size: 5) {
                let base = a
                combine(&a, plus: base, minus: b, gain: Float(sharpen * 1.2), hasAlpha: hasAlpha)
            }
        }

        guard let provider = CGDataProvider(data: Data(a) as CFData),
              let out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return ai }
        return out
    }

    private static func draw(_ image: CGImage, into buf: inout [UInt8], _ w: Int, _ h: Int,
                             _ space: CGColorSpace, _ info: UInt32) -> Bool {
        buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
    }

    private static func scale(_ src: inout [UInt8], _ sw: Int, _ sh: Int,
                              into dst: inout [UInt8], _ dw: Int, _ dh: Int) -> Bool {
        src.withUnsafeMutableBytes { (s: UnsafeMutableRawBufferPointer) -> Bool in
            dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Bool in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(sh),
                                       width: vImagePixelCount(sw), rowBytes: sw * 4)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(dh),
                                       width: vImagePixelCount(dw), rowBytes: dw * 4)
                return vImageScale_ARGB8888(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
            }
        }
    }

    private static func tent(_ src: inout [UInt8], into dst: inout [UInt8], _ w: Int, _ h: Int, size: Int) -> Bool {
        src.withUnsafeMutableBytes { (s: UnsafeMutableRawBufferPointer) -> Bool in
            dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Bool in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h),
                                       width: vImagePixelCount(w), rowBytes: w * 4)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h),
                                       width: vImagePixelCount(w), rowBytes: w * 4)
                return vImageTentConvolve_ARGB8888(&sb, &db, nil, 0, 0, UInt32(size), UInt32(size), nil,
                                                   vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
            }
        }
    }

    /// Moves each pixel towards `soft` by up to `amount`, less where the two differ a lot (an edge).
    private static func smoothBlend(_ a: inout [UInt8], toward soft: [UInt8], amount: Float, edge: Float) {
        let n = a.count
        a.withUnsafeMutableBufferPointer { ap in
            soft.withUnsafeBufferPointer { bp in
                var i = 0
                while i < n {
                    let d0 = Float(bp[i]) - Float(ap[i])
                    let d1 = Float(bp[i + 1]) - Float(ap[i + 1])
                    let d2 = Float(bp[i + 2]) - Float(ap[i + 2])
                    let d = max(abs(d0), max(abs(d1), abs(d2)))
                    let w = amount * max(0, 1 - d / edge)
                    if w > 0 {
                        ap[i] = UInt8(max(0, min(255, (Float(ap[i]) + w * d0).rounded())))
                        ap[i + 1] = UInt8(max(0, min(255, (Float(ap[i + 1]) + w * d1).rounded())))
                        ap[i + 2] = UInt8(max(0, min(255, (Float(ap[i + 2]) + w * d2).rounded())))
                    }
                    i += 4
                }
            }
        }
    }

    /// a += gain × (plus − minus) on the colour channels, clamped (and kept within alpha when premultiplied).
    private static func combine(_ a: inout [UInt8], plus: [UInt8], minus: [UInt8], gain: Float, hasAlpha: Bool) {
        let n = a.count
        a.withUnsafeMutableBufferPointer { ap in
            plus.withUnsafeBufferPointer { pp in
                minus.withUnsafeBufferPointer { mp in
                    var i = 0
                    while i < n {
                        let limit: Float = hasAlpha ? Float(ap[i + 3]) : 255
                        for c in 0..<3 {
                            let v = Float(ap[i + c]) + gain * (Float(pp[i + c]) - Float(mp[i + c]))
                            ap[i + c] = UInt8(max(0, min(limit, v.rounded())))
                        }
                        i += 4
                    }
                }
            }
        }
    }
}
