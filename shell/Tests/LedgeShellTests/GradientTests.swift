import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// Gradients, in the two shapes the platform has (ticket 0001 A7): the
/// **standardized wash** a `stack` may declare as a token (spec §5), and the
/// free-form `gradient` draw op inside a `canvas` (§3.4). The split is the
/// design — a container names a hue and the shell owns the recipe, a canvas
/// names real colors and a real angle — so both halves are pinned here.
@MainActor
@Suite("Gradients: container wash & canvas op (spec §5, §3.4)")
struct GradientTests {
    // MARK: - The container wash

    private func mount(_ props: [String: JSONValue]) -> (ProtocolRenderer, LedgeStackView) {
        let renderer = ProtocolRenderer()
        renderer.applyCommit(app: "music", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: props),
            Mutation(op: .setRoot, id: 1),
        ])
        return (renderer, renderer.view(app: "music", id: 1) as! LedgeStackView)
    }

    @Test("A `gradient` token installs a wash in the hue it names")
    func washFollowsTheToken() {
        let (_, stack) = mount(["axis": .string("v"), "gradient": .string("violet")])
        #expect(stack.washColor == LedgeTheme.violet)
        // Behind the children, not on the background: `fill` is still free.
        #expect(stack.layer?.sublayers?.first is CAGradientLayer)
    }

    @Test("Every token resolves to a theme hue, and an unknown one to nothing")
    func tokenVocabulary() {
        #expect(ProtocolRenderer.gradientToken("accent") == LedgeTheme.accent)
        #expect(ProtocolRenderer.gradientToken("green") == LedgeTheme.green)
        #expect(ProtocolRenderer.gradientToken("red") == LedgeTheme.red)
        #expect(ProtocolRenderer.gradientToken("violet") == LedgeTheme.violet)
        #expect(ProtocolRenderer.gradientToken("cyan") == LedgeTheme.cyan)
        // Not an error and not a guess: a future token renders as no wash on an
        // older shell, exactly as `fill`/`stroke` already degrade.
        #expect(ProtocolRenderer.gradientToken("sepia") == nil)
        #expect(ProtocolRenderer.gradientToken("#1DB9A6") == nil)
        #expect(ProtocolRenderer.gradientToken(nil) == nil)
    }

    @Test("A wash and a fill coexist; dropping the token takes the wash away")
    func washUpdatesInPlace() {
        let renderer = ProtocolRenderer()
        renderer.applyCommit(app: "music", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: [
                "axis": .string("v"), "fill": .string("raised"), "gradient": .string("cyan"),
            ]),
            Mutation(op: .setRoot, id: 1),
        ])
        let stack = renderer.view(app: "music", id: 1) as! LedgeStackView
        #expect(stack.washColor == LedgeTheme.cyan)
        #expect(stack.layer?.backgroundColor == LedgeTheme.raised.cgColor)

        renderer.applyCommit(app: "music", mutations: [
            Mutation(op: .update, id: 1, props: ["gradient": .string("green")]),
        ])
        #expect(stack.washColor == LedgeTheme.green)

        // Deleted with null (§3.1): resolved from the merged prop set, so it
        // really goes rather than reading as "unchanged".
        renderer.applyCommit(app: "music", mutations: [
            Mutation(op: .update, id: 1, props: ["gradient": .null]),
        ])
        #expect(stack.washColor == nil)
        #expect(stack.layer?.sublayers?.contains(where: { $0 is CAGradientLayer }) != true)
    }

    @Test("The wash tracks the container's bounds")
    func washResizesWithTheStack() {
        let (_, stack) = mount(["axis": .string("v"), "gradient": .string("accent")])
        stack.frame = CGRect(x: 0, y: 0, width: 440, height: 120)
        stack.layout()
        let wash = stack.layer?.sublayers?.first as? CAGradientLayer
        #expect(wash?.frame == stack.bounds)
    }

    // MARK: - The canvas op

    /// Draw an op list into a canvas and read the pixels back — the same path a
    /// live frame takes.
    private func render(_ ops: [JSONValue], size: CGSize) throws -> NSBitmapImageRep {
        let canvas = ProtocolCanvasView(frame: CGRect(origin: .zero, size: size))
        canvas.chromeless = true
        canvas.apply(ops: ops)
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        canvas.cacheDisplay(in: canvas.bounds, to: representation)
        return representation
    }

    /// Sampled in **pixel** coordinates, which `NSBitmapImageRep` counts from
    /// the top-left — the same way §3.4 ops count.
    private func sample(_ representation: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try #require(representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    @Test("`gradient` ramps from `from` to `to`, downward by default")
    func verticalRamp() throws {
        let pixels = try render([
            .object([
                "op": .string("gradient"),
                "x": .int(0), "y": .int(0), "w": .int(40), "h": .int(40),
                "from": .string("#000000"), "to": .string("#FFFFFF"),
            ]),
        ], size: CGSize(width: 40, height: 40))

        // Angle 0 is top-to-bottom in the op space (y-down), so the dark end is
        // at the top — the same direction `y` counts.
        let top = try sample(pixels, x: 20, y: 1)
        let bottom = try sample(pixels, x: 20, y: 38)
        #expect(top.brightnessComponent < 0.15)
        #expect(bottom.brightnessComponent > 0.85)
        // No sideways ramp: a vertical wash is flat across the row.
        let otherTop = try sample(pixels, x: 4, y: 1)
        #expect(abs(otherTop.brightnessComponent - top.brightnessComponent) < 0.05)
    }

    @Test("`angle` turns the ramp clockwise: 90° washes to the right")
    func angledRamp() throws {
        let pixels = try render([
            .object([
                "op": .string("gradient"),
                "x": .int(0), "y": .int(0), "w": .int(40), "h": .int(40),
                "from": .string("#000000"), "to": .string("#FFFFFF"),
                "angle": .int(90),
            ]),
        ], size: CGSize(width: 40, height: 40))

        let left = try sample(pixels, x: 1, y: 20)
        let right = try sample(pixels, x: 38, y: 20)
        #expect(left.brightnessComponent < 0.15)
        #expect(right.brightnessComponent > 0.85)
    }

    @Test("The op fills only its own rect, and rounds it when asked")
    func boundedByItsRect() throws {
        let pixels = try render([
            .object([
                "op": .string("gradient"),
                "x": .int(10), "y": .int(10), "w": .int(20), "h": .int(20),
                "radius": .int(10),
                "from": .string("#FFFFFF"), "to": .string("#FFFFFF"),
            ]),
        ], size: CGSize(width: 40, height: 40))

        #expect(try sample(pixels, x: 20, y: 20).brightnessComponent > 0.85)
        // Outside the rect entirely…
        #expect(try sample(pixels, x: 2, y: 2).alphaComponent < 0.1)
        // …and outside the *rounded* corner of it, which a square clip would
        // have painted.
        #expect(try sample(pixels, x: 11, y: 11).alphaComponent < 0.5)
    }

    @Test("A gradient op missing a color is skipped, like any op the shell can't read")
    func malformedOpIsSkipped() throws {
        let pixels = try render([
            .object([
                "op": .string("gradient"),
                "x": .int(0), "y": .int(0), "w": .int(40), "h": .int(40),
                "from": .string("#FFFFFF"),
            ]),
        ], size: CGSize(width: 40, height: 40))
        #expect(try sample(pixels, x: 20, y: 20).alphaComponent < 0.1)
    }
}
