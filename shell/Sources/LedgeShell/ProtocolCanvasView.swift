import AppKit
import LedgeShellCore
import QuartzCore

/// A `canvas` node's pixel surface (spec §3.4). Draw op lists are rendered into
/// an offscreen buffer and blitted on the next display; the engine's coalescer
/// already collapses faster-than-refresh frames to the latest per canvas, so the
/// view only ever holds one buffered image.
final class ProtocolCanvasView: NSView {
    /// Fires when a focused canvas gets a key (spec §4.1 `key`).
    var onKey: ((_ key: String, _ down: Bool) -> Void)?
    var focusable = false

    /// Drop the rounded card behind the pixels. A canvas in a panel is a surface
    /// *on* the panel and reads better with one; a canvas in a notch wing IS the
    /// pill, so anything behind it is a seam.
    var chromeless = false {
        didSet {
            guard chromeless != oldValue else { return }
            applyChrome()
        }
    }

    private var buffer: NSImage?

    /// Whether a frame has actually been rendered into this canvas — how a test
    /// asks "did that draw land here?" without comparing pixels.
    var hasBuffer: Bool { buffer != nil }

    override var isFlipped: Bool { true }              // §3.4 ops use top-left y
    override var acceptsFirstResponder: Bool { focusable }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        applyChrome()
        setAccessibilityRole(.image)
        setAccessibilityLabel("Canvas")
    }

    private func applyChrome() {
        // Implicit layer animations would cross-fade this on every toggle.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A canvas sits on a `sunken` mat at the chip tier (D6): the pixels are
        // the app's, the frame is the shell's.
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = chromeless ? 0 : LedgeMetrics.canvasRadius
        layer?.backgroundColor = chromeless
            ? NSColor.clear.cgColor
            : LedgeTheme.sunken.cgColor
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Render `ops` into the offscreen buffer and request a blit. Latest wins.
    func apply(ops: [JSONValue]) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        for op in ops {
            draw(op: op)
        }
        image.unlockFocus()
        buffer = image
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        buffer?.draw(in: bounds)
    }

    /// Click with canvas-local coordinates (same y-down space as draw ops).
    var onClick: ((CGPoint) -> Void)?

    /// Press-drag-release with a phase and canvas-local coordinates (spec §4.1
    /// `drag`). `phase` is `down` / `move` / `up`; the point is in the same
    /// y-down space as `onClick` and the draw ops.
    ///
    /// **The point is not clamped to the view.** A scrubber the user drags past
    /// the edge of the canvas has to keep tracking — that is what makes a knob
    /// feel held rather than dropped — so a `move` may report a negative x or
    /// one past the width, and the app decides what its own edges mean.
    var onDrag: ((_ phase: String, _ point: CGPoint) -> Void)?

    /// Shell-side throttle for `move` (spec §4.1): a fast wiggle across a
    /// trackpad produces events far faster than the panel can redraw, and every
    /// one of them would be a frame on the socket. `down` and `up` are never
    /// throttled — they are the phases an app builds state machines out of.
    static let dragMoveInterval: CFTimeInterval = 1.0 / 30
    /// Per-view override of the throttle, for tests that want every move.
    var dragMoveInterval: CFTimeInterval = ProtocolCanvasView.dragMoveInterval

    /// Whether the app declared `onDrag` (spec §5). Resolved from the merged
    /// prop set on every commit, like every other prop — so a canvas that starts
    /// passing a handler mid-session starts getting the phases, and one that
    /// stops paying attention stops paying for the traffic.
    var dragEnabled = false

    private var lastMoveTime: CFTimeInterval = 0

    override func mouseDown(with event: NSEvent) {
        if focusable { window?.makeFirstResponder(self) }
        let point = localPoint(for: event)
        // Both, when both are asked for: a canvas that only wants the scrub
        // simply passes no `onClick`, and one that only wants taps passes no
        // `onDrag`. Synthesizing one from the other would make the shell guess
        // at a gesture threshold on the app's behalf.
        onClick?(point)
        guard dragEnabled, let onDrag else { return }
        lastMoveTime = 0
        onDrag("down", point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled, let onDrag else {
            super.mouseDragged(with: event)
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastMoveTime >= dragMoveInterval else { return }
        lastMoveTime = now
        onDrag("move", localPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragEnabled, let onDrag else {
            super.mouseUp(with: event)
            return
        }
        // Always sent, and it carries the final position — so a coalesced
        // `move` is never the last word on where the gesture ended.
        lastMoveTime = 0
        onDrag("up", localPoint(for: event))
    }

    /// Window coordinates → canvas-local, y-down (§3.4).
    private func localPoint(for event: NSEvent) -> CGPoint {
        var point = convert(event.locationInWindow, from: nil)
        if !isFlipped {
            point.y = bounds.height - point.y
        }
        return point
    }

    override func keyDown(with event: NSEvent) {
        guard focusable, let onKey else {
            super.keyDown(with: event)
            return
        }
        onKey(Self.keyName(for: event), true)
    }

    override func keyUp(with event: NSEvent) {
        guard focusable, let onKey else {
            super.keyUp(with: event)
            return
        }
        onKey(Self.keyName(for: event), false)
    }

    // MARK: - Ops

    private func draw(op: JSONValue) {
        guard let object = op.asObject, let name = object["op"]?.asString else { return }
        switch name {
        case "clear":
            // Transparent clear of the whole surface.
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
        case "rect":
            let rect = CGRect(
                x: number(object["x"]), y: number(object["y"]),
                width: number(object["w"]), height: number(object["h"])
            )
            let radius = number(object["radius"])
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            (Self.color(object["fill"]?.asString) ?? .white).setFill()
            path.fill()
        case "line":
            guard let points = object["points"]?.asArray, points.count > 1 else { return }
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                guard let pair = point.asArray, pair.count == 2 else { continue }
                let cgPoint = CGPoint(x: number(pair[0]), y: number(pair[1]))
                index == 0 ? path.move(to: cgPoint) : path.line(to: cgPoint)
            }
            path.lineWidth = object["width"]?.asDouble.map { CGFloat($0) } ?? 1
            (Self.color(object["stroke"]?.asString) ?? .white).setStroke()
            path.stroke()
        case "gradient":
            drawGradient(object)
        case "image":
            drawImage(object)
        case "text":
            guard let content = object["content"]?.asString else { return }
            let size = object["size"]?.asDouble.map { CGFloat($0) } ?? 11
            let attributes: [NSAttributedString.Key: Any] = [
                .font: LedgeTheme.systemFont(size),
                .foregroundColor: Self.color(object["color"]?.asString) ?? NSColor.white,
            ]
            content.draw(
                at: CGPoint(x: number(object["x"]), y: number(object["y"])),
                withAttributes: attributes
            )
        default:
            break                               // unknown ops are skipped (§3.4)
        }
    }

    /// `{ "op": "gradient", "x", "y", "w", "h", "from", "to", "angle"?, "radius"? }`
    /// — an axial gradient filling one rect (spec §3.4).
    ///
    /// Free-form on purpose, unlike `stack.gradient`: a canvas is pixels the app
    /// owns, so it names real colors (hex, like every other op) and a real
    /// direction. `angle` is **degrees clockwise from top-to-bottom**, matching
    /// the y-down op space — 0 washes downward, 90 to the right — and defaults
    /// to 0. `radius` rounds the rect exactly as it does for `rect`.
    private func drawGradient(_ object: [String: JSONValue]) {
        let rect = CGRect(
            x: number(object["x"]), y: number(object["y"]),
            width: number(object["w"]), height: number(object["h"])
        )
        guard rect.width > 0, rect.height > 0,
              let from = Self.color(object["from"]?.asString),
              let to = Self.color(object["to"]?.asString),
              let gradient = NSGradient(starting: from, ending: to),
              let context = NSGraphicsContext.current?.cgContext else { return }

        let radians = (object["angle"]?.asDouble ?? 0) * .pi / 180
        let direction = CGVector(dx: sin(radians), dy: cos(radians))
        // Half the rect's extent *along the gradient's own axis*, so the ramp
        // spans exactly the rect however it is angled — a 45° wash that stopped
        // at half the width would leave a hard band in the far corner.
        let half = (abs(rect.width * direction.dx) + abs(rect.height * direction.dy)) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)

        context.saveGState()
        let radius = number(object["radius"])
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).setClip()
        gradient.draw(
            from: CGPoint(x: center.x - direction.dx * half, y: center.y - direction.dy * half),
            to: CGPoint(x: center.x + direction.dx * half, y: center.y + direction.dy * half),
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )
        context.restoreGState()
    }

    /// `{ "op": "image", "src", "x", "y", "w", "h", "sx"?, "sy"?, "sw"?, "sh"? }`
    /// — a file image, or one cell of a spritesheet (spec §3.4; ops may be added
    /// without a version bump, and an older shell skips this one).
    ///
    /// `src` is an absolute path (apps build it from `import.meta.dir`).
    /// `sx/sy/sw/sh` select a source rect in **image pixels**, origin top-left
    /// like every other coordinate in §3.4; omitting `sw`/`sh` draws the whole
    /// image. Decoding is cached across canvases by `LedgeImageStore`, so a game
    /// blitting one sheet at frame rate touches the file about once a second.
    private func drawImage(_ object: [String: JSONValue]) {
        guard let path = object["src"]?.asString,
              let source = LedgeImageStore.shared.cgImage(atPath: path) else { return }
        let destination = CGRect(
            x: number(object["x"]), y: number(object["y"]),
            width: number(object["w"]), height: number(object["h"])
        )
        guard destination.width > 0, destination.height > 0 else { return }

        var cell = source
        if let sw = object["sw"]?.asDouble, let sh = object["sh"]?.asDouble, sw > 0, sh > 0 {
            // `CGImage.cropping` works in pixels with the origin at the top-left
            // — the same space the op names, so the cell rect needs no flip.
            let rect = CGRect(
                x: number(object["sx"]), y: number(object["sy"]),
                width: CGFloat(sw), height: CGFloat(sh)
            ).intersection(CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height)))
            guard !rect.isNull, rect.width >= 1, rect.height >= 1,
                  let cropped = source.cropping(to: rect) else { return }
            cell = cropped
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // A pixel sprite blown up must stay crisp; a photo scaled down must not
        // alias. Which one this is, is exactly the direction of the scale.
        let magnifying = destination.width >= CGFloat(cell.width)
            && destination.height >= CGFloat(cell.height)
        context.interpolationQuality = magnifying ? .none : .high
        // Op space is y-down (this view is flipped, §3.4) but `CGContext.draw` is
        // y-up, so an image drawn straight in lands upside down. Flip about the
        // destination rect rather than the whole surface, so `x`/`y` keep meaning
        // what every other op means by them.
        context.translateBy(x: 0, y: destination.midY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -destination.midY)
        context.draw(cell, in: destination)
        context.restoreGState()
    }

    private func number(_ value: JSONValue?) -> CGFloat {
        value?.asDouble.map { CGFloat($0) } ?? 0
    }

    /// Parse `#RGB`, `#RRGGBB`, or `#RRGGBBAA`.
    static func color(_ string: String?) -> NSColor? {
        guard var hex = string, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 49: return " "
        case 36: return "Enter"
        default: return event.charactersIgnoringModifiers ?? ""
        }
    }
}
