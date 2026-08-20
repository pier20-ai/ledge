import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The furniture a list-and-detail app needs: a rule between rows, a row that is
/// itself the tap target, a column that scrolls, and a page swap that leaves
/// nothing behind. Driven through the real renderer and asserted against real
/// frames — "the row looks tappable" is how a 34 pt circle with the row hanging
/// off its left edge survived being specified for a year.
@MainActor
@Suite("Lists and pages (spec §5)")
struct PagesTests {
    private func renderer(scrollCap: CGFloat? = nil) -> ProtocolRenderer {
        let renderer = ProtocolRenderer()
        if let scrollCap { renderer.scrollCap = { _ in scrollCap } }
        return renderer
    }

    /// Lay the tree out at the panel's real content width, the way `HostSession`
    /// does — a width nobody set is a width every fill constraint agrees on.
    @discardableResult
    private func layout(_ renderer: ProtocolRenderer, app: String) throws -> NSView {
        let root = try #require(renderer.rootView(for: app))
        let composite = HostSession.makeComposite(root: root, width: 440)
        composite.frame = NSRect(x: 0, y: 0, width: 440, height: 1000)
        composite.layoutSubtreeIfNeeded()
        return root
    }

    // MARK: - divider

    @Test("divider is a one-point hairline spanning its column")
    func dividerSpansTheColumn() throws {
        let renderer = renderer()
        renderer.applyCommit(app: "a", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: ["axis": .string("v"), "pad": .double(14)]),
            Mutation(op: .create, id: 2, kind: "text", props: ["content": .string("Open")]),
            Mutation(op: .create, id: 3, kind: "divider", props: [:]),
            Mutation(op: .create, id: 4, kind: "text", props: ["content": .string("High")]),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .insert, id: 3, parent: 1),
            Mutation(op: .insert, id: 4, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])
        try layout(renderer, app: "a")

        let rule = try #require(renderer.view(app: "a", id: 3) as? LedgeDividerView)
        let column: CGFloat = 440 - 28
        #expect(rule.frame.height == LedgeMetrics.hairline)
        // The column, not the panel: the stack's own 14 pt pad is respected, so a
        // rule never runs out under the card it is dividing.
        #expect(rule.frame.width == column)
        #expect(rule.frame.minX == 14)
    }

    @Test("An update op on a divider is legal and changes nothing")
    func dividerUpdateIsInert() throws {
        let renderer = renderer()
        renderer.applyCommit(app: "a", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: ["axis": .string("v")]),
            Mutation(op: .create, id: 2, kind: "divider", props: [:]),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])
        renderer.applyCommit(app: "a", mutations: [
            Mutation(op: .update, id: 2, props: ["whatever": .bool(true)]),
        ])
        let rule = try #require(renderer.view(app: "a", id: 2) as? LedgeDividerView)
        #expect(rule.intrinsicContentSize.height == LedgeMetrics.hairline)
    }

    // MARK: - button with a child

    /// A watchlist row: `button` wrapping a row of its own, which is §5's
    /// "`label` or child" taken literally.
    private func rowTree() -> [Mutation] {
        [
            Mutation(op: .create, id: 1, kind: "stack", props: ["axis": .string("v")]),
            Mutation(op: .create, id: 2, kind: "button", props: [
                "variant": .string("plain"), "onClick": .bool(true),
            ]),
            Mutation(op: .create, id: 3, kind: "stack", props: [
                "axis": .string("h"), "gap": .double(10), "pad": .double(10),
            ]),
            Mutation(op: .create, id: 4, kind: "text", props: ["content": .string("AAPL")]),
            Mutation(op: .create, id: 5, kind: "spacer"),
            Mutation(op: .create, id: 6, kind: "text", props: ["content": .string("$214.62")]),
            Mutation(op: .insert, id: 4, parent: 3),
            Mutation(op: .insert, id: 5, parent: 3),
            Mutation(op: .insert, id: 6, parent: 3),
            Mutation(op: .insert, id: 3, parent: 2),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ]
    }

    @Test("A button's child fills it, and the button takes the child's height")
    func buttonHostsItsChild() throws {
        let renderer = renderer()
        renderer.applyCommit(app: "a", mutations: rowTree())
        try layout(renderer, app: "a")

        let button = try #require(renderer.view(app: "a", id: 2) as? LedgeButton)
        let row = try #require(renderer.view(app: "a", id: 3))
        #expect(button.hostedContent === row)
        // The whole row is the control: same origin, same size, no 34 pt capsule
        // and no content adrift outside it.
        #expect(row.frame.size == button.bounds.size)
        #expect(button.frame.width == 440)
        #expect(button.frame.height == row.fittingSize.height)
        // A hosted button is not "icon-only with an empty label", which is what
        // decides whether it collapses to a circle.
        #expect(!button.isIconOnly)
        // A card, not a lozenge: a 40 pt row at the capsule radius is a pill.
        #expect(button.layer?.cornerRadius == LedgeMetrics.rCard)
    }

    @Test("Nothing inside a hosted row swallows the press meant for the row")
    func hostedRowKeepsTheHitTarget() throws {
        let renderer = renderer()
        renderer.applyCommit(app: "a", mutations: rowTree())
        try layout(renderer, app: "a")

        let button = try #require(renderer.view(app: "a", id: 2) as? LedgeButton)
        let label = try #require(renderer.view(app: "a", id: 4))
        let container = try #require(button.superview)

        // A press over the ticker, the far end of the row from anything that
        // looks like a control. `hitTest` lands on the row's stack — AppKit's
        // answer for a plain container — and NSResponder walks that up to the
        // button, which is what makes the *whole* row pressable rather than the
        // strip of it that happens to be empty.
        let hit = try #require(container.hitTest(container.convert(CGPoint(x: 4, y: 4), from: label)))
        #expect(!(hit is NSControl), "a control inside the row would eat the press")
        var responder: NSResponder? = hit
        while let current = responder, current !== button { responder = current.nextResponder }
        #expect(responder === button)
    }

    @Test("Removing a hosted button takes its child subtree with it")
    func removingAHostedButtonClearsTheSubtree() throws {
        let renderer = renderer()
        renderer.applyCommit(app: "a", mutations: rowTree())
        renderer.applyCommit(app: "a", mutations: [Mutation(op: .remove, id: 2)])

        // Every id under the button is gone from the live tree, not just the
        // button — otherwise a page swap leaks a row per visit.
        for id in [2, 3, 4, 5, 6] {
            #expect(renderer.view(app: "a", id: id) == nil)
        }
        let root = try #require(renderer.rootView(for: "a") as? NSStackView)
        #expect(root.arrangedSubviews.isEmpty)
    }

    // MARK: - fill widths

    @Test("A column holding a segment still spans its own column")
    func aSegmentDoesNotCollapseItsPage() throws {
        let renderer = renderer()
        renderer.applyCommit(app: "a", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: ["axis": .string("v")]),
            Mutation(op: .create, id: 2, kind: "stack", props: [
                "axis": .string("v"), "pad": .double(14), "gap": .double(10),
            ]),
            Mutation(op: .create, id: 3, kind: "segment", props: [
                "options": .array([
                    .object(["id": .string("1d"), "label": .string("1D")]),
                    .object(["id": .string("6m"), "label": .string("6M")]),
                ]),
                "value": .string("1d"),
            ]),
            Mutation(op: .create, id: 4, kind: "chart", props: [
                "points": .array([.double(1), .double(2), .double(3)]),
            ]),
            Mutation(op: .insert, id: 3, parent: 2),
            Mutation(op: .insert, id: 4, parent: 2),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])
        try layout(renderer, app: "a")

        let page = try #require(renderer.view(app: "a", id: 2))
        let segment = try #require(renderer.view(app: "a", id: 3))
        let chart = try #require(renderer.view(app: "a", id: 4))
        // The segment keeps its measured width — that is what its hard hugging is
        // for — and takes nobody with it.
        let panel: CGFloat = 440
        let column: CGFloat = 440 - 28
        #expect(page.frame.width == panel)
        #expect(segment.frame.width < panel)
        #expect(chart.frame.width == column)
    }

    // MARK: - stack scroll

    @Test("A list longer than its cap scrolls instead of growing the panel")
    func longListScrolls() throws {
        let cap: CGFloat = 120
        let renderer = renderer(scrollCap: cap)
        var mutations: [Mutation] = [
            Mutation(op: .create, id: 1, kind: "stack", props: [
                "axis": .string("v"), "scroll": .bool(true), "gap": .double(0),
            ]),
        ]
        for id in 2...21 {
            mutations.append(Mutation(op: .create, id: id, kind: "stack", props: [
                "axis": .string("h"), "pad": .double(10),
            ]))
            mutations.append(Mutation(op: .create, id: id + 100, kind: "text", props: [
                "content": .string("row \(id)"),
            ]))
            mutations.append(Mutation(op: .insert, id: id + 100, parent: id))
            mutations.append(Mutation(op: .insert, id: id, parent: 1))
        }
        mutations.append(Mutation(op: .setRoot, id: 1))
        renderer.applyCommit(app: "a", mutations: mutations)
        try layout(renderer, app: "a")

        let wrapper = try #require(renderer.view(app: "a", id: 1) as? LedgeScrollStackView)
        // What the panel measures stops at the cap…
        #expect(renderer.rootFittingHeight(for: "a") == cap)
        #expect(wrapper.frame.height == cap)
        // …while the content behind it is genuinely taller, which is the whole
        // difference between scrolling and clipping.
        #expect(wrapper.stack.fittingSize.height > cap)
        // Rows still span the column inside the scroller: the fill constraints
        // resolve against the clip view, not against the widest row.
        let panel: CGFloat = 440
        #expect(try #require(renderer.view(app: "a", id: 2)).frame.width == panel)
    }

    @Test("A short list asks for exactly its content and no scrolling shows")
    func shortListDoesNotReserveTheCap() throws {
        let renderer = renderer(scrollCap: 400)
        renderer.applyCommit(app: "a", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: [
                "axis": .string("v"), "scroll": .bool(true),
            ]),
            Mutation(op: .create, id: 2, kind: "text", props: ["content": .string("only row")]),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])
        try layout(renderer, app: "a")

        let wrapper = try #require(renderer.view(app: "a", id: 1) as? LedgeScrollStackView)
        #expect(wrapper.frame.height == ceil(wrapper.stack.fittingSize.height))
        #expect(wrapper.frame.height < 400)
    }

    // MARK: - navigating

    @Test("Swapping the page under the root replaces the tree, wing intact")
    func pageSwap() throws {
        let renderer = renderer()
        // Mount: root + wing + a list page.
        renderer.applyCommit(app: "a", mutations: [
            Mutation(op: .create, id: 1, kind: "stack", props: ["axis": .string("v")]),
            Mutation(op: .create, id: 2, kind: "wing", props: ["side": .string("left")]),
            Mutation(op: .create, id: 3, kind: "stack", props: ["axis": .string("v"), "scroll": .bool(true)]),
            Mutation(op: .create, id: 4, kind: "text", props: ["content": .string("AAPL")]),
            Mutation(op: .insert, id: 4, parent: 3),
            Mutation(op: .insert, id: 2, parent: 1),
            Mutation(op: .insert, id: 3, parent: 1),
            Mutation(op: .setRoot, id: 1),
        ])
        // The commit a `setState` produces: the old page out, the new page in.
        renderer.applyCommit(app: "a", mutations: [
            Mutation(op: .create, id: 5, kind: "stack", props: ["axis": .string("v"), "pad": .double(14)]),
            Mutation(op: .create, id: 6, kind: "text", props: ["content": .string("Apple")]),
            Mutation(op: .insert, id: 6, parent: 5),
            Mutation(op: .remove, id: 3),
            Mutation(op: .insert, id: 5, parent: 1),
        ])
        try layout(renderer, app: "a")

        #expect(renderer.view(app: "a", id: 3) == nil)
        #expect(renderer.view(app: "a", id: 4) == nil)
        // The wing is a zone, not a page: navigating does not disturb it.
        #expect(renderer.wingView(for: "a") != nil)
        let root = try #require(renderer.rootView(for: "a") as? NSStackView)
        #expect(root.arrangedSubviews.count == 1)
        #expect(try #require(renderer.view(app: "a", id: 5)).frame.width == 440)
    }
}
