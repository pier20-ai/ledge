import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The design system's laws (docs/design/design.html, D7), asserted where they
/// were broken: measured centering, the capsule rule, the size ramp, the disabled
/// state, min/max/step, and multi-line text.
///
/// Every case drives the real `ProtocolEngine` → `ProtocolRenderer` path from the
/// golden fixtures, so a law that only holds when a Swift test constructs the view
/// by hand does not count.
@MainActor
@Suite("Design system — controls (D4/D6/D7)")
struct DesignSystemTests {
    private func makeStack() -> (ProtocolEngine, ProtocolRenderer) {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        return (engine, renderer)
    }

    /// Lay the app's tree out at the panel width, the way the panel controller
    /// does — nothing about centering is decidable before layout has run.
    private func layout(_ renderer: ProtocolRenderer, app: String, width: CGFloat = 440) {
        guard let root = renderer.rootView(for: app) else { return }
        root.translatesAutoresizingMaskIntoConstraints = true
        root.frame = CGRect(x: 0, y: 0, width: width, height: ceil(root.fittingSize.height))
        root.layoutSubtreeIfNeeded()
    }

    private func mountControls() throws -> (ProtocolEngine, ProtocolRenderer) {
        let (engine, renderer) = makeStack()
        engine.receive(try Fixtures.envelope("commit-control-props.json"))
        layout(renderer, app: "gallery")
        return (engine, renderer)
    }

    // MARK: - L2: measured centering, empty content = zero width, zero gap

    @Test("Icon-only button is square and its glyph is dead center (D1's defect)")
    func iconOnlyIsCenteredSquare() throws {
        let (_, renderer) = try mountControls()
        let button = try #require(renderer.view(app: "gallery", id: 5) as? LedgeButton)

        #expect(button.isIconOnly)
        // Zero label width AND zero gap ⇒ the frame is a square at the size's
        // height. This is the whole bug: 10 pt of phantom content used to make it
        // wider than tall and pull the glyph 5 pt left.
        #expect(button.intrinsicContentSize.width == button.intrinsicContentSize.height)
        #expect(button.intrinsicContentSize.height == LedgeMetrics.Size.m.height)
        #expect(button.labelFrame.width == 0)

        let icon = try #require(button.iconFrame)
        #expect(abs(icon.midX - button.bounds.midX) < 0.51)
        #expect(abs(icon.midY - button.bounds.midY) < 0.51)
    }

    @Test("A labeled button pays for its gap; an empty one does not")
    func labeledButtonKeepsItsGap() throws {
        let (_, renderer) = try mountControls()
        let labeled = try #require(renderer.view(app: "gallery", id: 3) as? LedgeButton)
        let iconOnly = try #require(renderer.view(app: "gallery", id: 5) as? LedgeButton)

        #expect(!labeled.isIconOnly)
        #expect(labeled.labelFrame.width > 0)
        #expect(labeled.iconFrame == nil)                  // no icon on this one
        // Icon-only glyphs are 14 pt medium; a labeled button's stay 11 semibold
        // (D8/Q3) — the same symbol at two sizes depending on company.
        #expect(iconOnly.iconPointSize == LedgeMetrics.iconOnlyPointSize)
    }

    @Test("An icon-only button that gains a label re-measures its glyph")
    func crossingTheIconOnlyBoundary() throws {
        let (engine, renderer) = try mountControls()
        let button = try #require(renderer.view(app: "gallery", id: 5) as? LedgeButton)
        #expect(button.iconPointSize == LedgeMetrics.iconOnlyPointSize)

        engine.receive(Envelope(
            app: "gallery",
            seq: 20,
            type: "commit",
            payload: .object(["mutations": .array([
                .object(["op": .string("update"), "id": .int(5), "props": .object([
                    "label": .string("Play"),
                ])]),
            ])])
        ))
        #expect(!button.isIconOnly)
        #expect(button.iconPointSize == LedgeMetrics.buttonIconPointSize)
        #expect(button.intrinsicContentSize.width > button.intrinsicContentSize.height)
    }

    // MARK: - L3: the capsule rule

    @Test("Every control is a capsule with a continuous corner")
    func capsuleRadii() throws {
        let (_, renderer) = try mountControls()

        for id in [2, 3, 4, 5, 6] {
            let button = try #require(renderer.view(app: "gallery", id: id) as? LedgeButton)
            let expected = LedgeMetrics.capsule(button.bounds.height)
            #expect(button.layer?.cornerRadius == expected, "button \(id)")
            #expect(button.layer?.cornerCurve == .continuous, "button \(id)")
        }

        // The card tier lost its arbitrary 10 (D4): boxes are 12 now.
        #expect(RoundedBoxView().layer?.cornerRadius == LedgeMetrics.rCard)
        #expect(RoundedBoxView().layer?.cornerCurve == .continuous)
    }

    @Test("Input is a capsule at the ratified 34 pt height (D8/Q2)")
    func inputIsCapsule() throws {
        let (engine, renderer) = makeStack()
        engine.receive(Envelope(app: "ask", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("input"),
                         "props": .object(["placeholder": .string("Ask anything…")])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        layout(renderer, app: "ask")
        let input = try #require(renderer.view(app: "ask", id: 2) as? LedgeInput)
        #expect(input.bounds.height == LedgeMetrics.inputHeight)
        #expect(input.layer?.cornerRadius == LedgeMetrics.capsule(LedgeMetrics.inputHeight))
        #expect(input.layer?.cornerCurve == .continuous)
    }

    // MARK: - D8/Q4: the size ramp

    @Test("size s/m/l set height and pad, on create and on update")
    func sizeRamp() throws {
        let (engine, renderer) = try mountControls()
        let small = try #require(renderer.view(app: "gallery", id: 2) as? LedgeButton)
        let medium = try #require(renderer.view(app: "gallery", id: 3) as? LedgeButton)
        let large = try #require(renderer.view(app: "gallery", id: 4) as? LedgeButton)

        #expect(small.currentSize == .s)
        #expect(medium.currentSize == .m)                  // absent prop ⇒ default
        #expect(large.currentSize == .l)
        #expect(small.intrinsicContentSize.height == 28)
        #expect(medium.intrinsicContentSize.height == 34)
        #expect(large.intrinsicContentSize.height == 40)

        // The same three labels at three sizes: pad-x is what separates them.
        let sameLabelDelta = large.intrinsicContentSize.width - small.intrinsicContentSize.width
        #expect(sameLabelDelta != 0)

        engine.receive(try Fixtures.envelope("commit-control-props-update.json"))
        layout(renderer, app: "gallery")
        #expect(small.currentSize == .l)                   // s → l in place
        #expect(large.currentSize == .s)                   // l → s in place
        #expect(small.intrinsicContentSize.height == 40)

        // An icon-only button's *square* tracks the ramp too.
        let iconOnly = try #require(renderer.view(app: "gallery", id: 5) as? LedgeButton)
        #expect(iconOnly.currentSize == .l)
        #expect(iconOnly.intrinsicContentSize == NSSize(width: 40, height: 40))
    }

    // MARK: - D6: the disabled state

    @Test("disabled dims content, refuses hover and press, and never calls back")
    func disabledButton() throws {
        let (engine, renderer) = try mountControls()
        let button = try #require(renderer.view(app: "gallery", id: 6) as? LedgeButton)
        #expect(button.isDisabled)
        #expect(button.contentAlpha == LedgeMetrics.disabledAlpha)
        #expect(!button.isEnabled)

        // The guard is the first line of `mouseDown`, before any event tracking,
        // so a synthetic press proves the handler is not reached.
        var fired = 0
        renderer.onEvent = { _, _, _, _ in fired += 1 }
        let press = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        button.mouseDown(with: press)
        #expect(fired == 0)
        #expect(button.layer?.affineTransform().isIdentity == true)     // no press scale

        // Deleting the prop (null, §3.1) has to re-enable it, not read as
        // "unchanged" — the create-only-prop bug in its other direction.
        engine.receive(try Fixtures.envelope("commit-control-props-update.json"))
        #expect(!button.isDisabled)
        #expect(button.contentAlpha == 1)
        #expect(button.isEnabled)
    }

    // MARK: - D6: slider min/max/step

    @Test("Slider honors min/max/step; the value is in the app's own scale")
    func sliderRange() throws {
        let (engine, renderer) = try mountControls()
        let slider = try #require(renderer.view(app: "gallery", id: 7) as? LedgeSlider)

        #expect(slider.rangeMin == 60)
        #expect(slider.rangeMax == 200)
        #expect(slider.step == 5)
        #expect(slider.value == 90)
        // Position stays a 0…1 fraction of the track: only the number changed space.
        #expect(abs(slider.position - (90.0 - 60) / 140) < 0.0001)

        engine.receive(try Fixtures.envelope("commit-control-props-update.json"))
        #expect(slider.value == 145)                       // already on the grid

        slider.value = 143                                 // snaps to the step grid
        #expect(slider.value == 145)
        slider.value = 1_000                               // clamps at max
        #expect(slider.value == 200)
        slider.value = 0                                   // clamps at min
        #expect(slider.value == 60)
    }

    @Test("A slider that declares nothing is still 0…1 (music's scrub bar)")
    func sliderDefaultsUnchanged() throws {
        let (engine, renderer) = makeStack()
        engine.receive(Envelope(app: "music", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("slider"),
                         "props": .object(["value": .double(0.46)])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2), "before": .null]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        let slider = try #require(renderer.view(app: "music", id: 2) as? LedgeSlider)
        #expect(slider.rangeMin == 0)
        #expect(slider.rangeMax == 1)
        #expect(slider.step == nil)
        #expect(slider.value == 0.46)
    }

    // MARK: - L7: text never wraps silently

    @Test("maxLines wraps to N lines and reports the wrapped height")
    func textMaxLines() throws {
        let (engine, renderer) = try mountControls()
        let wrapped = try #require(renderer.view(app: "gallery", id: 8) as? LedgeText)
        let clipped = try #require(renderer.view(app: "gallery", id: 9) as? LedgeText)

        #expect(wrapped.lineLimit == 3)
        #expect(wrapped.maximumNumberOfLines == 3)
        // Wrap first, ellipsize the last visible line — `.byTruncatingTail` here
        // would clear `cell.wraps` and quietly put it back to one line.
        #expect(wrapped.lineBreakMode == .byWordWrapping)
        #expect(wrapped.cell?.wraps == true)
        #expect((wrapped.cell as? NSTextFieldCell)?.truncatesLastVisibleLine == true)
        #expect(clipped.lineLimit == 1)
        #expect(clipped.truncates == false)
        #expect(clipped.lineBreakMode == .byClipping)

        // The whole point: at a narrow column the label reports the height of the
        // lines it will actually draw. An NSTextField left to itself reports one.
        wrapped.translatesAutoresizingMaskIntoConstraints = true
        wrapped.frame = CGRect(x: 0, y: 0, width: 180, height: 20)
        wrapped.layout()
        let threeLines = wrapped.intrinsicContentSize.height

        let single = LedgeText(wrapped.stringValue)
        single.font = wrapped.font
        let oneLine = single.intrinsicContentSize.height
        #expect(threeLines > oneLine * 2)
        #expect(threeLines < oneLine * 4)                  // capped at three, not free

        // Dropping back to one line is a real change, not "unchanged".
        engine.receive(try Fixtures.envelope("commit-control-props-update.json"))
        #expect(wrapped.lineLimit == 1)
        #expect(clipped.truncates == true)
        #expect(clipped.lineBreakMode == .byTruncatingTail)
    }

    // MARK: - L1: one ruler

    @Test("Theme carries the tokens that replaced the component literals")
    func literalsBecameTokens() {
        #expect(LedgeTheme.raisedHover2.alphaComponent == 0.10)
        #expect(LedgeTheme.hairlineHover.alphaComponent == 0.14)
        #expect(LedgeTheme.inkFill.alphaComponent == 0.85)
        #expect(LedgeTheme.selected.alphaComponent == 0.12)
        // A pill's tone is always a triple from one family (L9).
        for tone in LedgePill.Tone.allCases {
            #expect(tone.ink.alphaComponent > 0)
            #expect(tone.tint.alphaComponent > 0)
            #expect(tone.stroke.alphaComponent > 0)
        }
    }

    @Test("The radius scale is the two rules, not nine values")
    func radiusScale() {
        #expect(LedgeMetrics.rChip == 8)
        #expect(LedgeMetrics.rCard == 12)
        #expect(LedgeMetrics.rContent == 14)
        #expect(LedgeMetrics.rPanel == 26)
        // Concentric: content is the panel minus the 12 pt inset.
        #expect(LedgeMetrics.rContent == LedgeMetrics.rPanel - LedgeMetrics.padCard)
        // Capsule: a 34 pt control is 17, a 20 pt pill is 10.
        #expect(LedgeMetrics.capsule(34) == 17)
        #expect(LedgeMetrics.capsule(LedgeMetrics.pillHeight) == 10)
    }
}
