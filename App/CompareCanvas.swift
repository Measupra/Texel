#if os(iOS)
import SwiftUI
import UIKit

/// Before/after view: pinch to zoom, drag to pan, drag the round handle to move the divider,
/// double-tap to switch between fit and actual pixels.
struct CompareCanvas: UIViewRepresentable {
    var before: CGImage?
    var after: CGImage?
    var mode: ViewMode
    @Binding var split: Double
    var onZoomChange: (Double) -> Void

    func makeUIView(context: Context) -> CanvasView {
        CanvasView()
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        let binding = $split
        view.onSplit = { binding.wrappedValue = $0 }
        view.onZoomChange = onZoomChange
        view.update(before: before, after: after, mode: mode, split: split)
    }
}

final class CompareContentView: UIView {
    private let beforeLayer = CALayer()
    private let afterLayer = CALayer()
    private let maskLayer = CALayer()
    private let divider = CALayer()

    var mode: ViewMode = .split { didSet { if mode != oldValue { layoutLayers() } } }
    var split: CGFloat = 0.5 { didSet { if split != oldValue { layoutLayers() } } }
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { layoutLayers() } } }
    var hasAfter: Bool { afterLayer.contents != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for l in [beforeLayer, afterLayer] {
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            l.minificationFilter = .trilinear
            layer.addSublayer(l)
        }
        maskLayer.backgroundColor = UIColor.black.cgColor
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.95).cgColor
        divider.shadowColor = UIColor.black.cgColor
        divider.shadowOpacity = 0.4
        divider.shadowRadius = 2
        layer.addSublayer(divider)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setImages(before: CGImage?, after: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        beforeLayer.contents = before
        afterLayer.contents = after
        CATransaction.commit()
        layoutLayers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
    }

    func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        beforeLayer.frame = b
        afterLayer.frame = b
        beforeLayer.isHidden = hasAfter && mode == .after
        afterLayer.isHidden = !hasAfter || mode == .before
        if hasAfter && mode == .split {
            let x = (b.width * split).rounded()
            maskLayer.frame = CGRect(x: x, y: 0, width: b.width - x, height: b.height)
            afterLayer.mask = maskLayer
            let w = 2 / max(zoom, 0.0001)
            divider.frame = CGRect(x: x - w / 2, y: 0, width: w, height: b.height)
            divider.isHidden = false
        } else {
            afterLayer.mask = nil
            divider.isHidden = true
        }
        CATransaction.commit()
    }
}

final class CanvasView: UIView, UIScrollViewDelegate {
    var onSplit: ((Double) -> Void)?
    var onZoomChange: ((Double) -> Void)?

    private let scroll = UIScrollView()
    private let content = CompareContentView(frame: .zero)
    private let knob = UIView(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
    private var imageSize: CGSize = .zero
    private var fitted = true
    private var shownBefore: CGImage?
    private var shownAfter: CGImage?
    private var split: Double = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.bouncesZoom = true
        addSubview(scroll)
        scroll.addSubview(content)

        knob.backgroundColor = .white
        knob.layer.cornerRadius = 19
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.35
        knob.layer.shadowRadius = 6
        knob.layer.shadowOffset = CGSize(width: 0, height: 2)
        let arrows = UIImageView(image: UIImage(systemName: "arrow.left.and.right",
                                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)))
        arrows.tintColor = UIColor(white: 0.15, alpha: 1)
        arrows.contentMode = .center
        arrows.frame = knob.bounds
        arrows.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        knob.addSubview(arrows)
        knob.isHidden = true
        addSubview(knob)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(knobPanned(_:)))
        knob.addGestureRecognizer(pan)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(before: CGImage?, after: CGImage?, mode: ViewMode, split: Double) {
        if before !== shownBefore || after !== shownAfter {
            let newImage = after ?? before
            let size = newImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            let sizeChanged = size != imageSize
            shownBefore = before
            shownAfter = after
            if sizeChanged {
                scroll.zoomScale = 1
                imageSize = size
                content.frame = CGRect(origin: .zero, size: size)
                scroll.contentSize = size
                fitted = true
            }
            content.setImages(before: before, after: after)
            setNeedsLayout()
        }
        self.split = split
        content.mode = mode
        content.split = CGFloat(split)
        positionKnob()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        updateZoomLimits()
        centerContent()
        positionKnob()
    }

    private func updateZoomLimits() {
        guard imageSize.width > 0, bounds.width > 0 else { return }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height) * 0.94
        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = max(fit * 2, 4)
        if fitted || scroll.zoomScale < fit {
            scroll.zoomScale = fit
        }
        content.zoom = scroll.zoomScale
    }

    private func centerContent() {
        let w = content.frame.width, h = content.frame.height
        let x = max((scroll.bounds.width - w) / 2, 0)
        let y = max((scroll.bounds.height - h) / 2, 0)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    private func positionKnob() {
        guard content.mode == .split, content.hasAfter, imageSize.width > 0 else {
            knob.isHidden = true
            return
        }
        let visible = scroll.convert(scroll.bounds, to: content)
        let x = content.bounds.width * CGFloat(split)
        let y = min(max(visible.midY, 0), content.bounds.height)
        let p = content.convert(CGPoint(x: x, y: y), to: self)
        knob.center = p
        knob.isHidden = !(p.x >= 2 && p.x <= bounds.width - 2)
    }

    @objc private func knobPanned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: content)
        split = Double(min(1, max(0, p.x / max(content.bounds.width, 1))))
        content.split = CGFloat(split)
        onSplit?(split)
        positionKnob()
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > scroll.minimumZoomScale * 1.05 {
            fitted = true
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
        } else {
            let target = min(scroll.maximumZoomScale, 1 / max(window?.screen.scale ?? 3, 1) * 2)
            let scale = max(target, scroll.minimumZoomScale * 3)
            let p = g.location(in: content)
            let w = scroll.bounds.width / scale, h = scroll.bounds.height / scale
            fitted = false
            scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        content.zoom = scrollView.zoomScale
        positionKnob()
        let percent = Double(scrollView.zoomScale * (window?.screen.scale ?? 3)) * 100
        let report = onZoomChange
        // Report after the current layout pass, so SwiftUI isn't updated mid-update.
        DispatchQueue.main.async { report?(percent) }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        fitted = scale <= scrollView.minimumZoomScale * 1.001
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionKnob()
    }
}
#endif
