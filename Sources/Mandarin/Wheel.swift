import AppKit

enum WheelMode { case drag, click }

enum Palette {
    static let peach = NSColor(srgbRed: 1.0, green: 0.88, blue: 0.76, alpha: 0.96)
    static let peachOuter = NSColor(srgbRed: 1.0, green: 0.83, blue: 0.68, alpha: 0.96)
    static let tangerine = NSColor(srgbRed: 0.96, green: 0.40, blue: 0.18, alpha: 1)
    static let tangerineLight = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.30, alpha: 1)
    static let brown = NSColor(srgbRed: 0.45, green: 0.22, blue: 0.08, alpha: 1)
}

@MainActor
final class WheelController {
    static let shared = WheelController()
    private var panel: WheelPanel?
    private(set) var mode: WheelMode = .drag
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible == true }

    func show(urls: [URL], at point: NSPoint, mode: WheelMode) {
        hideWork?.cancel()
        let rings = WheelItem.rings(for: urls)
        guard !rings.inner.isEmpty || !rings.outer.isEmpty else {
            if mode == .click { HUD.shared.error("Этот тип файла пока не поддерживается") }
            return
        }
        self.mode = mode
        let panel = self.panel ?? WheelPanel()
        self.panel = panel

        let wheel = panel.wheel
        wheel.mode = mode
        wheel.label = WheelItem.normalized(urls[0].pathExtension).uppercased()
        wheel.countBadge = urls.count > 1 ? urls.count : 0
        wheel.inner = rings.inner
        wheel.outer = rings.outer
        wheel.clickURLs = urls
        wheel.hovered = .none
        wheel.onPick = { [weak self] item, dropped in
            self?.hide()
            Converter.run(item, urls: dropped, at: point)
        }
        wheel.onCancel = { [weak self] in self?.hide() }
        panel.updateMask()
        wheel.needsDisplay = true

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        panel.alphaValue = 0
        if mode == .click { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        panel.invalidateShadow()
        panel.popIn()
    }

    func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

final class WheelPanel: NSPanel {
    let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
    private let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 440))
        root.wantsLayer = true
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .aqua)
        root.addSubview(effect)
        root.addSubview(wheel)
        contentView = root
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { WheelController.shared.hide() }

    func updateMask() {
        let r = wheel.discRadius
        let size = effect.bounds.size
        effect.maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2)).fill()
            return true
        }
    }

    func popIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            animator().alphaValue = 1
        }
        guard let layer = contentView?.layer else { return }
        let b = contentView!.bounds
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: b.midX, y: b.midY)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.55
        spring.toValue = 1.0
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 18
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }
}

final class WheelView: NSView {
    enum Hit: Equatable { case none, center, item(Int, Int) }

    var inner: [WheelItem] = []
    var outer: [WheelItem] = []
    var label = ""
    var countBadge = 0
    var mode: WheelMode = .drag
    var clickURLs: [URL] = []
    var onPick: ((WheelItem, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    var hovered: Hit = .none {
        didSet {
            guard hovered != oldValue else { return }
            if case .item = hovered {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            needsDisplay = true
        }
    }

    private let rCenter: CGFloat = 46
    private let r1a: CGFloat = 54, r1b: CGFloat = 126
    private let r2a: CGFloat = 132, r2b: CGFloat = 200
    private var c: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    var discRadius: CGFloat { (outer.isEmpty ? r1b : r2b) + 10 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    func hit(_ p: NSPoint) -> Hit {
        let dx = p.x - c.x, dy = p.y - c.y
        let d = hypot(dx, dy)
        if d <= rCenter + 4 { return .center }
        let ring: Int
        let items: [WheelItem]
        if d >= r1a - 4 && d <= r1b + 3 {
            ring = 0; items = inner
        } else if !outer.isEmpty && d > r1b + 3 && d <= r2b + 8 {
            ring = 1; items = outer
        } else {
            return .none
        }
        guard !items.isEmpty else { return .none }
        let seg = 360 / CGFloat(items.count)
        var t = 90 - atan2(dy, dx) * 180 / .pi + seg / 2
        t = t.truncatingRemainder(dividingBy: 360)
        if t < 0 { t += 360 }
        return .item(ring, min(Int(t / seg), items.count - 1))
    }

    private func segmentPath(_ i: Int, of n: Int, ra: CGFloat, rb: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineJoinStyle = .round
        if n == 1 {
            p.appendOval(in: NSRect(x: c.x - rb, y: c.y - rb, width: rb * 2, height: rb * 2))
            p.appendOval(in: NSRect(x: c.x - ra, y: c.y - ra, width: ra * 2, height: ra * 2))
            p.windingRule = .evenOdd
            return p
        }
        let seg = 360 / CGFloat(n)
        let th = 90 - CGFloat(i) * seg
        let gap: CGFloat = 10
        let go = (gap / 2) / rb * 180 / .pi
        let gi = (gap / 2) / ra * 180 / .pi
        p.appendArc(withCenter: c, radius: rb, startAngle: th + seg / 2 - go, endAngle: th - seg / 2 + go, clockwise: true)
        p.appendArc(withCenter: c, radius: ra, startAngle: th - seg / 2 + gi, endAngle: th + seg / 2 - gi, clockwise: false)
        p.close()
        return p
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let R = discRadius
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        NSColor(srgbRed: 1, green: 0.74, blue: 0.52, alpha: 0.30).setFill()
        disc.fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        disc.lineWidth = 1
        disc.stroke()

        drawRing(inner, ring: 0, ra: r1a, rb: r1b, base: Palette.peach)
        drawRing(outer, ring: 1, ra: r2a, rb: r2b, base: Palette.peachOuter)
        drawCenter()
    }

    private func drawRing(_ items: [WheelItem], ring: Int, ra: CGFloat, rb: CGFloat, base: NSColor) {
        for (i, item) in items.enumerated() {
            let on = hovered == .item(ring, i)
            let path = segmentPath(i, of: items.count, ra: on ? ra - 2 : ra, rb: on ? rb + 5 : rb)
            let fill = on ? Palette.tangerine : base
            fill.setFill()
            fill.setStroke()
            path.lineWidth = 5
            path.fill()
            path.stroke()
            if on {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                NSGradient(starting: Palette.tangerineLight.withAlphaComponent(0.9), ending: Palette.tangerine.withAlphaComponent(0))?
                    .draw(in: path.bounds, angle: 90)
                NSGraphicsContext.restoreGraphicsState()
            }

            let seg = 360 / CGFloat(items.count)
            let th = (90 - CGFloat(i) * seg) * .pi / 180
            let mid = (ra + rb) / 2
            let pos = CGPoint(x: c.x + cos(th) * mid, y: c.y + sin(th) * mid)
            let color: NSColor = on ? .white : Palette.brown
            if let sym = item.symbol {
                drawSymbol(sym, at: CGPoint(x: pos.x, y: pos.y + 8), size: 17, color: color)
                drawText(item.title, at: CGPoint(x: pos.x, y: pos.y - 12), font: .systemFont(ofSize: 10.5, weight: .semibold), color: color)
            } else {
                drawText(item.title, at: pos, font: .systemFont(ofSize: 14, weight: .bold), color: color)
            }
        }
    }

    private func drawCenter() {
        let on = hovered == .center
        let r = rCenter
        let circle = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let grad = on
            ? NSGradient(starting: NSColor(srgbRed: 0.55, green: 0.30, blue: 0.20, alpha: 1), ending: NSColor(srgbRed: 0.40, green: 0.20, blue: 0.12, alpha: 1))
            : NSGradient(starting: Palette.tangerineLight, ending: Palette.tangerine)
        grad?.draw(in: circle, angle: -90)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        if on {
            drawSymbol("xmark", at: CGPoint(x: c.x, y: c.y + 7), size: 16, color: .white)
            drawText("Отмена", at: CGPoint(x: c.x, y: c.y - 13), font: .systemFont(ofSize: 10, weight: .semibold), color: .white)
        } else {
            drawText(label, at: CGPoint(x: c.x, y: c.y + (countBadge > 0 ? 6 : 0)), font: .systemFont(ofSize: 15, weight: .heavy), color: .white)
            if countBadge > 0 {
                drawText(plural(countBadge, "файл", "файла", "файлов"), at: CGPoint(x: c.x, y: c.y - 13), font: .systemFont(ofSize: 9.5, weight: .semibold), color: .white.withAlphaComponent(0.9))
            }
        }
    }

    private func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
    }

    private func drawSymbol(_ name: String, at p: CGPoint, size: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = img.size
        img.draw(in: NSRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height))
    }

    private func item(for hit: Hit) -> WheelItem? {
        guard case let .item(ring, i) = hit else { return nil }
        let items = ring == 0 ? inner : outer
        return i < items.count ? items[i] : nil
    }

    // MARK: Drag & drop

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = hit(convert(sender.draggingLocation, from: nil))
        return item(for: hovered) != nil ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = .none }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let picked = item(for: hit(convert(sender.draggingLocation, from: nil)))
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard let picked, !urls.isEmpty else {
            onCancel?()
            return false
        }
        DispatchQueue.main.async { self.onPick?(picked, urls) }
        return true
    }

    // MARK: Click mode

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .click else { return }
        hovered = hit(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if mode == .click { hovered = .none }
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .click else { return }
        if let picked = item(for: hit(convert(event.locationInWindow, from: nil))) {
            onPick?(picked, clickURLs)
        } else {
            onCancel?()
        }
    }
}

enum Icons {
    static func menuBar() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let body = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 1.5, width: 13, height: 13))
            body.lineWidth = 1.6
            body.stroke()
            for k in 0..<6 {
                let a = CGFloat(k) * .pi / 3
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 9 + cos(a) * 2.2, y: 8 + sin(a) * 2.2))
                line.line(to: NSPoint(x: 9 + cos(a) * 5, y: 8 + sin(a) * 5))
                line.lineWidth = 1.1
                line.stroke()
            }
            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: 9, y: 14.2))
            leaf.curve(to: NSPoint(x: 15.5, y: 17), controlPoint1: NSPoint(x: 10.5, y: 17.5), controlPoint2: NSPoint(x: 13.5, y: 17.8))
            leaf.curve(to: NSPoint(x: 9, y: 14.2), controlPoint1: NSPoint(x: 14, y: 15), controlPoint2: NSPoint(x: 11, y: 14))
            leaf.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
