import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A decoded source image, kept as 16-bit premultiplied RGBA (little-endian) for the GPU.
struct SourceImage: @unchecked Sendable {
    let url: URL?
    let name: String
    let cgImage: CGImage
    let width: Int
    let height: Int
    let colorSpace: CGColorSpace
    let hasAlpha: Bool
    let pixels: Data
}

enum ImageFileError: LocalizedError {
    case unreadable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let n): return "\(n) couldn't be opened as an image."
        case .writeFailed(let n): return "\(n) couldn't be written. Check the folder permissions and free space."
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case png = "PNG", tiff = "TIFF", jpeg = "JPEG", heic = "HEIC"
    var id: String { rawValue }

    var type: UTType {
        switch self {
        case .png: return .png
        case .tiff: return .tiff
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .tiff: return "tiff"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
    var isLossy: Bool { self == .jpeg || self == .heic }
}

enum ImageFiles {
    static func load(url: URL) throws -> SourceImage {
        let name = url.lastPathComponent
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageFileError.unreadable(name) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let ph = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        // A full-size "thumbnail" applies the EXIF orientation for us.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
        guard let image else { throw ImageFileError.unreadable(name) }
        return try make(from: image, name: name, url: url)
    }

    static func make(from image: CGImage, name: String, url: URL?) throws -> SourceImage {
        let w = image.width, h = image.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var space = image.colorSpace ?? srgb
        if space.model != .rgb || !space.supportsOutput { space = srgb }

        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }

        let rowBytes = w * 8
        var data = Data(count: rowBytes * h)
        // The GPU wants little-endian 16-bit channels. If Quartz won't draw that layout
        // directly, draw big-endian and swap the bytes afterwards.
        func draw(_ info: UInt32) -> Bool {
            data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                          bitsPerComponent: 16, bytesPerRow: rowBytes,
                                          space: space, bitmapInfo: info) else { return false }
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
        }
        let premul = CGImageAlphaInfo.premultipliedLast.rawValue
        if !draw(premul | CGBitmapInfo.byteOrder16Little.rawValue) {
            guard draw(premul | CGBitmapInfo.byteOrder16Big.rawValue) else { throw ImageFileError.unreadable(name) }
            data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Void in
                let words = buf.bindMemory(to: UInt16.self)
                for i in words.indices { words[i] = words[i].byteSwapped }
            }
        }
        return SourceImage(url: url, name: name, cgImage: image, width: w, height: h,
                           colorSpace: space, hasAlpha: hasAlpha, pixels: data)
    }

    static func save(_ image: CGImage, to url: URL, format: ExportFormat, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ImageFileError.writeFailed(url.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageFileError.writeFailed(url.lastPathComponent) }
    }
}
