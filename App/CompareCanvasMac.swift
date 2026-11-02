#if os(macOS)
import SwiftUI
import AppKit
import QuartzCore

/// Mac version of the before/after view, with the same look and controls as on iPhone:
/// pinch or ⌘-scroll to zoom, drag to pan, drag the round handle to compare,
/// double-click to switch between fit and actual pixels.
struct CompareCanvas: NSViewRepresentable {
    var before: CGImage?
    var after: CGImage?
    var mode: ViewMode
    @Binding var split: Double
    var onZoomChange: (Double) -> Void

    func makeNSView(context: Context) -> MacCanvasView {
        MacCanvasView(frame: .zero)
    }

    func updateNSView(_ view: MacCanvasView, context: Context) {
        let binding = $split
        view.onSplit = { binding.wrappedValue = $0 }
        view.onZoomChange = onZoomChange
        view.update(before: before, after: after, mode: mode, split: split)
    }
}

/// Keeps the image centred when it is smaller than the view.
final class MacCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        return r
    }
}

/// ⌘- or ⌥-scroll zooms around the pointer; plain scrolling pans.
final class MacZoomScrollView: NSScrollView {
    var onUserZoom: (() -> Void)?

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onUserZoom?()
    }

    override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags
        guard mods.contains(.command) || mods.contains(.option) else { return super.scrollWheel(with: event) }
        onUserZoom?()
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        let factor = exp(event.scrollingDeltaY * k)
        let p = contentView.convert(event.locationInWindow, from: nil)
        setMagnification(min(maxMagnification, max(minMagnification, magnification * factor)), centeredAt: p)
    }
}

/// Draws the original under the result and masks the result to the right of the divider.
final class MacCompareContent: NSView {
    private let beforeLayer = CALayer()
    private let afterLayer = CALayer()
    private let maskLayer = CALayer()
    private let divider = CALayer()

    var mode: ViewMode = .split { didSet { if mode != oldValue { layoutLayers() } } }
    var split: CGFloat = 0.5 { didSet { if split != oldValue { layoutLayers() } } }
    var hasAfter: Bool { afterLayer.contents != nil }
    var onSplitDrag: ((NSPoint) -> Void)?
    var onDoubleClick: (() -> Void)?

    private enum Drag { case pan(start: NSPoint, origin: NSPoint), divider }
    private var drag: Drag?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        for l in [beforeLayer, afterLayer] {
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            l.minificationFilter = .trilinear
            layer?.addSublayer(l)
        }
        maskLayer.backgroundColor = NSColor.black.cgColor
        divider.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        divider.shadowColor = NSColor.black.cgColor
        divider.shadowOpacity = 0.4
        divider.shadowRadius = 2
        divider.shadowOffset = .zero
        layer?.addSublayer(divider)
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

    override func layout() {
        super.layout()
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
            maskLayer.frame = CGRect(x: x, y: 0, width: max(0, b.width - x), height: b.height)
            afterLayer.mask = maskLayer
            let mag = enclosingScrollView?.magnification ?? 1
            let w = 2 / max(mag, 0.0001)
            divider.frame = CGRect(x: x - w / 2, y: 0, width: w, height: b.height)
            divider.isHidden = false
        } else {
            afterLayer.mask = nil
            divider.isHidden = true
        }
        CATransaction.commit()
    }

    private func nearDivider(_ p: NSPoint) -> Bool {
        guard mode == .split, hasAfter, let sv = enclosingScrollView else { return false }
        return abs(p.x - bounds.width * split) * sv.magnification < 8
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if mode == .split, hasAfter, let sv = enclosingScrollView {
            let w = 16 / max(sv.magnification, 0.0001)
            addCursorRect(NSRect(x: bounds.width * split - w / 2, y: 0, width: w, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if nearDivider(p) {
            drag = .divider
        } else if let sv = enclosingScrollView {
            drag = .pan(start: event.locationInWindow, origin: sv.contentView.bounds.origin)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let sv = enclosingScrollView else { return }
        switch drag {
        case .divider:
            onSplitDrag?(event.locationInWindow)
        case .pan(let start, let origin):
            let mag = sv.magnification
            let dx = (event.locationInWindow.x - start.x) / mag
            let dy = (event.locationInWindow.y - start.y) / mag
            let clip = sv.contentView
            var r = clip.bounds
            r.origin = NSPoint(x: origin.x - dx, y: origin.y + dy)
            clip.scroll(to: clip.constrainBoundsRect(r).origin)
            sv.reflectScrolledClipView(clip)
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }
}

/// The round white handle on the divider.
final class MacKnob: NSView {
    var onDrag: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        let arrows = NSImageView()
        arrows.image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        arrows.contentTintColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        arrows.frame = bounds
        arrows.autoresizingMask = [.width, .height]
        addSubview(arrows)
        toolTip = "Drag to compare before and after"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
}

final class MacCanvasView: NSView {
    var onSplit: ((Double) -> Void)?
    var onZoomChange: ((Double) -> Void)?

    private let scroll = MacZoomScrollView()
    private let content = MacCompareContent(frame: .zero)
    private let knob = MacKnob(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
    private var imageSize: CGSize = .zero
    private var fitted = true
    private var shownBefore: CGImage?
    private var shownAfter: CGImage?
    private var split: Double = 0.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.contentView = MacCenteringClipView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.01
        scroll.maxMagnification = 32
        scroll.documentView = content
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        scroll.onUserZoom = { [weak self] in self?.fitted = false }
        addSubview(scroll)

        knob.isHidden = true
        knob.onDrag = { [weak self] p in self?.dragSplit(toWindowPoint: p) }
        addSubview(knob)

        content.onSplitDrag = { [weak self] p in self?.dragSplit(toWindowPoint: p) }
        content.onDoubleClick = { [weak self] in self?.toggleZoom() }

        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func update(before: CGImage?, after: CGImage?, mode: ViewMode, split: Double) {
        if before !== shownBefore || after !== shownAfter {
            let newImage = after ?? before
            let size = newImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            shownBefore = before
            shownAfter = after
            if size != imageSize {
                imageSize = size
                content.setFrameSize(size)
                fitted = true
            }
            content.setImages(before: before, after: after)
            if fitted {
                DispatchQueue.main.async { [weak self] in self?.fit() }
            }
        }
        self.split = split
        content.mode = mode
        content.split = CGFloat(split)
        window?.invalidateCursorRects(for: content)
        positionKnob()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitted { fit() } else { positionKnob() }
    }

    private func fit() {
        guard imageSize.width > 0, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        let b = content.bounds
        scroll.magnify(toFit: b.insetBy(dx: -b.width * 0.03, dy: -b.height * 0.03))
        fitted = true
        afterZoom()
    }

    private func toggleZoom() {
        if fitted {
            let backing = window?.backingScaleFactor ?? 2
            let clip = scroll.contentView
            let center = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
            scroll.animator().setMagnification(1 / backing, centeredAt: center)
            fitted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.afterZoom() }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                let b = content.bounds
                scroll.animator().magnify(toFit: b.insetBy(dx: -b.width * 0.03, dy: -b.height * 0.03))
            }
            fitted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.afterZoom() }
        }
    }

    private func afterZoom() {
        content.layoutLayers()
        positionKnob()
        let backing = window?.backingScaleFactor ?? 2
        let percent = Double(scroll.magnification * backing) * 100
        let report = onZoomChange
        DispatchQueue.main.async { report?(percent) }
    }

    @objc private func boundsChanged(_ note: Notification) {
        afterZoom()
        window?.invalidateCursorRects(for: content)
    }

    private func positionKnob() {
        guard content.mode == .split, content.hasAfter, imageSize.width > 0 else {
            knob.isHidden = true
            return
        }
        let visible = scroll.documentVisibleRect
        let x = content.bounds.width * CGFloat(split)
        let y = min(max(visible.midY, 0), content.bounds.height)
        let p = content.convert(NSPoint(x: x, y: y), to: self)
        knob.frame = NSRect(x: (p.x - 19).rounded(), y: (p.y - 19).rounded(), width: 38, height: 38)
        knob.isHidden = !(p.x >= 2 && p.x <= bounds.width - 2)
    }

    private func dragSplit(toWindowPoint p: NSPoint) {
        let local = content.convert(p, from: nil)
        split = Double(min(1, max(0, local.x / max(content.bounds.width, 1))))
        content.split = CGFloat(split)
        onSplit?(split)
        window?.invalidateCursorRects(for: content)
        positionKnob()
    }
}
#endif
