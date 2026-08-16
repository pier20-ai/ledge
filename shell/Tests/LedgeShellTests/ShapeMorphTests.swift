import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// **The open animation's in-between shapes** (principle 6 "one material, one
/// body", principle 10 "motion is the personality").
///
/// On device, expanding the pill into a visit passed through silhouettes that
/// were not silhouettes: a warped black blob with drooping lobes. The cause was
/// not the spring and not the geometry — both endpoints were correct — it was
/// that the two endpoints were *differently shaped paths*.
///
/// `CAShapeLayer.path` interpolates by walking both paths' elements in lockstep
/// and lerping control points. That is only meaningful when the element counts
/// and types match. The collapsed pill emitted 9 elements (`MQLQLQLQZ`); an
/// expanded visit emitted 15 (`MQLLQLQLQLQLLQZ`), because three segments of the
/// bar shoulder were behind an `if let shoulder`. Core Animation paired a quad
/// against a line and the bottom-left corner against the shoulder, and drew the
/// blob.
///
/// So the invariant these tests defend is **structural**, not visual: one
/// element sequence for every presentation the surface can be in. The visual
/// consequence — that a lerp between any two of them is a sane bar over a sane
/// panel — is then free, and `interpolatedShapesStaySane` checks it holds.
@MainActor
@Suite("Shape morphing — every in-between is a silhouette")
struct ShapeMorphTests {
    // MARK: - Path introspection

    private struct Element: Equatable {
        var type: CGPathElementType
        var points: [CGPoint]
    }

    private static func elements(of path: CGPath) -> [Element] {
        var out: [Element] = []
        path.applyWithBlock { raw in
            let type = raw.pointee.type
            let count: Int = switch type {
            case .moveToPoint, .addLineToPoint: 1
            case .addQuadCurveToPoint: 2
            case .addCurveToPoint: 3
            case .closeSubpath: 0
            @unknown default: 0
            }
            out.append(
                Element(type: type, points: (0..<count).map { raw.pointee.points[$0] })
            )
        }
        return out
    }

    private static func signature(of path: CGPath) -> String {
        elements(of: path).map { element in
            switch element.type {
            case .moveToPoint: "M"
            case .addLineToPoint: "L"
            case .addQuadCurveToPoint: "Q"
            case .addCurveToPoint: "C"
            case .closeSubpath: "Z"
            @unknown default: "?"
            }
        }.joined()
    }

    /// Exactly what CoreAnimation does when the structures *do* match: pair the
    /// elements by index and lerp every control point. Rebuilding it here is the
    /// point — if the real paths ever stop matching, this refuses to run.
    private static func lerp(_ from: CGPath, _ to: CGPath, _ t: CGFloat) -> CGPath {
        let a = elements(of: from)
        let b = elements(of: to)
        #expect(a.count == b.count, "structures must match to interpolate")

        let path = CGMutablePath()
        for (lhs, rhs) in zip(a, b) {
            #expect(lhs.type == rhs.type)
            let points = zip(lhs.points, rhs.points).map { p, q in
                CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
            }
            switch lhs.type {
            case .moveToPoint: path.move(to: points[0])
            case .addLineToPoint: path.addLine(to: points[0])
            case .addQuadCurveToPoint: path.addQuadCurve(to: points[1], control: points[0])
            case .addCurveToPoint:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closeSubpath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }

    // MARK: - The shapes under test

    private static let fillet = ShellSurfaceView.fillet
    private static let notch = NotchMetrics.fallback          // 210 × 34
    private static var barWidth: CGFloat { notch.closedWidth + LedgeMetrics.visitBarWing * 2 }

    /// The collapsed pill, as `applyGeometry` builds it: no wings, a zero-radius
    /// joint clamped into the 34 pt side.
    private static func pill() -> CGPath {
        let rect = CGRect(x: 0, y: 0, width: notch.closedWidth + fillet * 2, height: notch.closedHeight)
        let body = rect.insetBy(dx: fillet, dy: 0)
        return ShellSurfaceView.notchPath(
            in: rect,
            topRadius: fillet,
            bottomRadius: 12,
            shoulder: .init(
                panel: body,
                y: min(notch.closedHeight, max(fillet, rect.height - 12)),
                radius: 0
            )
        )
    }

    /// An expanded visit `width` wide, as `applyGeometry` builds it since
    /// G2.4/G2.5: one uniform width top to bottom, floored at the islands'
    /// span, with the shoulder joint permanently degenerate — kept in the path
    /// only so every presentation shares one element signature.
    private static func visit(width: CGFloat, height: CGFloat = 300) -> CGPath {
        let shapeWidth = max(width, barWidth) + fillet * 2
        let rect = CGRect(x: 0, y: 0, width: shapeWidth, height: height)
        let panel = rect.insetBy(dx: fillet, dy: 0)
        return ShellSurfaceView.notchPath(
            in: rect,
            topRadius: fillet,
            bottomRadius: 26,
            shoulder: .init(
                panel: panel,
                y: min(notch.closedHeight, max(fillet, height - 26)),
                radius: 0
            )
        )
    }

    // MARK: - The structural law

    @Test("Every shape the surface can be is the same element sequence")
    func oneStructureForEveryShape() {
        // The literal is the assertion: a shape that stops matching this string
        // cannot be animated to or from any other shape.
        let expected = "MQLLQLQLQLQLLQZ"

        #expect(Self.signature(of: Self.pill()) == expected)
        // A narrow session — the panel hangs, the shoulder is a real fillet.
        #expect(Self.signature(of: Self.visit(width: 360)) == expected)
        // A session exactly as wide as the bar: the shoulder degenerates.
        #expect(Self.signature(of: Self.visit(width: Self.barWidth)) == expected)
        // A session wider than the bar — the shape follows the panel.
        #expect(Self.signature(of: Self.visit(width: 640)) == expected)
        // A swell: between the two, and drawn by the same builder.
        #expect(Self.signature(of: Self.visit(width: 300, height: 120)) == expected)
    }

    @Test("A zero-radius joint draws the pill it always drew")
    func degenerateJointIsInvisible() {
        // The three shoulder segments collapse to zero length, so the *rendered*
        // outline is unchanged even though the element count is not. Fill the
        // path and the old one and compare where the ink lands.
        let rect = CGRect(x: 0, y: 0, width: 234, height: 34)
        let path = Self.pill()
        #expect(path.boundingBox == rect)

        // Every point that should be inside the pill is, and the corners the
        // fillets cut away are not.
        #expect(path.contains(CGPoint(x: 117, y: 17)))
        #expect(path.contains(CGPoint(x: 20, y: 30)))
        #expect(path.contains(CGPoint(x: 214, y: 30)))
        // The top corners tuck *under* the menu bar: the fillet is convex there,
        // so a point just inside the rect's corner is outside the shape.
        #expect(!path.contains(CGPoint(x: 1, y: 10)))
        #expect(!path.contains(CGPoint(x: 233, y: 10)))
        // …and the bottom corners are rounded away too.
        #expect(!path.contains(CGPoint(x: 0.5, y: 33.5)))
    }

    // MARK: - The visual consequence

    @Test("Interpolating pill → visit never leaves the silhouette")
    func interpolatedShapesStaySane() {
        let from = Self.pill()
        let to = Self.visit(width: 360)

        var lastWidth: CGFloat = 0
        var lastHeight: CGFloat = 0
        for t in stride(from: 0 as CGFloat, through: 1, by: 0.05) {
            let path = Self.lerp(from, to, t)
            let box = path.boundingBox

            // It is still one closed body of the right structure.
            #expect(Self.signature(of: path) == "MQLLQLQLQLQLLQZ", "t=\(t)")

            // It grows monotonically in both axes — no lobe swinging out and
            // back, which is exactly what the blob did.
            #expect(box.width >= lastWidth - 0.01, "width went backwards at t=\(t)")
            #expect(box.height >= lastHeight - 0.01, "height went backwards at t=\(t)")
            lastWidth = box.width
            lastHeight = box.height

            // It stays anchored to the top of the screen and never grows past
            // either endpoint's extent.
            #expect(box.minY == 0, "t=\(t)")
            #expect(box.height <= to.boundingBox.height + 0.01, "t=\(t)")
            #expect(box.width <= to.boundingBox.width + 0.01, "t=\(t)")

            // The centre of the body is filled at every depth: a drooping lobe
            // leaves the middle of the shape empty, which is what made the
            // device frames read as two things instead of one.
            let mid = box.midX
            for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] as [CGFloat] {
                let y = box.minY + box.height * fraction
                #expect(path.contains(CGPoint(x: mid, y: y)), "hole at t=\(t) y=\(y)")
            }
        }
    }

    @Test("The bar never narrows past the panel hanging from it")
    func barAlwaysAtLeastAsWideAsPanel() {
        // The one ordering that makes the silhouette a bar-over-panel rather
        // than a panel-over-bar. It holds at both ends, so linear interpolation
        // preserves it — but only because the joint is in both paths.
        let from = Self.pill()
        let to = Self.visit(width: 360)

        for t in stride(from: 0 as CGFloat, through: 1, by: 0.05) {
            let path = Self.lerp(from, to, t)
            let box = path.boundingBox
            // Sample the outline just below the top fillet (the bar) and just
            // above the bottom fillet (the panel).
            let barY = box.minY + Self.fillet + 1
            let panelY = box.maxY - 27
            guard panelY > barY else { continue }

            let barSpan = Self.span(of: path, atY: barY)
            let panelSpan = Self.span(of: path, atY: panelY)
            #expect(barSpan.width >= panelSpan.width - 0.5, "panel wider than bar at t=\(t)")
            // Both are centred on the same axis — a lopsided in-between is the
            // "drooping lobe" signature.
            #expect(abs(barSpan.midX - panelSpan.midX) < 0.5, "off-axis at t=\(t)")
        }
    }

    /// Where the filled shape starts and stops along one scanline.
    private static func span(of path: CGPath, atY y: CGFloat) -> (midX: CGFloat, width: CGFloat) {
        let box = path.boundingBox
        var first: CGFloat?
        var last: CGFloat?
        var x = box.minX
        while x <= box.maxX {
            if path.contains(CGPoint(x: x, y: y)) {
                if first == nil { first = x }
                last = x
            }
            x += 0.5
        }
        guard let first, let last else { return (box.midX, 0) }
        return ((first + last) / 2, last - first)
    }

    // MARK: - The surface itself

    @Test("The live surface's path keeps the structure across a real open")
    func liveSurfaceKeepsStructure() {
        let surface = ShellSurfaceView(callbacks: .inert)
        surface.metrics = .fallback
        surface.frame = CGRect(x: 0, y: 0, width: 900, height: 700)

        surface.present(.collapsed, content: nil, height: 0, animated: false)
        surface.layoutSubtreeIfNeeded()
        let collapsed = surface.currentSilhouette
        #expect(Self.signature(of: collapsed) == "MQLLQLQLQLQLLQZ")

        surface.present(
            .expanded(app: "chess"),
            content: FlippedView(),
            height: 300,
            animated: false
        )
        surface.layoutSubtreeIfNeeded()
        let expanded = surface.currentSilhouette
        #expect(Self.signature(of: expanded) == "MQLLQLQLQLQLLQZ")

        // The two are genuinely different shapes — otherwise the test above is
        // asserting nothing.
        #expect(collapsed.boundingBox != expanded.boundingBox)

        // And CoreAnimation can therefore interpolate them.
        let half = Self.lerp(collapsed, expanded, 0.5)
        #expect(half.boundingBox.width > collapsed.boundingBox.width)
        #expect(half.boundingBox.width < expanded.boundingBox.width)
    }
}
