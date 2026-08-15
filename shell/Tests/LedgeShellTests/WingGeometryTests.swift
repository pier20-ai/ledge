import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The collapsed notch as a live-activity surface (spec §3.3 extension, §8's
/// "live-activity wings up to 340 × 34"). What these pin down is the geometry
/// contract: text sizes the left wing, a canvas sizes the right one, a bare
/// `width` is a total pill width split evenly, and none of it survives into the
/// expanded panel or outlives the app that asked for it.
@MainActor
@Suite("Notch wings (spec §3.3 extension)")
struct WingGeometryTests {
    private func makeSurface() -> ShellSurfaceView {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback                      // 210 × 34, the mockup
        surface.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        surface.present(.collapsed, content: nil, height: 0, animated: false)
        return surface
    }

    private func collapsedWidth(_ surface: ShellSurfaceView) -> CGFloat {
        surface.shapeSize(expanded: false, height: 0).width
    }

    private var fillets: CGFloat { ShellSurfaceView.fillet * 2 }

    @Test("No wing is the idle pill: exactly the hardware notch")
    func idlePill() {
        let surface = makeSurface()
        #expect(surface.wing == nil)
        #expect(collapsedWidth(surface) == 210 + fillets)
    }

    @Test("Text grows the left wing; a canvas grows the right one")
    func contentSizesWings() {
        let surface = makeSurface()
        let idle = collapsedWidth(surface)

        surface.setWing(WingSpec(text: "AAPL ▲ 1.2%"), animated: false)
        let withText = collapsedWidth(surface)
        #expect(withText > idle)

        surface.setWing(
            WingSpec(text: "AAPL ▲ 1.2%", canvas: WingCanvasSpec(id: 12, w: 64)),
            animated: false
        )
        let withBoth = collapsedWidth(surface)
        #expect(withBoth == withText + 64 + 24)          // canvas + its padding

        // Spec §8's ceiling: 210 + 65 a side ≈ 340. A wing may go a little past
        // that for a long label, but never unboundedly.
        #expect(withBoth <= 210 + PanelLimits.maxWingWidth * 2 + fillets)
    }

    @Test("A runaway label is clamped to one wing's maximum")
    func textIsClamped() {
        let surface = makeSurface()
        surface.setWing(WingSpec(text: String(repeating: "W", count: 200)), animated: false)
        #expect(collapsedWidth(surface) == 210 + PanelLimits.maxWingWidth + fillets)
    }

    @Test("A bare width request is a total pill width, split evenly (the breathing app)")
    func bareWidthIsSymmetric() {
        let surface = makeSurface()
        surface.setWing(WingSpec(width: 286), animated: false)
        // 286 total = 210 notch + 76 surplus, 38 a side.
        #expect(collapsedWidth(surface) == 286 + fillets)

        // Narrower than the hardware notch is not a thing you can ask for.
        surface.setWing(WingSpec(width: 100), animated: false)
        #expect(collapsedWidth(surface) == 210 + fillets)

        // Nor is a pill wider than two full wings.
        surface.setWing(WingSpec(width: 5000), animated: false)
        #expect(collapsedWidth(surface) == 210 + PanelLimits.maxWingWidth * 2 + fillets)
    }

    @Test("A width alongside content is a floor, not a replacement")
    func widthPadsContent() {
        let surface = makeSurface()
        surface.setWing(WingSpec(canvas: WingCanvasSpec(id: 1, w: 40)), animated: false)
        let contentOnly = collapsedWidth(surface)

        // A width the content already exceeds changes nothing…
        surface.setWing(
            WingSpec(width: 200, canvas: WingCanvasSpec(id: 1, w: 40)),
            animated: false
        )
        #expect(collapsedWidth(surface) == contentOnly)

        // …and a larger one pads both sides up to it.
        surface.setWing(
            WingSpec(width: 340, canvas: WingCanvasSpec(id: 1, w: 40)),
            animated: false
        )
        #expect(collapsedWidth(surface) == 340 + fillets)
    }

    @Test("Wings never touch the expanded panel")
    func expandedIgnoresWings() {
        let surface = makeSurface()
        surface.setWing(WingSpec(text: "live", canvas: WingCanvasSpec(id: 1, w: 80)), animated: false)
        // The visit is the panel's own width (G2.4: uniform, no bar band), and
        // the wing contributes nothing either way.
        let expanded = surface.shapeSize(expanded: true, width: 440, height: 300)
        #expect(expanded.width == 440 + fillets)

        surface.present(.expanded(app: "stocks"), content: nil, width: 440, height: 300, animated: false)
        // The wing is remembered — it comes back when the panel closes — but it
        // contributes nothing while the app owns the whole box.
        #expect(surface.wing != nil)
        #expect(surface.shapeSize(expanded: true, width: 440, height: 300).width
                == 440 + fillets)
    }

    @Test("Clearing returns the pill to idle; an empty spec is a clear")
    func clearing() {
        let surface = makeSurface()
        surface.setWing(WingSpec(text: "live"), animated: false)
        #expect(surface.wing != nil)

        surface.setWing(nil, animated: false)
        #expect(surface.wing == nil)
        #expect(collapsedWidth(surface) == 210 + fillets)

        // A wing that says nothing at all is indistinguishable from no wing.
        surface.setWing(WingSpec(), animated: false)
        #expect(surface.wing == nil)
    }

    @Test("Repeated width updates coalesce to the latest and stay additive with hover")
    func repeatedWidthUpdates() {
        let surface = makeSurface()
        // What a 2–10 Hz pacer does: many widths in a row. Each one replaces the
        // last (latest wins) rather than queueing, so the pill's width is always
        // the most recent request — the springs interpolate, the state does not.
        for width in stride(from: 220.0, through: 300.0, by: 4.0) {
            surface.setWing(WingSpec(width: width), animated: true)
        }
        #expect(surface.wing?.width == 300)
        #expect(collapsedWidth(surface) == 300 + fillets)
    }

    @Test("Wing content never intercepts the click that opens the panel")
    func wingContentIsClickThrough() {
        let surface = makeSurface()
        surface.setWing(
            WingSpec(text: "AAPL ▲ 1.2%", canvas: WingCanvasSpec(id: 12, w: 64)),
            animated: false
        )
        surface.layoutSubtreeIfNeeded()

        // Anywhere inside the pill must hit the surface itself (which opens the
        // panel), never the label or the canvas strip sitting on top of it.
        let shape = surface.currentShapeRect
        for x in stride(from: shape.minX + 4, to: shape.maxX - 4, by: 12) {
            let hit = surface.hitTest(CGPoint(x: x, y: shape.height / 2))
            #expect(hit != nil, "the pill itself must stay clickable at x=\(x)")
            #expect(!(hit is NSTextField), "the wing label swallowed a click at x=\(x)")
            #expect(hit !== surface.wingCanvasView, "the wing canvas swallowed a click at x=\(x)")
        }
    }

    // MARK: - The camera housing

    /// Where the wing's two pieces actually landed, in the surface's own
    /// coordinates — which is the space the hardware cutout is described in.
    private func contentFrames(_ surface: ShellSurfaceView) -> (label: CGRect, canvas: CGRect) {
        surface.layoutSubtreeIfNeeded()
        return (
            surface.convert(surface.wingLabelView.bounds, from: surface.wingLabelView),
            surface.convert(surface.wingCanvasView.bounds, from: surface.wingCanvasView)
        )
    }

    /// The bug this suite exists to keep fixed. The collapsed shape is anchored
    /// to the hardware cutout rather than centred on itself, because the cutout
    /// is a hole in the display and cannot move: a pill centred on its own width
    /// slides sideways by (left − right) / 2, and a wing with a label and nothing
    /// beside it — an alarm's countdown, the everyday case — is exactly the
    /// maximally asymmetric one. Half the label ended up behind the camera.
    @Test("A one-sided wing keeps its label clear of the camera housing")
    func labelNeverReachesUnderTheHousing() {
        let surface = makeSurface()
        // The alarm app's own string, emoji and all — the report that found this.
        surface.setWing(WingSpec(text: "⏰ 14:53 · 10m"), animated: false)
        let housing = surface.hardwareCutoutRect
        let frames = contentFrames(surface)

        #expect(frames.label.width > 0, "the label has to be somewhere")
        #expect(
            frames.label.maxX <= housing.minX,
            "the label ran to \(frames.label.maxX), under a housing that starts at \(housing.minX)"
        )
        // …and the pill itself still covers the cutout completely, which is the
        // reason it is drawn at all.
        let shape = surface.currentShapeRect
        #expect(shape.minX <= housing.minX && shape.maxX >= housing.maxX)
    }

    @Test("Neither wing crosses the housing, whatever the mix of content")
    func contentStaysInItsOwnWing() {
        let surface = makeSurface()
        for spec in [
            WingSpec(text: "⏰ 14:53 · 10m"),
            WingSpec(canvas: WingCanvasSpec(id: 12, w: 120)),
            WingSpec(text: "Now playing — a very long track title indeed",
                     canvas: WingCanvasSpec(id: 12, w: 64)),
            WingSpec(text: "sync", width: 340),
        ] {
            surface.setWing(spec, animated: false)
            let housing = surface.hardwareCutoutRect
            let frames = contentFrames(surface)
            if frames.label.width > 0 {
                #expect(frames.label.maxX <= housing.minX, "label under the housing for \(spec)")
            }
            if frames.canvas.width > 0 && spec.canvas != nil {
                #expect(frames.canvas.minX >= housing.maxX, "strip under the housing for \(spec)")
            }
        }
    }

    @Test("A label too long for its wing is truncated, never run on")
    func longLabelTruncates() {
        let surface = makeSurface()
        let text = "⏰ 06:00 · a label far longer than any wing can hold"
        surface.setWing(WingSpec(text: text), animated: false)
        let label = surface.wingLabelView
        surface.layoutSubtreeIfNeeded()

        let measured = (text as NSString).size(withAttributes: [.font: label.font as Any]).width
        #expect(label.frame.width < measured, "the frame must clamp, so the cell can ellipsize")
        #expect(label.frame.width <= PanelLimits.maxWingWidth)
        #expect(label.lineBreakMode == .byTruncatingTail)
        #expect(label.maximumNumberOfLines == 1)
    }

    // MARK: - The meter (flow.md's third wing form)

    @Test("A meter sizes the right wing to the shell's own width, not the app's")
    func meterSizesTheRightWing() throws {
        let surface = makeSurface()
        let idle = collapsedWidth(surface)

        surface.setWing(try Fixtures.wing("chrome-wing-meter.json"), animated: false)
        surface.layoutSubtreeIfNeeded()
        let meter = surface.wingMeterView
        #expect(!meter.isHidden)
        #expect(surface.wingCanvasView.isHidden)
        // 64 pt of bar plus the wing's own padding, exactly as a canvas of the
        // same width would have cost — the difference is who chose the 64.
        #expect(meter.bounds.width == LedgeMetrics.wingMeterWidth)
        #expect(collapsedWidth(surface) > idle)

        // Right wing, clear of the housing, and the bar is 3 pt centred in the
        // strip rather than filling it.
        let housing = surface.hardwareCutoutRect
        let placed = surface.convert(meter.bounds, from: meter)
        #expect(placed.minX >= housing.maxX)
        #expect(meter.trackFrame.height == LedgeMetrics.wingMeterHeight)
        #expect(abs(meter.trackFrame.midY - meter.bounds.midY) <= 0.5)
        #expect(meter.trackFrame.width == LedgeMetrics.wingMeterWidth)
        #expect(meter.fillFrame.width == (LedgeMetrics.wingMeterWidth * 0.42).rounded())
        #expect(meter.trackFrame.minY >= 0 && meter.trackFrame.maxY <= housing.height)
    }

    @Test("A meter value outside 0…1 clamps rather than overrunning its track")
    func meterClamps() throws {
        let surface = makeSurface()
        surface.setWing(try Fixtures.wing("chrome-wing-meter-clamp.json"), animated: false)
        surface.layoutSubtreeIfNeeded()
        let meter = surface.wingMeterView
        #expect(meter.fraction == 1)
        #expect(meter.fillFrame.width == meter.trackFrame.width)

        surface.setWing(WingSpec(meter: WingMeterSpec(value: -3)), animated: false)
        surface.layoutSubtreeIfNeeded()
        #expect(meter.fraction == 0)
        #expect(meter.fillFrame.width == 0)

        // A meter alone is a wing: it is content, so an empty-spec release must
        // not swallow it.
        #expect(surface.wing != nil)
        surface.setWing(nil, animated: false)
        #expect(surface.wingMeterView.isHidden)
    }

    @Test("Canvas and meter both claim the right wing; the app's own pixels win")
    func canvasBeatsMeter() {
        let surface = makeSurface()
        surface.setWing(
            WingSpec(canvas: WingCanvasSpec(id: 12, w: 100), meter: WingMeterSpec(value: 0.5)),
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        #expect(!surface.wingCanvasView.isHidden)
        #expect(surface.wingMeterView.isHidden)
        // …and the wing is the canvas' 100, not the meter's 64.
        #expect(collapsedWidth(surface) == 210 + fillets + 100 + 24)
    }

    @Test("Wing content never exceeds the notch strip's height")
    func contentFitsTheStrip() {
        let surface = makeSurface()
        surface.setWing(
            WingSpec(text: "⏰ 14:53 · 10m", canvas: WingCanvasSpec(id: 12, w: 64)),
            animated: false
        )
        let strip = surface.hardwareCutoutRect.height       // = metrics.closedHeight
        let frames = contentFrames(surface)
        #expect(frames.label.minY >= 0 && frames.label.maxY <= strip)
        #expect(frames.canvas.minY >= 0 && frames.canvas.maxY <= strip)
        #expect(surface.shapeSize(expanded: false, height: 0).height == strip)
    }
}
