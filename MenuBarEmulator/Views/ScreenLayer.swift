import SwiftUI
import QuartzCore

/// The live game picture, drawn with Core Animation: every frame goes straight from the emulator to a CALayer, so
/// SwiftUI never re-renders per frame. `crop` picks one DS screen out of the core's top-over-bottom frame; the bottom
/// DS screen also takes the mouse as the stylus. Clicking anywhere else on the picture drags the window.
struct ScreenLayer: NSViewRepresentable {
    enum Crop { case full, top, bottom }

    let emulator: Emulator
    var crop: Crop = .full
    var filter: Display.Filter = .sharp
    /// Separate DS windows can show the touch screen in either half after a screen swap.
    var touchScreen = false
    /// Double-click (not on the touch screen) = full screen.
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.crop = crop
        view.filter = filter
        view.touchScreen = touchScreen
        view.onDoubleClick = onDoubleClick
        view.emulator = emulator
        view.observer = emulator.addFrameObserver { [weak view] image in view?.show(image) }
        if view.current == nil, let snapshot = emulator.snapshot { view.show(snapshot) }
        return view
    }

    func updateNSView(_ view: ScreenView, context: Context) {
        view.crop = crop
        view.filter = filter
        view.touchScreen = touchScreen
        view.onDoubleClick = onDoubleClick
    }

    static func dismantleNSView(_ view: ScreenView, coordinator: ()) {
        if let id = view.observer { view.emulator?.removeFrameObserver(id) }
    }
}

final class ScreenView: NSView {
    weak var emulator: Emulator?
    var observer: UUID?
    var touchScreen = false
    var onDoubleClick: (() -> Void)?
    var crop: ScreenLayer.Crop = .full {
        didSet { if crop != oldValue, let source { show(source) } }
    }
    var filter: Display.Filter = .sharp {
        didSet { picture.magnificationFilter = filter == .smooth ? .linear : .nearest }
    }
    /// What's on screen (already cropped), also used when the view is drawn into an image.
    private(set) var current: CGImage?
    private var source: CGImage?
    let picture = CALayer()
    /// The stylus tip on the touch screen: pops in where you tap, trails a glow as you drag, shrinks away on release.
    let tip = CALayer()
    private var lastTrail: CGPoint?
    /// Lifts the tip once the button's really up: the mouse-up doesn't always reach this view.
    private var liftWatch: Timer?
    private var lastStylusEvent: CFTimeInterval = 0
    /// Where the stylus last touched, so a lift the view never heard about still reaches the game.
    private var lastTouch = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        picture.contentsGravity = .resize
        picture.magnificationFilter = .nearest
        picture.minificationFilter = .trilinear
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
        tip.isHidden = true
        tip.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        tip.borderColor = NSColor.black.withAlphaComponent(0.3).cgColor
        tip.borderWidth = 1
        tip.shadowColor = NSColor.black.cgColor
        tip.shadowOpacity = 0.45
        tip.shadowRadius = 3
        tip.shadowOffset = .zero
        tip.actions = ["position": NSNull(), "bounds": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(tip)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Game screen")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // The picture layer must follow every size change (window resizes don't always trigger layout()),
    // or a stale size leaves the game off-center and cut off.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitPicture()
    }

    override func layout() {
        super.layout()
        fitPicture()
    }

    private func fitPicture() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        picture.contentsScale = window?.backingScaleFactor ?? 2
    }

    func show(_ image: CGImage) {
        source = image
        let half = image.height / 2
        let cropped: CGImage? = switch crop {
        case .full: image
        case .top: image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: half))
        case .bottom: image.cropping(to: CGRect(x: 0, y: half, width: image.width, height: half))
        }
        current = cropped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = cropped
        CATransaction.commit()
    }

    /// Only used when the view is rendered into an image (screenshots of the UI); live frames use the layer.
    override func draw(_ dirtyRect: NSRect) {
        guard let current else { return }
        NSImage(cgImage: current, size: .zero).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                                                    hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
    }

    // MARK: Mouse: DS stylus on a touch screen, window drag everywhere else

    override var mouseDownCanMoveWindow: Bool { !touchScreen }

    /// The separate touch-screen window never becomes key, so its first click must count as a tap.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard touchScreen else {
            if event.clickCount == 2, let onDoubleClick { return onDoubleClick() }
            return window?.performDrag(with: event) ?? ()
        }
        touch(event, down: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touchScreen else { return super.mouseDragged(with: event) }
        touch(event, down: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard touchScreen else { return super.mouseUp(with: event) }
        touch(event, down: false)
    }

    private func touch(_ event: NSEvent, down: Bool) {
        let point = convert(event.locationInWindow, from: nil) // flipped: y counts down from the top
        lastTouch = Self.normalizedTouch(point, in: bounds.size, crop: crop)
        emulator?.touch(normalized: lastTouch, down: down)
        showStylus(at: point, landing: event.type == .leftMouseDown, down: down)
    }

    // MARK: Stylus indicator

    private func showStylus(at point: CGPoint, landing: Bool, down: Bool) {
        let size = max(9, bounds.width * 0.034)
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tip.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        tip.cornerRadius = size / 2
        tip.position = point
        if down { tip.isHidden = false; tip.opacity = 1 }
        CATransaction.commit()
        if down {
            lastStylusEvent = CACurrentMediaTime()
            tip.removeAnimation(forKey: "lift")
            watchForLift()
        }

        if landing {
            tip.removeAllAnimations()
            lastTrail = point
            guard !calm else { return }
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.3
            pop.toValue = 1
            pop.damping = 11
            pop.duration = pop.settlingDuration
            tip.add(pop, forKey: "pop")
            fade(ring(at: point, size: size), scale: (0.6, 2.8), duration: 0.5)
        } else if down {
            guard !calm, let last = lastTrail, hypot(point.x - last.x, point.y - last.y) > size * 0.45 else { return }
            lastTrail = point
            let glow = dot(at: point, size: size * 0.55)
            fade(glow, scale: (1, 0.3), duration: 0.32)
        } else {
            liftStylus()
        }
    }

    private func watchForLift() {
        guard liftWatch == nil else { return }
        liftWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                // Button up and no stylus events for a moment (trackpad tap-drag sends drags with no button down).
                guard NSEvent.pressedMouseButtons & 1 == 0, CACurrentMediaTime() - self.lastStylusEvent > 0.25 else { return }
                self.emulator?.touch(normalized: self.lastTouch, down: false)
                self.liftStylus()
            }
        }
    }

    private func liftStylus() {
        liftWatch?.invalidate()
        liftWatch = nil
        lastTrail = nil
        guard !tip.isHidden, tip.opacity > 0 else { return }
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let lift = CABasicAnimation(keyPath: "transform.scale")
        lift.fromValue = 1
        lift.toValue = 0.3
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        let group = CAAnimationGroup()
        group.animations = calm ? [out] : [lift, out]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tip.opacity = 0
        CATransaction.commit()
        tip.add(group, forKey: "lift")
    }

    /// A ring that ripples out from where the stylus lands.
    private func ring(at point: CGPoint, size: CGFloat) -> CALayer {
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: size * 1.4, height: size * 1.4)
        ring.cornerRadius = size * 0.7
        ring.position = point
        ring.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        ring.borderWidth = 2
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 2
        ring.shadowOffset = .zero
        return ring
    }

    private func dot(at point: CGPoint, size: CGFloat) -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.position = point
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        return dot
    }

    /// Adds `layer` under the tip, scales and fades it out, then removes it.
    private func fade(_ layer: CALayer, scale: (CGFloat, CGFloat), duration: CFTimeInterval) {
        layer.opacity = 0
        self.layer?.insertSublayer(layer, below: tip)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = scale.0
        grow.toValue = scale.1
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 0.9
        out.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, out]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.add(group, forKey: "fade")
        CATransaction.commit()
    }

    static func normalizedTouch(_ point: CGPoint, in size: CGSize, crop: ScreenLayer.Crop) -> CGPoint {
        let x = size.width > 0 ? point.x / size.width : 0, y = size.height > 0 ? point.y / size.height : 0
        return CGPoint(x: x, y: (crop == .top ? 0 : 0.5) + y / 2)
    }
}

/// Thin dark lines between pixels, like an old handheld LCD. Skipped when pixels are too small to show it.
struct LCDGrid: View {
    let columns: Int
    let rows: Int

    var body: some View {
        Canvas { context, size in
            let dx = size.width / CGFloat(columns), dy = size.height / CGFloat(rows)
            guard dx >= 2, dy >= 2 else { return }
            var path = Path()
            for i in 1..<columns { path.addRect(CGRect(x: CGFloat(i) * dx, y: 0, width: 0.01, height: size.height)) }
            for j in 1..<rows { path.addRect(CGRect(x: 0, y: CGFloat(j) * dy, width: size.width, height: 0.01)) }
            context.stroke(path, with: .color(.black.opacity(0.22)), lineWidth: max(0.5, dx * 0.16))
        }
        .allowsHitTesting(false)
    }
}
