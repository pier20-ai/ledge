import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// The six §5 kinds ratified in D8/Q5, driven from the same golden fixtures the
/// host replays. Each one is asserted twice: as the shell builds it from a
/// `create`, and as it changes under an `update` — because a create-only prop is
/// the exact bug `button` shipped once already.
@MainActor
@Suite("New §5 kinds (D6)")
struct NewKindsTests {
    private func mount() throws -> (ProtocolEngine, ProtocolRenderer) {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        engine.receive(try Fixtures.envelope("commit-new-kinds.json"))
        if let root = renderer.rootView(for: "gallery") {
            root.translatesAutoresizingMaskIntoConstraints = true
            root.frame = CGRect(x: 0, y: 0, width: 440, height: ceil(root.fittingSize.height))
            root.layoutSubtreeIfNeeded()
        }
        return (engine, renderer)
    }

    @Test("All six kinds mount, and the shadow tree accepts their props")
    func allSixMount() throws {
        let (_, renderer) = try mount()
        #expect(renderer.kind(app: "gallery", id: 2) == .toggle)
        #expect(renderer.kind(app: "gallery", id: 4) == .segment)
        #expect(renderer.kind(app: "gallery", id: 5) == .stepper)
        #expect(renderer.kind(app: "gallery", id: 7) == .progress)
        #expect(renderer.kind(app: "gallery", id: 8) == .spinner)
        #expect(renderer.kind(app: "gallery", id: 9) == .pill)
        // Nothing was dropped: an unknown kind would have failed validation and
        // discarded the whole commit, leaving no root at all.
        #expect(renderer.rootView(for: "gallery") != nil)
    }

    // MARK: - toggle

    @Test("toggle: 36×20 capsule, knob parks at the on/off end, updates in place")
    func toggle() throws {
        let (engine, renderer) = try mount()
        let on = try #require(renderer.view(app: "gallery", id: 2) as? LedgeToggle)
        let off = try #require(renderer.view(app: "gallery", id: 3) as? LedgeToggle)

        #expect(on.isOn)
        #expect(!off.isOn)
        #expect(on.intrinsicContentSize == NSSize(width: 36, height: 20))
        #expect(on.bounds.height == LedgeMetrics.toggleHeight)
        #expect(on.bounds.width == LedgeMetrics.toggleWidth)

        // Disabled dims the whole switch and refuses the press.
        #expect(off.disabled)
        #expect(off.alphaValue == LedgeMetrics.disabledAlpha)
        #expect(!off.isEnabled)

        engine.receive(try Fixtures.envelope("commit-new-kinds-update.json"))
        #expect(!on.isOn)                                  // on → off in place
        #expect(off.isOn)                                  // and off → on…
        #expect(!off.disabled)                             // …once re-enabled by `disabled: null`
        #expect(off.alphaValue == 1)
    }

    // MARK: - segment

    @Test("segment: capsule group, measured segments, selection moves in place")
    func segment() throws {
        let (engine, renderer) = try mount()
        let segment = try #require(renderer.view(app: "gallery", id: 4) as? LedgeSegment)

        #expect(segment.options.map(\.id) == ["1d", "1w", "1m"])
        #expect(segment.options.map(\.label) == ["1D", "1W", "1M"])
        #expect(segment.value == "1w")
        #expect(segment.bounds.height == LedgeMetrics.segmentHeight)
        #expect(segment.layer?.cornerRadius == LedgeMetrics.capsule(segment.bounds.height))
        #expect(segment.layer?.cornerCurve == .continuous)
        // Three segments, each its label plus 12 pt of pad either side, inside a
        // 2 pt group pad — never a fixed segment width.
        #expect(segment.intrinsicContentSize.width > LedgeMetrics.segmentItemPadX * 6)

        engine.receive(try Fixtures.envelope("commit-new-kinds-update.json"))
        #expect(segment.value == "1m")
        #expect(segment.options.count == 3)                // options untouched: no rebuild
    }

    @Test("segment: an option with no id is dropped, not given a synthetic one")
    func segmentBadOption() throws {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        engine.receive(Envelope(app: "x", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("segment"),
                         "props": .object([
                            "options": .array([
                                .object(["id": .string("a"), "label": .string("A")]),
                                .object(["label": .string("orphan")]),
                                // No label: the id doubles as the label rather than
                                // rendering an empty segment nobody can read.
                                .object(["id": .string("c")]),
                            ]),
                            "value": .string("a"),
                         ])]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        let segment = try #require(renderer.view(app: "x", id: 1) as? LedgeSegment)
        #expect(segment.options.map(\.id) == ["a", "c"])
        #expect(segment.options.map(\.label) == ["A", "c"])
    }

    // MARK: - stepper

    @Test("stepper: clamps to min/max, and shows the app's format string")
    func stepper() throws {
        let (engine, renderer) = try mount()
        let hours = try #require(renderer.view(app: "gallery", id: 5) as? LedgeStepper)
        let clock = try #require(renderer.view(app: "gallery", id: 6) as? LedgeStepper)

        #expect(hours.value == 7)
        #expect(hours.rangeMin == 0)
        #expect(hours.rangeMax == 23)
        #expect(hours.step == 1)
        #expect(hours.displayedText == "7")                // integers read as integers
        #expect(hours.bounds.height == LedgeMetrics.stepperHeight)
        #expect(hours.layer?.cornerRadius == LedgeMetrics.capsule(LedgeMetrics.stepperHeight))
        // The value column never narrows below 52, so "7" and "23" don't shuffle
        // the −/+ targets under the user's finger.
        #expect(hours.intrinsicContentSize.width
            >= LedgeMetrics.stepperValueMinWidth + LedgeMetrics.stepperButton * 2)

        // 450 minutes past midnight is 07:30, which only the app knows.
        #expect(clock.displayedText == "07:30")

        engine.receive(try Fixtures.envelope("commit-new-kinds-update.json"))
        #expect(hours.value == 21)
        #expect(hours.displayedText == "21")
        #expect(clock.value == 465)
        #expect(clock.displayedText == "07:45")

        hours.apply(value: 999, min: nil, max: nil, step: nil, format: nil)
        #expect(hours.value == 23)                         // clamped at max
        hours.apply(value: -5, min: nil, max: nil, step: nil, format: nil)
        #expect(hours.value == 0)                          // clamped at min
    }

    @Test("stepper: a stepper with no min/max is unbounded (alarm's hour wrap)")
    func stepperUnbounded() throws {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        engine.receive(Envelope(app: "alarm", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stepper"),
                         "props": .object([
                            "value": .double(1_380),
                            "step": .double(60),
                            "format": .string("23:00"),
                         ])]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        let stepper = try #require(renderer.view(app: "alarm", id: 1) as? LedgeStepper)
        // Alarm wraps 23:00 → 00:00 itself, in minutes-since-midnight space, so a
        // clamp invented here would break the picker.
        stepper.apply(value: 1_440, min: nil, max: nil, step: nil, format: .some("00:00"))
        #expect(stepper.value == 1_440)
        #expect(stepper.displayedText == "00:00")
        stepper.apply(value: -15, min: nil, max: nil, step: nil, format: .some("23:45"))
        #expect(stepper.value == -15)
    }

    // MARK: - progress

    @Test("progress: a 4 pt capsule bed with an ink fill, read-only")
    func progress() throws {
        let (engine, renderer) = try mount()
        let progress = try #require(renderer.view(app: "gallery", id: 7) as? LedgeProgress)
        #expect(progress.value == 0.64)
        #expect(progress.bounds.height == LedgeMetrics.progressHeight)
        #expect(progress.intrinsicContentSize.height == LedgeMetrics.progressHeight)
        // Read-only by definition (D6): it is not a slider, so it is not an
        // NSControl and there is nothing to send.
        #expect(!(progress is NSControl))

        engine.receive(try Fixtures.envelope("commit-new-kinds-update.json"))
        #expect(progress.value == 0.2)
        progress.value = 4                                 // clamps to 0…1
        #expect(progress.value == 1)
    }

    // MARK: - spinner

    @Test("spinner: 16 pt ring that only turns while it is on screen")
    func spinner() throws {
        let (engine, renderer) = try mount()
        let spinner = try #require(renderer.view(app: "gallery", id: 8) as? LedgeSpinner)
        #expect(spinner.intrinsicContentSize == NSSize(width: 16, height: 16))
        #expect(!spinner.isSpinning)                       // no window yet

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host
        spinner.removeFromSuperview()
        spinner.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(spinner)
        #expect(spinner.isSpinning)

        // An update op on a spinner has nothing to do — and must not restart or
        // stop the animation.
        engine.receive(try Fixtures.envelope("commit-new-kinds-update.json"))
        #expect(spinner.isSpinning)

        spinner.removeFromSuperview()
        #expect(!spinner.isSpinning)                       // never spins detached
    }

    // MARK: - pill

    @Test("pill: h20 capsule, tint/stroke/ink triple, label and tone both update")
    func pill() throws {
        let (engine, renderer) = try mount()
        let accent = try #require(renderer.view(app: "gallery", id: 9) as? LedgePill)
        let neutral = try #require(renderer.view(app: "gallery", id: 10) as? LedgePill)

        #expect(accent.label.stringValue == "PAPER")
        #expect(accent.tone == .accent)
        #expect(accent.bounds.height == LedgeMetrics.pillHeight)
        #expect(accent.layer?.cornerRadius == LedgeMetrics.capsule(LedgeMetrics.pillHeight))
        #expect(accent.layer?.backgroundColor == LedgeTheme.accentTint.cgColor)
        #expect(accent.layer?.borderColor == LedgeTheme.accentStroke.cgColor)
        #expect(accent.label.textColor == LedgeTheme.accent)
        // A pill routes through CenteredTextBox: a raw NSTextField top-aligns in a
        // box taller than its text, which is why every hand-rolled badge sat high.
        #expect(accent is CenteredTextBox)

        // `neutral` is raised glass + secondary ink, not a grey invented for it.
        #expect(neutral.tone == .neutral)
        #expect(neutral.layer?.backgroundColor == LedgeTheme.raised.cgColor)
        #expect(neutral.label.textColor == LedgeTheme.secondary)

        engine.receive(try Fixtures.envelope("commit-new-kinds-update.json"))
        #expect(accent.label.stringValue == "LIVE")
        #expect(accent.tone == .green)
        #expect(accent.layer?.backgroundColor == LedgeTheme.greenTint.cgColor)
        #expect(accent.label.textColor == LedgeTheme.green)
        #expect(neutral.tone == .violet)
        #expect(neutral.label.stringValue == "DRAFT")      // label untouched
    }

    @Test("pill: an unknown tone is neutral, never a guess")
    func pillUnknownTone() {
        #expect(LedgePill.Tone(token: "chartreuse") == .neutral)
        #expect(LedgePill.Tone(token: nil) == .neutral)
        #expect(LedgePill.Tone(token: "cyan") == .cyan)
    }

    // MARK: - stack scroll (the container upgrade)

    @Test("stack scroll wraps the stack, keeps fill widths, and caps its height")
    func stackScroll() throws {
        let (_, renderer) = try mount()
        let root = try #require(renderer.view(app: "gallery", id: 1) as? LedgeScrollStackView)

        // The node's view is the wrapper (so the panel measures the capped
        // height), but the children live on the stack inside the clip view.
        #expect(root.stack.arrangedSubviews.count == 9)
        #expect(root.contentView === root.stack)
        #expect(renderer.rootView(for: "gallery") === root)

        // Below the cap the wrapper is exactly its content: scroll is invisible
        // until it is needed.
        let cap = PanelLimits.fallback.maxHeight - NotchMetrics.fallback.closedHeight
        #expect(root.intrinsicContentSize.height <= cap)
        #expect(root.intrinsicContentSize.height == ceil(root.stack.fittingSize.height))
    }

    @Test("A long scrolling list stops at the cap instead of growing the panel")
    func scrollCapClamps() throws {
        let renderer = ProtocolRenderer()
        renderer.scrollCap = { _ in 120 }                  // a deliberately tiny ceiling
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)

        var mutations: [JSONValue] = [
            .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                     "props": .object(["axis": .string("v"), "scroll": .bool(true), "gap": .int(8)])]),
        ]
        for id in 2...25 {
            mutations.append(.object(["op": .string("create"), "id": .int(id), "kind": .string("text"),
                                      "props": .object(["content": .string("row \(id)")])]))
            mutations.append(.object(["op": .string("insert"), "parent": .int(1), "id": .int(id),
                                      "before": .null]))
        }
        mutations.append(.object(["op": .string("setRoot"), "id": .int(1)]))
        engine.receive(Envelope(app: "deals", seq: 1, type: "commit",
                                payload: .object(["mutations": .array(mutations)])))

        let root = try #require(renderer.rootView(for: "deals") as? LedgeScrollStackView)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.frame = CGRect(x: 0, y: 0, width: 440, height: 120)
        root.layoutSubtreeIfNeeded()

        #expect(root.stack.fittingSize.height > 120)        // the content is long…
        #expect(root.intrinsicContentSize.height == 120)    // …the panel sees the cap
        #expect(renderer.rootFittingHeight(for: "deals") <= 120)
    }

    @Test("A horizontal stack that asks to scroll is ignored, not guessed at")
    func horizontalScrollIgnored() throws {
        let renderer = ProtocolRenderer()
        let engine = ProtocolEngine(
            screen: ScreenInfo(notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480),
            delegate: renderer,
            send: { _ in }
        )
        engine.connectionOpened(generation: 1)
        engine.receive(Envelope(app: "row", seq: 1, type: "commit", payload: .object([
            "mutations": .array([
                .object(["op": .string("create"), "id": .int(1), "kind": .string("stack"),
                         "props": .object(["axis": .string("h"), "scroll": .bool(true)])]),
                .object(["op": .string("setRoot"), "id": .int(1)]),
            ]),
        ])))
        #expect(renderer.rootView(for: "row") is LedgeStackView)
        #expect(!(renderer.rootView(for: "row") is LedgeScrollStackView))
    }
}
