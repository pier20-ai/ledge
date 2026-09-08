import AppKit
import Foundation
import Testing
@testable import LedgeShell
@testable import LedgeShellCore

/// `rate` on `slider` and `progress` (spec §5): the control advances its own
/// displayed value between commits.
///
/// The thing being bought here is latency, not smoothness for its own sake. A
/// Now Playing monitor polls a player every three seconds because that is a
/// reasonable number of Apple events to send, and the scrub bar consequently
/// moved in three-second steps. `rate` lets the app state the one thing it
/// actually knows — "this grows by one per second" — and have the shell do the
/// arithmetic at 30 Hz where the pixels are, for zero extra commits.
@MainActor
@Suite("Self-advancing controls (spec §5 `rate`)")
struct SelfAdvanceTests {
    /// A control in a real window, because the tick is deliberately window-gated.
    private func hosted<V: NSView>(_ view: V) -> (window: NSWindow, view: V) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 22)
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private func makeSlider(value: Double, max upper: Double) -> LedgeSlider {
        LedgeSlider(value: value, min: 0, max: upper, step: nil) { _ in }
    }

    // MARK: - Advancing

    @Test("A rated slider advances in value units per second")
    func sliderAdvances() {
        let (window, slider) = hosted(makeSlider(value: 10, max: 200))
        _ = window
        slider.applyRate(1)
        #expect(slider.rate == 1)

        slider.advance(by: 2.5)
        #expect(abs(slider.value - 12.5) < 0.001)
        slider.advance(by: 0.5)
        #expect(abs(slider.value - 13) < 0.001)
    }

    @Test("Self-advance clamps at max rather than walking off the track")
    func clampsAtMax() {
        let (window, slider) = hosted(makeSlider(value: 195, max: 200))
        _ = window
        slider.applyRate(1)
        slider.advance(by: 60)
        #expect(slider.value == 200)
        #expect(slider.position == 1)
    }

    @Test("`progress` advances in fractions and stops at 1")
    func progressAdvances() {
        let (window, progress) = hosted(LedgeProgress(value: 0))
        _ = window
        progress.applyRate(0.25)
        progress.advance(by: 2)
        #expect(abs(progress.value - 0.5) < 0.001)
        progress.advance(by: 10)
        #expect(progress.value == 1)
    }

    @Test("rate 0 (or absent) is exactly today's static behavior")
    func zeroRateIsStatic() {
        let (window, slider) = hosted(makeSlider(value: 10, max: 200))
        _ = window
        slider.applyRate(nil)
        #expect(slider.rate == 0)
        #expect(!slider.isSelfAdvancing)
        slider.advance(by: 100)
        #expect(slider.value == 10)

        // …and a rate that goes back to zero really stops.
        slider.applyRate(1)
        #expect(slider.isSelfAdvancing)
        slider.applyRate(0)
        #expect(!slider.isSelfAdvancing)
        slider.advance(by: 100)
        #expect(slider.value == 10)
    }

    // MARK: - The tick's lifetime

    @Test("The tick only runs in a window, and stops when the view leaves")
    func tickIsWindowGated() {
        let loose = makeSlider(value: 0, max: 100)
        loose.applyRate(1)
        #expect(!loose.isSelfAdvancing, "a detached control must not hold a timer open")

        let (window, slider) = hosted(makeSlider(value: 0, max: 100))
        slider.applyRate(1)
        #expect(slider.isSelfAdvancing)

        slider.removeFromSuperview()
        #expect(!slider.isSelfAdvancing, "off-window teardown, the LedgeSpinner rule")
        _ = window
    }

    /// Polls for the tick rather than sleeping a fixed 150 ms and hoping: the
    /// suite runs in parallel with every other suite, and a starved main
    /// thread made the fixed wait fail about one run in three. The deadline is
    /// generous; the bound on the value is what actually proves the timer is
    /// interpolating from the clock rather than free-running.
    @Test("The real timer advances the value over a short run-loop spin")
    func realTimerRuns() {
        let (window, slider) = hosted(makeSlider(value: 0, max: 100))
        _ = window
        let started = CACurrentMediaTime()
        slider.applyRate(10)                       // 10 units/s
        #expect(slider.isSelfAdvancing)
        let deadline = Date().addingTimeInterval(3)
        while slider.value == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let elapsed = CACurrentMediaTime() - started
        #expect(slider.value > 0, "the tick never fired in \(elapsed) s")
        // Clock-interpolated: never more than the rate times the wall clock
        // that actually passed (plus one interval of slack for the tick that
        // landed after the clock was read).
        #expect(slider.value <= 10 * (elapsed + LedgeMetrics.selfAdvanceInterval),
                "free-running: \(slider.value) after \(elapsed) s")
    }

    // MARK: - Re-anchoring

    @Test("A committed value glides through jitter and jumps on a real move")
    func commitsReanchor() {
        let (window, slider) = hosted(makeSlider(value: 60, max: 200))
        _ = window
        slider.applyRate(1)
        slider.advance(by: 3)                      // locally at 63
        #expect(abs(slider.value - 63) < 0.001)

        // The poll lands saying 62.6: within a second of self-advance, so it is
        // poll jitter. Snapping to it would twitch the knob backwards every
        // three seconds for the entire track.
        slider.applyCommittedValue(62.6)
        #expect(abs(slider.value - 63) < 0.001)

        // 20 seconds away is not jitter — the user seeked, or the track changed.
        slider.applyCommittedValue(20)
        #expect(slider.value == 20)
    }

    @Test("With no rate, every commit lands verbatim")
    func staticCommitsLandExactly() {
        let (window, slider) = hosted(makeSlider(value: 60, max: 200))
        _ = window
        slider.applyCommittedValue(60.4)
        #expect(slider.value == 60.4)
    }

    // MARK: - Through the renderer

    @Test("The rate fixtures drive real controls end to end")
    func fixtureReplay() throws {
        let session = HostSession()
        session.openReplay()
        session.inject(try Fixtures.envelope("commit-rate.json"))
        let root = try #require(session.content(for: "nowplaying")).view
        root.layoutSubtreeIfNeeded()

        let sliders = descendants(of: root).compactMap { $0 as? LedgeSlider }
        let bars = descendants(of: root).compactMap { $0 as? LedgeProgress }
        #expect(sliders.count == 2)
        #expect(bars.count == 2)
        // A scrubber in seconds: value 64 of 224, advancing one per second.
        #expect(sliders[0].rate == 1)
        #expect(sliders[0].value == 64)
        #expect(sliders[0].rangeMax == 224)
        #expect(bars[0].rate > 0)
        // The slider that never mentioned `rate` is static, as it always was.
        #expect(sliders[1].rate == 0)

        // `progress.color` (G3): a token, resolved by the shell. The first bar
        // asked for accent — design.html §01's working-moment meter — and the
        // second asked for nothing, which is ink.
        #expect(bars[0].fillColor == LedgeTheme.accent)
        #expect(bars[1].fillColor == LedgeTheme.inkFill)

        // Pausing sends rate 0; dropping the key entirely is the same thing.
        session.inject(try Fixtures.envelope("commit-rate-update.json"))
        #expect(sliders[0].rate == 0)
        #expect(bars[0].rate == 0)
        // …and `color: null` is §3.1's delete, so the accent bar goes back to
        // ink rather than keeping a stale hue, while its neighbour gains one.
        #expect(bars[0].fillColor == LedgeTheme.inkFill)
        #expect(bars[1].fillColor == LedgeTheme.green)
    }

    @Test("A meter's colour vocabulary is hue families, never ink shades")
    func meterColorVocabulary() {
        #expect(ProtocolRenderer.meterColor("accent") == LedgeTheme.accent)
        #expect(ProtocolRenderer.meterColor("green") == LedgeTheme.green)
        #expect(ProtocolRenderer.meterColor("red") == LedgeTheme.red)
        #expect(ProtocolRenderer.meterColor("violet") == LedgeTheme.violet)
        #expect(ProtocolRenderer.meterColor("cyan") == LedgeTheme.cyan)
        // Ink shades are *type* colours; naming one here would be the default
        // spelled three more ways. An unknown token degrades to the default too,
        // which is how a future token renders on an older shell.
        #expect(ProtocolRenderer.meterColor("secondary") == LedgeTheme.inkFill)
        #expect(ProtocolRenderer.meterColor("chartreuse") == LedgeTheme.inkFill)
        #expect(ProtocolRenderer.meterColor(nil) == LedgeTheme.inkFill)
    }
}
