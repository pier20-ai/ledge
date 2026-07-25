import AppKit

/// One ruler for geometry (design system D4/D6, law L1). `LedgeTheme` owns every
/// color; this owns every size. A component with a hardcoded number is a review
/// reject — the point is that "the button is 34 tall" is stated once, so the
/// `size` ramp and the capsule rule can be changed in one place instead of
/// eleven.
///
/// Two rules generate almost all of it (D4):
///
/// - **Capsule** — anything you press or type into has `radius = height / 2`.
///   That is the collapsed notch's own silhouette, and it makes an icon-only
///   button a circle for free.
/// - **Concentric** — a nested container's radius is its parent's minus the
///   inset (floor 4): panel 26 → content 14 → tile 8; card 12 → chip 8.
enum LedgeMetrics {
    // MARK: - Radius scale

    /// Slider tracks, progress bars — a 4 pt bar is a capsule at 2.
    static let rTrack: CGFloat = 2
    /// Small nested tiles inside a card, and the mat under a canvas.
    static let rChip: CGFloat = 8
    /// Cards, tiles, boxes. The one mid-size radius; `RoundedBoxView`'s old 10
    /// was concentric with nothing.
    static let rCard: CGFloat = 12
    /// The panel's content container: panel 26 − 12 pt inset.
    static let rContent: CGFloat = 14
    /// The expanded panel's bottom corners.
    static let rPanel: CGFloat = 26

    /// The capsule rule. Pass a control's height, get its corner radius.
    static func capsule(_ height: CGFloat) -> CGFloat { max(0, height) / 2 }

    // MARK: - Spacing (the 4 pt grid)

    /// `stack` default gap (spec §5).
    static let gap: CGFloat = 8
    /// Card pad — also the panel's concentric inset.
    static let padCard: CGFloat = 12

    // MARK: - Control sizes

    /// The `size` ramp (D8/Q4): s 28 · m 34 (default) · l 40. Height, pad-x and
    /// the icon-only square all track it; the *type* ramp does not — D3 has five
    /// sizes and a button label is always `s`/semibold.
    enum Size: String, CaseIterable {
        case s
        case m
        case l

        static let `default`: Size = .m

        init(token: String?) {
            self = Size(rawValue: token ?? "") ?? .default
        }

        var height: CGFloat {
            switch self {
            case .s: 28
            case .m: 34
            case .l: 40
            }
        }

        /// Horizontal padding of a labeled control. `m` is D4's ratified 14; the
        /// ramp steps by 4 either side of it.
        var padX: CGFloat {
            switch self {
            case .s: 10
            case .m: 14
            case .l: 18
            }
        }
    }

    // MARK: - Button (D4 control metrics, D6)

    /// Gap between a leading icon and its label. An *empty* label earns no gap
    /// (L2) — that is the icon-centering defect.
    static let buttonIconGap: CGFloat = 5
    /// NSTextField's cell pads a couple of points past the measured string; a
    /// label laid out at exactly its string width truncates a character.
    static let labelCellPad: CGFloat = 5
    /// Icon beside a label: small and heavy, so it reads as punctuation.
    static let buttonIconPointSize: CGFloat = 11
    static let buttonIconWeight: NSFont.Weight = .semibold
    /// Icon *alone*: 14 pt medium, matching the app strip (D8/Q3) — transport
    /// glyphs have to read at arm's length.
    static let iconOnlyPointSize: CGFloat = 14
    static let iconOnlyWeight: NSFont.Weight = .medium
    /// Disabled content alpha (D6). The background does not dim — the control is
    /// still there, it just has nothing to say yet.
    static let disabledAlpha: CGFloat = 0.35

    // MARK: - Press (D5, law L4)

    static let pressScaleLabeled: CGFloat = 0.96
    static let pressScaleIcon: CGFloat = 0.92
    static let pressDurationIn: TimeInterval = 0.08
    static let pressDurationOut: TimeInterval = 0.12
    /// Hover washes and other state changes (D5). Layout ticks animate never.
    static let hoverDuration: TimeInterval = 0.12

    // MARK: - Input

    static let inputHeight: CGFloat = Size.m.height
    static let inputPadX: CGFloat = Size.m.padX

    // MARK: - Slider

    /// Hit height — bigger than the track so the thumb is grabbable.
    static let sliderHeight: CGFloat = 22
    static let sliderPadX: CGFloat = 6
    static let sliderTrackHeight: CGFloat = 4
    static let sliderKnob: CGFloat = 14

    // MARK: - Pill, dot, hairline, send disc

    static let pillHeight: CGFloat = 20
    static let pillPadX: CGFloat = 8
    static let pillPointSize: CGFloat = 10
    static let pillWeight: NSFont.Weight = .semibold
    static let dot: CGFloat = 5
    static let hairline: CGFloat = 1
    static let sendDisc: CGFloat = 24
    /// App-strip icon button: a 34 pt circle with a tint-only hover.
    static let stripIcon: CGFloat = 34
    static let stripIconPointSize: CGFloat = 14
    static let stripIconWeight: NSFont.Weight = .medium
    static let stripActiveDot: CGFloat = 4
    static let stripActiveDotInset: CGFloat = 3
    /// The cell one strip icon occupies: the 34 pt circle plus 3 pt of air each
    /// side, which is the 40 pt pitch the strip has always been laid out on.
    static let stripIconCell: CGFloat = 40
    /// Leading inset of the first strip icon.
    static let stripLeadingPad: CGFloat = 10
    /// Distance from the strip's right edge to the Settings icon's left edge,
    /// and to the hairline that separates it from everything else.
    static let stripSettingsInset: CGFloat = 50
    static let stripSettingsDividerInset: CGFloat = 61
    /// The gap that keeps **[+]** off the Settings divider however crowded the
    /// strip gets. A minimum, never a target: the scrolling icon area gives back
    /// whatever it doesn't need, so an uncrowded strip looks exactly as it did.
    static let stripSafeGap: CGFloat = 12

    // MARK: - Panel wings (the hardware-cutout exclusion row)

    /// Breathing room either side of the hardware cutout before a zone starts.
    /// The cutout's own edges are antialiased against a hole in the display, so
    /// content flush against them reads as content that is *slightly* clipped —
    /// which is worse than content that is obviously inset.
    static let panelWingCutoutMargin: CGFloat = 8
    /// Inset from the panel's own edges to a zone's content.
    static let panelWingPad: CGFloat = 12
    /// Gap between items an app puts in its left wing.
    static let panelWingGap: CGFloat = 6
    /// The default left-zone content: the app's catalog name, in the same face
    /// the collapsed wing label uses (D3 `s`/semibold, secondary ink).
    static let panelWingNamePointSize: CGFloat = 11.5
    static let panelWingNameWeight: NSFont.Weight = .semibold

    // MARK: - Self-advancing controls (`rate`, §5)

    /// Tick rate for a `slider`/`progress` that declared `rate`. 30 Hz is under
    /// the eye's threshold for a bar this size and costs a tenth of what a
    /// display link would; the value is interpolated from the wall clock, so a
    /// dropped tick loses no position.
    static let selfAdvanceInterval: TimeInterval = 1.0 / 30
    /// How far a committed value may differ from the locally-advanced one before
    /// the control **jumps** instead of gliding — one second of self-advance.
    /// Below it the difference is poll jitter and snapping to it would make a
    /// scrubber twitch backwards every three seconds; above it the app is
    /// telling us something (a seek, a track change) and gliding would be a lie.
    static let selfAdvanceGlideSeconds: Double = 1

    // MARK: - New kinds (D6 "New kinds")

    /// `toggle`: 36 × 20 capsule, 16 pt knob inset 2, 150 ms ease.
    static let toggleWidth: CGFloat = 36
    static let toggleHeight: CGFloat = 20
    static let toggleKnob: CGFloat = 16
    static let toggleKnobInset: CGFloat = 2
    static let toggleDuration: TimeInterval = 0.15

    /// `segment`: capsule group with a 2 pt pad around h24 segments.
    static let segmentPad: CGFloat = 2
    static let segmentItemHeight: CGFloat = 24
    static let segmentItemPadX: CGFloat = 12
    static var segmentHeight: CGFloat { segmentItemHeight + segmentPad * 2 }
    /// The selection moves in place; it is a state change, so it animates (L6).
    static let segmentDuration: TimeInterval = 0.12

    /// `stepper`: h28 capsule, square −/+ hit targets, numeric value column.
    static let stepperHeight: CGFloat = 28
    static let stepperButton: CGFloat = 28
    static let stepperValueMinWidth: CGFloat = 52
    static let stepperValuePointSize: CGFloat = 12
    static let stepperGlyphPointSize: CGFloat = 12
    /// Hold-to-repeat: a beat before it starts, then fast.
    static let stepperRepeatDelay: TimeInterval = 0.4
    static let stepperRepeatInterval: TimeInterval = 0.08

    /// `progress`: the slider's track without the knob.
    static let progressHeight: CGFloat = 4

    /// `spinner`: a 16 pt ring at 2 pt, one turn every 0.9 s, linear.
    static let spinnerSize: CGFloat = 16
    static let spinnerStroke: CGFloat = 2
    static let spinnerDuration: TimeInterval = 0.9
    /// How much of the ring the moving cap covers.
    static let spinnerCapFraction: CGFloat = 0.25

    // MARK: - Chart (D6)

    static let chartHeight: CGFloat = 44
    static let chartStroke: CGFloat = 1.8
    /// Vertical breathing room so a peak is not clipped by the frame.
    static let chartInsetY: CGFloat = 3
    static let chartFillAlpha: CGFloat = 0.25

    // MARK: - Text

    static let textDefaultPointSize: CGFloat = 12.5
    /// Extra width over the measured string: a truncating NSTextField
    /// under-reports its own intrinsic width, so "$214.62" arrives as "$214…".
    static let textMeasureSlack: CGFloat = 6

    // MARK: - Cards & canvases

    static let canvasRadius: CGFloat = rChip
    static let errorCardPad: CGFloat = 16
}
