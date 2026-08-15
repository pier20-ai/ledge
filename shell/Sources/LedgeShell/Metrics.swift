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
    /// **The parked window** (design.html §04 `.window`). Between the card and
    /// the panel: it is the same body as the panel, but it has left the wall, so
    /// it is rounded on all four corners instead of tucking under the menu bar.
    static let rWindow: CGFloat = 16

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
    /// …except a **ghost**, which is the app tier: design.html §06 says an
    /// app-content glyph is larger than chrome, and 14 pt does not hold its own
    /// beside a 36 pt `display` numeral (D3's PNGs). The two-tier control law is
    /// a size law as well as a colour one, and this is the size half of it.
    static let ghostIconPointSize: CGFloat = 18
    static let iconOnlyWeight: NSFont.Weight = .medium

    /// The point size an icon-only button's glyph is built at. Per-variant
    /// rather than one number, because the chrome tier and the app tier are
    /// deliberately different weights of presence (design.html §06).
    static func iconOnlyPointSize(variant: LedgeButtonVariant) -> CGFloat {
        variant == .ghost ? ghostIconPointSize : iconOnlyPointSize
    }
    /// Disabled content alpha (D6). The background does not dim — the control is
    /// still there, it just has nothing to say yet.
    static let disabledAlpha: CGFloat = 0.35

    // MARK: - Press (D5, law L4)

    static let pressScaleLabeled: CGFloat = 0.96
    static let pressScaleIcon: CGFloat = 0.92
    static let pressDurationIn: TimeInterval = 0.08
    static let pressDurationOut: TimeInterval = 0.12
    /// Hover washes and other state changes: `LedgeMotion.fast` (Theme.swift).
    /// It used to be a 0.12 declared here and consumed by nobody — two duration
    /// tables where the principle allows one. Layout ticks animate never.
    static let hoverDuration: TimeInterval = LedgeMotion.fast

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
    /// Icon button: a 34 pt circle with a tint-only hover. Named for the app
    /// strip it was born in; the strip is gone (flow.md has no bottom bar) but
    /// the control survives it in the chrome surfaces.
    static let stripIcon: CGFloat = 34
    static let stripIconPointSize: CGFloat = 14
    static let stripIconWeight: NSFont.Weight = .medium
    static let stripActiveDot: CGFloat = 4
    static let stripActiveDotInset: CGFloat = 3

    // MARK: - Collapsed-wing meter (spec §3.3 extension, flow.md's "meter")

    /// The stock bar an app gets from `wing: { meter: { value } }`. Every number
    /// is the shell's — design.html §02's meter chip is 64 × 3, rounded — which
    /// is the whole point of the form: two apps' meters are the same object,
    /// where two hand-drawn canvases never were.
    static let wingMeterWidth: CGFloat = 64
    static let wingMeterHeight: CGFloat = 3

    // MARK: - Panel wings (the hardware-cutout exclusion row)

    /// Breathing room either side of the hardware cutout before a zone starts.
    /// The cutout's own edges are antialiased against a hole in the display, so
    /// content flush against them reads as content that is *slightly* clipped —
    /// which is worse than content that is obviously inset.
    static let panelWingCutoutMargin: CGFloat = 8
    /// Inset from the **bar's** own ends to a zone's content (design.html §01
    /// `.bar { padding: 0 10px }`). Not the panel's ends: the bar is a fixed
    /// width and the controls hang off *its* outer edges, so this number is
    /// measured from something that never moves.
    static let panelWingPad: CGFloat = 10
    /// How far the visit bar reaches past the hardware cutout on **each** side.
    ///
    /// The bar is a *fixed* width — the same on every session, every screen,
    /// every panel (principle 8: persistent controls are notch-anchored, never
    /// panel-anchored; principle 15: the number is stated once). design.html §01
    /// draws a 470 pt bar over a 168 pt cutout, which is 151 a side; 150 is that
    /// proportion, rounded to the grid.
    ///
    /// The consequence is the silhouette: a panel narrower than the bar hangs
    /// beneath it, centred, married by concave fillets (the mockup's 336 under
    /// its 470); a wider one meets the bar's edges. `ShellSurfaceView.notchPath`
    /// draws both as one body.
    static let visitBarWing: CGFloat = 150
    /// Gap between items an app puts in its left wing.
    static let panelWingGap: CGFloat = 6
    /// The default left-zone content: the app's catalog name, in the same face
    /// the collapsed wing label uses (D3 `s`/semibold, secondary ink).
    static let panelWingNamePointSize: CGFloat = 11.5
    static let panelWingNameWeight: NSFont.Weight = .semibold
    // MARK: - Parked (the torn-off window — design.html §04)

    /// How far the surface has to travel downward, from a drag that started on
    /// Ledge's own glass, before it **tears off** the notch. Long enough that a
    /// slipped click never parks the panel; short enough that the gesture is one
    /// deliberate pull rather than a haul across the screen.
    static let parkTearThreshold: CGFloat = 40
    /// Air around the ⌃ bead in the parked window's chrome row.
    static let parkedHomeInset: CGFloat = 8

    /// The `|` lane inside `‹|›` (`WingWalkerView`): the hairline is one point,
    /// but the thing you can hit is this wide. A one-point target is not a
    /// control, and this one opens the ledge overview.
    static let walkerDividerLane: CGFloat = 11

    // MARK: - The ledge (the overview — design.html §04)

    /// A slab: one session, standing on the shelf. 64 × 86 is the mockup's, and
    /// it is the *only* size a slab has — a strip too long for the panel pans
    /// (G3.2). `slabMinWidth` / `slabMinGap` were the squeeze that produced the
    /// sliced shelf the audit caught, and they are gone rather than unused.
    static let slabWidth: CGFloat = 64
    static let slabHeight: CGFloat = 86
    static let slabGap: CGFloat = 18
    /// How far the shelf's content fades out where the well cuts it — the
    /// ticker's mask in design.html §02, in points rather than percent, so the
    /// softening is the same on a shelf of three and a shelf of thirty.
    static let shelfFadeWidth: CGFloat = 22
    /// Top corners only: a slab **stands on** the shelf, so its bottom corners
    /// are square where they meet the hairline. The card rung (D4).
    static let slabRadius: CGFloat = rCard
    /// The room above the shelf — where the ✕ bead lives — **derived, not
    /// chosen**: a risen slab, the air above it, and the bead itself. The
    /// mockup's 44 was measured off a panel with no cutout row above it; here
    /// anything less puts the ✕ under the camera housing on the one frame a
    /// slab is fully up.
    ///
    /// A slab under the cursor both *lifts* by `slabRise` and *grows* about its
    /// bottom edge, so its top travels `slabRise + slabHeight · slabMagnify`.
    /// The growth was missing from this sum until G3.2 and the shortfall — 8.6
    /// points — went unnoticed because nothing above the shelf clipped: the ✕
    /// simply drew outside the surface. The shelf's well clips now, so the
    /// derivation has to be the whole of the travel or the bead loses its cap.
    static var shelfTopPad: CGFloat {
        slabRise + slabHeight * slabMagnify + slabCloseGap + Size.s.height
    }
    static let shelfPadX: CGFloat = 26
    static let shelfRoom: CGFloat = 40
    /// Air between a slab's top edge and the ✕ bead above it.
    static let slabCloseGap: CGFloat = 8

    /// **Slabs rise toward the cursor** (design.html §04's page script, copied
    /// whole): each slab is displaced by `rise · f` and scaled by `1 + magnify ·
    /// f`, where `f` is a gaussian of the pointer's distance from its centre.
    /// The transform origin is the slab's *bottom* — it is standing on a shelf,
    /// and a thing standing on a shelf grows upward.
    static let slabRise: CGFloat = 16
    static let slabMagnify: CGFloat = 0.10
    /// σ of that gaussian, in points. Wide enough that three slabs move at once
    /// (which is what makes it read as a surface rather than a hover state).
    static let slabFalloff: CGFloat = 72

    /// The app's catalog glyph, at the size the mockup draws it: big, white, and
    /// the only thing on the slab.
    static let slabGlyphPointSize: CGFloat = 22
    static let slabGlyphWeight: NSFont.Weight = .regular

    /// The gaussian itself, so the falloff is one function rather than a formula
    /// copied into a view and a test.
    static func slabMagnification(distance: CGFloat) -> CGFloat {
        exp(-(distance * distance) / (2 * slabFalloff * slabFalloff))
    }

    // MARK: - The swell (notification + summary)

    /// The chevron the shell draws on every summary, and the gap before it.
    /// It is the promise that another click opens the full thing (flow.md: "The
    /// summary always shows a quiet open affordance"), which is why the app
    /// cannot remove it — it is drawn by the surface, outside the app's node.
    static let swellChevronPointSize: CGFloat = 10
    static let swellChevronWeight: NSFont.Weight = .semibold
    static let swellChevronGap: CGFloat = 8
    static let swellChevronBox: CGFloat = 12

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

    // MARK: - Type ramp (D3, spec §5 `text.size` / `text.weight`)

    /// The one type ramp (principle 15). It lived inside `ProtocolRenderer.font`
    /// as a `switch` over five string literals, which meant every other surface
    /// that wanted "the `l` size" wrote `15` — the exact fork the principle
    /// names. Sizes are point sizes; nothing here is a scale factor, because a
    /// notch-scale ramp is chosen, not computed.
    enum TypeSize: String, CaseIterable {
        case xs
        case s
        case m
        case l
        case xl
        /// A single number that *is* the content — a temperature, a score, a
        /// clock. Bigger than `xl`, which is already the headline price.
        case display
        /// The largest thing Ledge draws: one numeral or glyph owning the whole
        /// well. Rationed to one per surface.
        case hero

        static let `default`: TypeSize = .m

        init(token: String?) {
            self = TypeSize(rawValue: token ?? "") ?? .default
        }

        var pointSize: CGFloat {
            switch self {
            case .xs: 10
            case .s: 11.5
            case .m: 12.5
            case .l: 15
            // The spec's own §3.1 example is `"$214.62"` at `xl`/`bold` — xl is
            // the headline price, not merely "a bit bigger".
            case .xl: 30
            case .display: 36
            case .hero: 48
            }
        }
    }

    /// The weight ramp. `light` joins it for the display/hero tier: a 48 pt
    /// numeral at `regular` is a wall, and the mockups' big numerals are all
    /// drawn at 300 (design.html `.numeral`, `.thesis`).
    enum TypeWeight: String, CaseIterable {
        case light
        case regular
        case medium
        case semibold
        case bold

        static let `default`: TypeWeight = .regular

        init(token: String?) {
            self = TypeWeight(rawValue: token ?? "") ?? .default
        }

        var fontWeight: NSFont.Weight {
            switch self {
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    /// `text.caps` tracking, as a fraction of the point size. Uppercase letters
    /// set at their natural spacing read as a jam; +6% is the eyebrow tracking
    /// design.html already uses (`.sec-eyebrow`, `.mark`), stated once so a
    /// label and a section header can never disagree.
    static let capsTracking: CGFloat = 0.06

    // MARK: - Text

    static let textDefaultPointSize: CGFloat = TypeSize.default.pointSize
    /// Extra width over the measured string: a truncating NSTextField
    /// under-reports its own intrinsic width, so "$214.62" arrives as "$214…".
    static let textMeasureSlack: CGFloat = 6

    // MARK: - Wash (`stack.gradient`, spec §5 proposal)

    /// Where the wash has faded to nothing, as a fraction of the container's
    /// height. Stated once, here, for the same reason every other number is:
    /// the geometry of a wash is the shell's, so every app's looks alike and a
    /// change to the recipe is a change in one place.
    static let washEnd: CGFloat = 0.6

    // MARK: - Bead (the convex control — `LedgeTheme.bead*` owns its colors)

    /// The inset edge that makes a bead convex: one point, top and bottom.
    static let beadEdgeWidth: CGFloat = 1
    /// How far a pressed bead sinks. Half a point is deliberately almost
    /// nothing — the deepening inset does the talking, and a control that
    /// *moves* a full point on the notch reads as a wobble.
    static let beadPressSink: CGFloat = 0.5

    // MARK: - List row (`LedgeRowView`)

    /// A row is full-bleed: the fill and the divider run edge to edge, and only
    /// the *content* is inset. That is what makes a list read as one column
    /// rather than a stack of cards.
    static let rowHeight: CGFloat = 34
    static let rowPadX: CGFloat = padCard
    /// Minimum air between a row's leading text and its trailing value.
    static let rowGap: CGFloat = gap
    /// The chevron: small, tertiary, and the last thing in the row.
    static let rowChevronPointSize: CGFloat = 10
    static let rowChevronWeight: NSFont.Weight = .semibold

    // MARK: - Empty state (`LedgeEmptyState`)

    /// The glyph sits at the display tier — big enough to be the thing you see,
    /// small enough that it is still furniture.
    static let emptyGlyphPointSize: CGFloat = TypeSize.display.pointSize
    static let emptyGlyphWeight: NSFont.Weight = .light
    /// Glyph → line, and line → action.
    static let emptyGlyphGap: CGFloat = 14
    static let emptyActionGap: CGFloat = 16
    static let emptyPad: CGFloat = 24

    // MARK: - Cards & canvases

    static let canvasRadius: CGFloat = rChip
    static let errorCardPad: CGFloat = 16
}
