import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// `stack.align` (spec §5) — the cross-axis alignment, driven from the golden
/// `commit-align` pair.
///
/// Two bugs met here, and both were silent. The renderer switched on
/// `start`/`end` while the spec and the JSX types say `leading`/`trailing`, so
/// the documented words did nothing at all; and the column's fill constraints
/// stretched every label to the full width, so even `center` — the one word
/// that did arrive — could not move a line, because an `NSTextField` stretched
/// to 440 pt draws its glyphs on the left. All three exercise apps had grown the
/// same spacer/text/spacer helper to work around it.
@MainActor
@Suite("stack.align (spec §5)")
struct StackAlignTests {
    private func mount(_ fixture: String = "commit-align.json") throws -> (ProtocolEngine, ProtocolRenderer) {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        engine.receive(try Fixtures.envelope(fixture))
        layout(renderer)
        return (engine, renderer)
    }

    /// Lay the tree out the way the shell does: the app's root inside a host
    /// view of the panel's width, autoresized to it (`ShellSurfaceView`'s
    /// `contentHost`). The host matters — a root floating with no superview has
    /// no width constraint at all, so the solver is free to widen the *column*
    /// to fit an over-long line instead of compressing the line.
    private func layout(_ renderer: ProtocolRenderer) {
        guard let root = renderer.rootView(for: "timer") else { return }
        let host = FlippedView(frame: CGRect(x: 0, y: 0, width: 440, height: 2000))
        root.translatesAutoresizingMaskIntoConstraints = true
        root.frame = CGRect(x: 0, y: 0, width: 440, height: ceil(root.fittingSize.height))
        root.autoresizingMask = [.width]
        host.addSubview(root)
        host.layoutSubtreeIfNeeded()
    }

    private func stack(_ renderer: ProtocolRenderer, _ id: Int) throws -> LedgeStackView {
        try #require(renderer.view(app: "timer", id: id) as? LedgeStackView)
    }

    /// A view's **alignment rect** — what Auto Layout actually positions.
    /// `NSTextField` claims 2 pt either side of its frame for a focus ring it
    /// never draws, so a label's frame is 4 pt wider than the box it occupies;
    /// asserting on frames would be asserting on that allowance.
    private func box(_ view: NSView) -> CGRect {
        view.alignmentRect(forFrame: view.frame)
    }

    @Test("`leading`/`center`/`trailing` are the words, and `start`/`end` still work")
    func vocabulary() throws {
        let (_, renderer) = try mount()
        // v-stacks: the cross axis is horizontal.
        #expect(try stack(renderer, 1).alignment == .centerX)
        #expect(try stack(renderer, 7).alignment == .leading)
        // An h-stack's cross axis is vertical, so the same three words mean
        // top/middle/bottom — `trailing` is the bottom edge.
        #expect(try stack(renderer, 5).alignment == .bottom)

        // The old vocabulary is an alias, not a casualty: a tree written against
        // the renderer's former words keeps working.
        let root = try stack(renderer, 1)
        for (word, expected) in [("start", NSLayoutConstraint.Attribute.leading),
                                 ("end", .trailing),
                                 ("center", .centerX)] {
            renderer.applyCommit(app: "timer", mutations: [
                Mutation(op: .update, id: 1, props: ["align": .string(word)]),
            ])
            #expect(root.alignment == expected, "align=\(word)")
        }

        // A word nobody has heard of falls back to the axis default rather than
        // being guessed at — a forward-compatible tree lays out plainly instead
        // of inheriting whatever the last commit happened to say.
        renderer.applyCommit(app: "timer", mutations: [
            Mutation(op: .update, id: 1, props: ["align": .string("middle-ish")]),
        ])
        #expect(root.alignment == .leading)
    }

    @Test("A centred column sizes its text to the words and puts it in the middle")
    func centredTextIsCentred() throws {
        let (_, renderer) = try mount()
        let column = try stack(renderer, 1)
        let eyebrow = try #require(renderer.view(app: "timer", id: 2))
        let numeral = try #require(renderer.view(app: "timer", id: 3))

        for label in [eyebrow, numeral] {
            // Natural width — not the column's. This is the whole bug: a
            // stretched label draws left however the stack is aligned.
            #expect(box(label).width < column.frame.width - 32,
                    "a centred label was stretched to \(box(label).width)")
            #expect(box(label).width == ceil(label.intrinsicContentSize.width))
            // …and centred on the column, within a point of rounding.
            #expect(abs(box(label).midX - column.bounds.midX) <= 1,
                    "midX \(box(label).midX) vs column \(column.bounds.midX)")
        }
        // The eyebrow and the numeral are different widths — proof they are
        // measured rather than sharing one stretched box.
        #expect(box(eyebrow).width != box(numeral).width)
    }

    @Test("A child with no width of its own still spans the centred column")
    func dividersStillSpan() throws {
        let (_, renderer) = try mount()
        let column = try stack(renderer, 1)
        let divider = try #require(renderer.view(app: "timer", id: 4) as? LedgeDividerView)
        // "Centred" for a rule would resolve to zero, so a `LedgeColumnFilling`
        // child keeps the fill constraint whatever the alignment says.
        #expect(divider.frame.width == column.frame.width - 32)   // pad 16 either side
        #expect(divider.frame.height == LedgeMetrics.hairline)
    }

    @Test("Leading is still the default and still stretches — nothing else moved")
    func leadingStillFills() throws {
        let (engine, renderer) = try mount()
        // Before: id 7 is a hugging child of a centred column.
        let nested = try stack(renderer, 7)
        let flush = try #require(renderer.view(app: "timer", id: 8))
        #expect(nested.frame.width < 200)

        engine.receive(try Fixtures.envelope("commit-align-update.json"))
        layout(renderer)

        // The root went back to `leading`: its children stretch again, which is
        // the behaviour every app written before this change depends on.
        let column = try stack(renderer, 1)
        let eyebrow = try #require(renderer.view(app: "timer", id: 2))
        #expect(column.alignment == .leading)
        #expect(box(eyebrow).width == column.frame.width - 32)
        #expect(box(eyebrow).minX == 16)

        // And id 7, now a full-width column that says `trailing`, holds its own
        // label against the right-hand edge.
        #expect(nested.alignment == .trailing)
        #expect(nested.frame.width == column.frame.width - 32)
        #expect(box(flush).width < nested.frame.width)
        #expect(abs(box(flush).maxX - nested.bounds.maxX) <= 1)
    }

    @Test("A line too long for a centred column is compressed, never overrun")
    func centredTextStaysInTheColumn() throws {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        // Radio's case: a centred track title longer than the panel. Hugging its
        // own width must not mean growing past the column and being clipped at
        // both ends — the label truncates inside the column like any other.
        engine.receive(Envelope(app: "timer", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v"), "pad": .double(16),
                                           "align": .string("center")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("text"),
                         "props": .object([
                            "content": .string(String(repeating: "Electric Counterpoint ", count: 8)),
                            "size": .string("l"),
                         ])]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2)]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        layout(renderer)

        let column = try stack(renderer, 1)
        let title = try #require(renderer.view(app: "timer", id: 2))
        #expect(box(title).width <= column.frame.width - 32)
        #expect(box(title).minX >= 16)
        #expect(box(title).maxX <= column.frame.width - 16)
    }

    // MARK: - Rows hug (G3)

    /// A column holding one row of `text` children, laid out at panel width.
    /// `spacer` puts a `<spacer />` at the end of the row; `distribute` sets
    /// `distribute="equal"`.
    private func row(
        spacer: Bool = false,
        widthless: Bool = false,
        distribute: String? = nil
    ) throws -> (renderer: ProtocolRenderer, row: LedgeStackView, left: NSView, right: NSView) {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        var rowProps: [String: JSONValue] = ["axis": .string("h"), "gap": .double(8)]
        if let distribute { rowProps["distribute"] = .string(distribute) }
        var mutations: [JSONValue] = [
            .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                     "props": .object(["axis": .string("v"), "pad": .double(16)])]),
            .object(["op": .string("create"), "id": .int(2), "kind": .string("stack"),
                     "props": .object(rowProps)]),
            .object(["op": .string("create"), "id": .int(3), "kind": .string("text"),
                     "props": .object(["content": .string("27°"), "size": .string("display")])]),
            .object(["op": .string("create"), "id": .int(4), "kind": .string("text"),
                     "props": .object(["content": .string("Overcast"), "size": .string("s")])]),
            .object(["op": .string("insert"), "parent": .int(2), "id": .int(3)]),
            .object(["op": .string("insert"), "parent": .int(2), "id": .int(4)]),
        ]
        if spacer {
            mutations.append(.object(["op": .string("create"), "id": .int(5),
                                      "kind": .string("spacer"), "props": .object([:])]))
            mutations.append(.object(["op": .string("insert"), "parent": .int(2), "id": .int(5)]))
        }
        if widthless {
            mutations.append(.object(["op": .string("create"), "id": .int(6),
                                      "kind": .string("progress"),
                                      "props": .object(["value": .double(0.4)])]))
            mutations.append(.object(["op": .string("insert"), "parent": .int(2), "id": .int(6)]))
        }
        mutations.append(.object(["op": .string("insert"), "parent": .int(1), "id": .int(2)]))
        mutations.append(.object(["op": .string("setRoot"), "id": .int(1)]))
        engine.receive(Envelope(app: "timer", seq: 1, type: "commit",
                                payload: .object(["mutations": .array(mutations)])))
        layout(renderer)
        return (
            renderer,
            try stack(renderer, 2),
            try #require(renderer.view(app: "timer", id: 3)),
            try #require(renderer.view(app: "timer", id: 4))
        )
    }

    @Test("A row places its children instead of flinging them to opposite edges")
    func rowsPlaceTheirChildren() throws {
        let (_, line, numeral, phrase) = try row()

        // The defect, as a measurement: the numeral was stretched to 357 pt to
        // swallow the slack (drawing its glyphs flush left inside that box) and
        // the phrase was pinned to the far edge, so a sentence about the sky
        // read as two unrelated facts (D2, Weather's temperature row).
        #expect(box(numeral).width == ceil(numeral.intrinsicContentSize.width))
        #expect(box(phrase).width == ceil(phrase.intrinsicContentSize.width))
        // Side by side, one gap apart — not one at each end of the panel.
        #expect(abs(box(phrase).minX - box(numeral).maxX - 8) <= 1)
        // The ROW is unchanged: still the full column, still at its leading
        // edge. Only what happens inside it moved, which is what keeps list
        // rows, cards and press targets exactly as they were.
        #expect(abs(line.frame.width - (440 - 32)) <= 1)
        #expect(abs(line.frame.minX - 16) <= 1)
        // The leftover width is genuinely left over, at the trailing end.
        #expect(box(phrase).maxX < line.bounds.maxX - 100)
    }

    @Test("A row holding something width-less keeps filling")
    func widthlessChildrenKeepTheFill() throws {
        // The column rule's own exception, on the other axis: a `progress` has
        // no width to be placed at, so a row containing one is a row whose slack
        // has somewhere to go — and it had better go there rather than leaving a
        // zero-width meter.
        let (_, line, _, _) = try row(widthless: true)
        #expect(line.distribution == .fill)
        let meter = try #require(line.arrangedSubviews.last as? LedgeProgress)
        #expect(meter.frame.width > 100)
    }

    @Test("A row that contains a spacer still fills — that is what a spacer says")
    func spacersStillPushRowsApart() throws {
        let (_, line, numeral, phrase) = try row(spacer: true)

        // Unchanged behaviour, and the reason the rule keys off the spacer: a
        // row that wants its width is expected to say so, and every app that
        // wants a trailing value already does.
        #expect(abs(line.frame.width - (440 - 32)) <= 1)
        #expect(abs(box(numeral).minX) <= 1)          // row-local coordinates
        #expect(abs(box(phrase).minX - box(numeral).maxX - 8) <= 1)
        // The slack landed on the spacer at the end, not inside the two labels.
        #expect(box(phrase).width == ceil(phrase.intrinsicContentSize.width))
    }

    @Test("`distribute=\"equal\"` still fills, spacer or not")
    func equalDistributionStillFills() throws {
        let (_, line, numeral, phrase) = try row(distribute: "equal")
        #expect(line.distribution == .fillEqually)
        #expect(abs(line.frame.width - (440 - 32)) <= 1)
        // Equal shares is an explicit request to fill — the two children are the
        // same width even though their strings are nothing alike.
        #expect(abs(box(numeral).width - box(phrase).width) <= 1)
    }

    @Test("A row that loses its spacer stops filling")
    func removingASpacerReDecidesTheRow() throws {
        let (renderer, line, numeral, _) = try row(spacer: true)
        #expect(line.distribution == .fill)

        // The decision is per-commit, not per-mount: `remove` has to re-derive
        // it, or a row keeps a distribution it no longer has any reason for —
        // and this is the one mutation that never re-synced its parent.
        renderer.applyCommit(app: "timer", mutations: [Mutation(op: .remove, id: 5)])
        layout(renderer)
        #expect(line.distribution == .gravityAreas)
        #expect(box(numeral).width == ceil(numeral.intrinsicContentSize.width))
    }

    @Test("A row that gains a spacer starts filling again")
    func addingASpacerReDecidesTheRow() throws {
        let (renderer, line, _, phrase) = try row()
        #expect(line.distribution == .gravityAreas)

        renderer.applyCommit(app: "timer", mutations: [
            Mutation(op: .create, id: 5, kind: "spacer"),
            Mutation(op: .insert, id: 5, parent: 2),
            Mutation(op: .create, id: 6, kind: "text", props: ["content": .string("12%")]),
            Mutation(op: .insert, id: 6, parent: 2),
        ])
        layout(renderer)
        #expect(line.distribution == .fill)
        // The classic row: label at one end, value at the other, slack between.
        let value = try #require(renderer.view(app: "timer", id: 6))
        #expect(abs(box(value).maxX - line.bounds.maxX) <= 1)
        #expect(box(phrase).maxX < box(value).minX - 100)
    }

    @Test("A hosted button in a centred column is the size of what it hosts")
    func hostedButtonHugs() throws {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        // Timer's numeral: the datum IS the control (principles, law 5). A
        // full-width button would make the whole row a press target, which is
        // the other half of what the spacer helpers were hiding.
        engine.receive(Envelope(app: "timer", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("v"), "pad": .double(16),
                                           "align": .string("center")])]),
                .object(["op": .string("create"), "id": .int(2), "kind": .string("button"),
                         "props": .object(["variant": .string("plain"), "onClick": .bool(true)])]),
                .object(["op": .string("create"), "id": .int(3), "kind": .string("text"),
                         "props": .object(["content": .string("25:00"), "size": .string("display")])]),
                .object(["op": .string("insert"), "parent": .int(2), "id": .int(3)]),
                .object(["op": .string("insert"), "parent": .int(1), "id": .int(2)]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        layout(renderer)

        let column = try stack(renderer, 1)
        let button = try #require(renderer.view(app: "timer", id: 2) as? LedgeButton)
        #expect(button.frame.width < column.frame.width - 32)
        #expect(abs(button.frame.midX - column.bounds.midX) <= 1)
    }
}
