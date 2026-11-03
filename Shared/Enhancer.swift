import Foundation
import CoreGraphics
import CoreImage

/// "Colour & light": Apple's own automatic photo fixes (exposure curve, shadows and highlights,
/// vibrance, skin-tone balance), the same analysis the Photos app's Auto button uses, plus a gentle
/// local-contrast "clarity" boost that brings out texture in things like foliage, bark and fabric.
enum Enhancer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `amount` 0…1 blends from the untouched image to the fully enhanced one.
    static func apply(_ image: CGImage, amount: Double) -> CGImage {
        guard amount > 0.001 else { return image }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let longSide = max(extent.width, extent.height)

        // Analyse a small copy: much faster, and the fixes don't depend on resolution.
        let k = min(1, 1024 / longSide)
        let preview = input.transformed(by: CGAffineTransform(scaleX: k, y: k))
        var out = input
        for filter in preview.autoAdjustmentFilters(options: [.redEye: false, .crop: false, .level: false]) {
            filter.setValue(out, forKey: kCIInputImageKey)
            if let o = filter.outputImage { out = o }
        }

        // Clarity: an unsharp mask with a wide radius lifts local contrast without sharpening noise.
        let clarity = CIFilter(name: "CIUnsharpMask")!
        clarity.setValue(out.clampedToExtent(), forKey: kCIInputImageKey)
        clarity.setValue(max(4, longSide * 0.006), forKey: kCIInputRadiusKey)
        clarity.setValue(0.35, forKey: kCIInputIntensityKey)
        if let o = clarity.outputImage { out = o.cropped(to: extent) }

        if amount < 0.999 {
            let mix = CIFilter(name: "CIDissolveTransition")!
            mix.setValue(input, forKey: kCIInputImageKey)
            mix.setValue(out, forKey: kCIInputTargetImageKey)
            mix.setValue(amount, forKey: kCIInputTimeKey)
            if let o = mix.outputImage { out = o.cropped(to: extent) }
        }

        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(out, from: extent, format: .RGBA8, colorSpace: space) ?? image
    }
}
