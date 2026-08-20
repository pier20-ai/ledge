import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The chat glass has to be readable over whatever is behind it.**
///
/// design.html drew the pane's gradient over the mockup's own dark page, where a
/// bottom stop of 18% reads as "nearly clear". Over a bright window it reads as
/// *nothing*: measured against white, ink-2 at the bottom of the pane came out
/// at 1.26:1 — below the 1.5:1 where two colours stop being distinguishable at
/// all — and the blank slot, which is this surface with no stage behind it and
/// therefore nothing but glass, was the worst case in the product.
///
/// Two changes answer it, and only one of them can be tested here:
///
///   · the gradient's floor is raised, which is arithmetic and is asserted; and
///   · an `NSVisualEffectView` frost blurs what is behind, which is a window
///     server effect that renders in no offscreen context and therefore cannot
///     be measured off-device.
///
/// So the contrast law is written against the **gradient alone**. The frost is
/// not allowed to be load-bearing: if it were, this suite would be asserting
/// something it cannot see.
@MainActor
@Suite("Chat glass legibility — readable over bright content")
struct ChatGlassLegibilityTests {
    // MARK: - Colour arithmetic (sRGB, WCAG)

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }

    private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let (a, b) = (luminance(lhs), luminance(rhs))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `over` composited onto opaque `under`.
    private static func composite(_ over: NSColor, on under: NSColor) -> NSColor {
        guard
            let top = over.usingColorSpace(.sRGB),
            let bottom = under.usingColorSpace(.sRGB)
        else { return under }
        let alpha = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * alpha + bottom.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + bottom.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + bottom.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    /// The pane's ground at `depth` (0 = under the notch, 1 = the bottom edge),
    /// over an opaque backdrop.
    private static func ground(at depth: CGFloat, over backdrop: NSColor) -> NSColor {
        let stops = LedgeGlass.chat
        var glass = stops[stops.count - 1].color
        for index in 0..<(stops.count - 1) where depth >= stops[index].at && depth <= stops[index + 1].at {
            let span = max(0.0001, stops[index + 1].at - stops[index].at)
            let fraction = (depth - stops[index].at) / span
            guard
                let a = stops[index].color.usingColorSpace(.sRGB),
                let b = stops[index + 1].color.usingColorSpace(.sRGB)
            else { break }
            glass = NSColor(
                srgbRed: a.redComponent + (b.redComponent - a.redComponent) * fraction,
                green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
                alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * fraction
            )
            break
        }
        return composite(glass, on: backdrop)
    }

    /// The worst backdrop there is, and the one a laptop is most often showing.
    private static let paperWhite = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // MARK: - The law

    @Test("Shell ink stays legible at the bottom of the pane, over white")
    func inkSurvivesTheBottomOfThePane() {
        let bottom = Self.ground(at: 1, over: Self.paperWhite)

        // ink-1 is the transcript's own voice, and it clears the 4.5:1 body-text
        // bar even at the very bottom edge.
        let primary = Self.composite(LedgeTheme.primary, on: bottom)
        #expect(
            Self.contrast(primary, bottom) >= 3.5,
            "ink-1 at the pane's floor: \(Self.contrast(primary, bottom))"
        )

        // ink-2 is the quiet register — placeholders, hints, the pill's own
        // label. It only has to be *readable*, but 1.26:1 was not readable, it
        // was absent.
        let secondary = Self.composite(LedgeTheme.secondary, on: bottom)
        #expect(
            Self.contrast(secondary, bottom) >= 2.2,
            "ink-2 at the pane's floor: \(Self.contrast(secondary, bottom))"
        )
    }

    @Test("…and it only gets better further up", arguments: [0.5, 0.7, 0.85] as [CGFloat])
    func legibilityIsMonotone(depth: CGFloat) {
        let here = Self.ground(at: depth, over: Self.paperWhite)
        let floor = Self.ground(at: 1, over: Self.paperWhite)
        // Darker ground higher up the pane, always: the gradient never brightens
        // as it descends, so the bottom edge is the only case worth arguing
        // about and every other depth is covered by the one above.
        #expect(Self.luminance(here) <= Self.luminance(floor) + 0.001)

        let ink = Self.composite(LedgeTheme.secondary, on: here)
        #expect(Self.contrast(ink, here) >= 2.2)
    }

    // MARK: - The gradient itself

    @Test("The floor is raised, and the character is unchanged")
    func gradientShape() {
        let stops = LedgeGlass.chat
        #expect(stops.count == 3)

        // Still opaque at the top — the pane meets the notch and the notch is
        // hardware.
        #expect(stops[0].at == 0)
        #expect(stops[0].color.alphaComponent >= 0.95)

        // Still clearest at the bottom, which is the whole point of the material
        // (flow.md: "the prompt pill sits where the glass is clearest").
        #expect(stops[2].at == 1)
        #expect(stops[2].color.alphaComponent < stops[1].color.alphaComponent)
        #expect(stops[1].color.alphaComponent < stops[0].color.alphaComponent)

        // …but the floor is a material now, not a suggestion. This is the
        // number the device judgement produced; anything under it puts the
        // prompt back on the wallpaper.
        #expect(stops[2].color.alphaComponent >= 0.55)

        // The inflection stays where design.html put it.
        #expect(stops[1].at == 0.55)
    }

    // MARK: - The frost

    /// It cannot be *measured* here, but it can be required to exist, to be
    /// shaped like the body, and — the setting that actually decides whether it
    /// does anything at all in Ledge's window — to be unconditionally active.
    @Test("The frost is masked to the same silhouette the body is cut to")
    func frostIsMaskedToTheBody() {
        let rect = CGRect(x: 0, y: 0, width: 440, height: 300)
        let path = ShellSurfaceView.notchPath(in: rect, topRadius: 12, bottomRadius: 26)
        let mask = ShellSurfaceView.maskImage(for: path, size: rect.size)

        let image = try? #require(mask)
        #expect(image?.size == rect.size)

        // Opaque inside the shape, clear outside it — otherwise the blur is a
        // rectangle behind a rounded body, which is the one way a frost can make
        // a surface look worse than no frost at all.
        guard
            let tiff = image?.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else {
            Issue.record("the mask did not rasterise")
            return
        }
        let inside = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        #expect((inside?.alphaComponent ?? 0) > 0.9, "the middle of the body is not masked in")
        // The top corners tuck under the menu bar, so they are outside the body.
        let corner = bitmap.colorAt(x: 1, y: 4)
        #expect((corner?.alphaComponent ?? 1) < 0.1, "the fillet's corner is not masked out")
    }

    @Test("A degenerate size asks for no mask rather than an empty one")
    func maskRefusesNonsense() {
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
        #expect(ShellSurfaceView.maskImage(for: path, size: .zero) == nil)
        #expect(ShellSurfaceView.maskImage(for: path, size: CGSize(width: 0, height: 40)) == nil)
    }

    /// The glass is a property of the *body*, and it is only ever on in a
    /// conversation. A frost left running behind a stage would blur the desktop
    /// under an opaque panel — invisible, and paid for every frame.
    @Test("Glass and frost are on together, and only in a conversation")
    func frostFollowsTheGlass() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        // In a real window, because that is the condition the frost is gated on
        // — behind-window blur with no window behind it is the material's opaque
        // fallback, which is why offscreen renders switch it off entirely.
        let window = NSWindow(
            contentRect: CGRect(x: -5000, y: -5000, width: 900, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(surface)

        func frost() -> NSVisualEffectView? {
            surface.subviews.compactMap { $0 as? NSVisualEffectView }.first
        }

        let effect = frost()
        #expect(effect != nil, "the frost was never installed")
        // The setting the whole thing hangs on: Ledge's panel is
        // `.nonactivatingPanel` and is never the active window, so the default
        // `.followsWindowActiveState` would disable the blur permanently.
        #expect(effect?.state == .active)
        #expect(effect?.blendingMode == .behindWindow)

        surface.setBodyMaterial(.solid)
        surface.present(.expanded(app: "chess"), content: nil, height: 300, animated: false)
        surface.layoutSubtreeIfNeeded()
        #expect(effect?.isHidden == true, "frosting behind an opaque stage")

        surface.setBodyMaterial(.chatGlass)
        surface.present(.chat(app: "chess"), content: nil, height: 300, animated: false)
        surface.layoutSubtreeIfNeeded()
        #expect(effect?.isHidden == false)
        #expect(effect?.maskImage != nil, "an unmasked frost is a rectangle")

        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()
        #expect(effect?.isHidden == true, "the collapsed pill is solid")
    }

    /// **The frost goes behind the gradient, and this is not automatic.**
    ///
    /// The body's material, the rim light and the attention glow are sublayers
    /// of the surface's *own* layer; the frost is a **subview**, and AppKit
    /// appends every subview's backing layer after all of them. Adding it first
    /// therefore put it on top — a slab of blurred material over the gradient it
    /// was meant to sit under, covering the rim light on the way past. It was
    /// invisible to every other test in the suite, because the blur renders as
    /// nothing at all off-screen.
    ///
    /// Two things have to hold and both have bitten: the layer must *exist*
    /// (AppKit creates it lazily, so an ordering set on a nil layer is a no-op
    /// that reads like a fix), and it must carry the negative rung.
    @Test("The frost is ordered under the body's own layers")
    func frostSitsUnderTheGlass() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        let frost = surface.subviews.compactMap { $0 as? NSVisualEffectView }.first
        guard let layer = frost?.layer else {
            Issue.record("the frost never got a backing layer")
            return
        }
        #expect(layer.zPosition == ShellSurfaceView.frostZPosition)
        #expect(ShellSurfaceView.frostZPosition < 0)

        // Everything it has to sit under is at the default rung, so one negative
        // step is the whole ordering — and nothing else may quietly join it
        // down there.
        for sublayer in surface.layer?.sublayers ?? [] where sublayer !== layer {
            #expect(
                sublayer.zPosition >= 0,
                "another layer went below the default rung and may now be under the frost"
            )
        }
    }

    /// The gate itself. Offscreen, the frost must be off whatever the mode —
    /// otherwise every snapshot of the chat pane is a grey block and the review
    /// pipeline is showing something the product never draws.
    @Test("Off screen there is nothing to blur, so there is no frost")
    func frostIsOffWithoutAWindow() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        surface.setBodyMaterial(.chatGlass)
        surface.present(.chat(app: "chess"), content: nil, height: 300, animated: false)
        surface.layoutSubtreeIfNeeded()

        let effect = surface.subviews.compactMap { $0 as? NSVisualEffectView }.first
        #expect(effect?.isHidden == true)
        // …and the gradient is still there, because the legibility does not
        // depend on the frost.
        #expect(surface.bodyMaterial == .chatGlass)
    }
}
