import AppKit
import QuartzCore

enum LedgeTheme {
    static let glass = NSColor.black.withAlphaComponent(0.92)
    static let glassSolid = NSColor.black
    static let raised = NSColor(white: 1, alpha: 0.055)
    static let raisedHover = NSColor(white: 1, alpha: 0.085)
    /// The *glass* button's hover wash — one step above `raisedHover`, because a
    /// glass button starts at `raised` and would otherwise barely move (D1).
    static let raisedHover2 = NSColor(white: 1, alpha: 0.10)
    static let hairline = NSColor(white: 1, alpha: 0.09)
    /// A hairline that is being hovered. Same value as `track`, different job —
    /// naming the intent is what keeps a future track tweak out of the buttons.
    static let hairlineHover = NSColor(white: 1, alpha: 0.14)
    static let track = NSColor(white: 1, alpha: 0.14)
    /// Progress made of ink, not brand (D8/Q6): slider fill, progress bar fill.
    static let inkFill = NSColor(white: 1, alpha: 0.85)
    /// The selected segment's wash (D6 `segment`).
    static let selected = NSColor(white: 1, alpha: 0.12)
    static let primary = NSColor(white: 1, alpha: 0.94)
    static let secondary = NSColor(white: 1, alpha: 0.56)
    static let tertiary = NSColor(white: 1, alpha: 0.32)
    static let accent = NSColor(srgbRed: 1, green: 180 / 255, blue: 84 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 1)
    static let red = NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 1)
    static let violet = NSColor(displayP3Red: 0.56, green: 0.38, blue: 1, alpha: 1)
    static let cyan = NSColor(displayP3Red: 0.18, green: 0.82, blue: 0.94, alpha: 1)
    static let blue = NSColor(displayP3Red: 0.24, green: 0.54, blue: 1, alpha: 1)

    // MARK: - Semantic container tokens (spec §5 proposal: stack fill/stroke)
    //
    // Apps name an *intent*, never a color: the shell owns the palette, so a
    // theme change is a change here and nowhere else. Same reasoning as the
    // semantic `text.color` vocabulary already in §5.
    static let accentTint = accent.withAlphaComponent(0.10)
    static let greenTint = green.withAlphaComponent(0.09)
    static let redTint = red.withAlphaComponent(0.09)
    static let sunken = NSColor.black.withAlphaComponent(0.35)
    static let accentStroke = accent.withAlphaComponent(0.25)
    static let greenStroke = green.withAlphaComponent(0.25)
    static let redStroke = red.withAlphaComponent(0.25)
    static let violetTint = violet.withAlphaComponent(0.08)
    static let violetStroke = violet.withAlphaComponent(0.20)
    /// Cyan completes the tint/stroke set so `pill tone="cyan"` (D6) is a triple
    /// from the theme like every other hue, not an improvised alpha.
    static let cyanTint = cyan.withAlphaComponent(0.09)
    static let cyanStroke = cyan.withAlphaComponent(0.25)

    /// `stack.gradient` — the top of the wash (spec §5 proposal). One alpha for
    /// every hue, because the point of a standardized wash is that two panels
    /// using different families still read as siblings. A tint is a flat fill
    /// you can see the edge of; a wash is this, and it has no edge.
    static let washAlpha: CGFloat = 0.22

    // MARK: - The bead (design.html `--bead-*`, principle 15)
    //
    // A Ledge control is not a rectangle drawn on the glass — it is the glass
    // *swelling*. That reads as convex because of three things and only three:
    // a fill that is brighter at the top than the bottom, a one-point specular
    // line along the top edge, and a one-point shadow along the bottom. The
    // values are design.html's, copied whole; the geometry that turns them into
    // layers is `LedgeMetrics.bead*` and `LedgeButton`'s `bead` variant.

    /// `--bead-fill`, top stop.
    static let beadFillTop = NSColor(white: 1, alpha: 0.11)
    /// `--bead-fill`, bottom stop.
    static let beadFillBottom = NSColor(white: 1, alpha: 0.05)
    /// `--bead-fill-hover`. A bead brightens under the cursor; it does not grow,
    /// gain a border, or change hue.
    static let beadFillTopHover = NSColor(white: 1, alpha: 0.17)
    static let beadFillBottomHover = NSColor(white: 1, alpha: 0.09)
    /// `--bead-edge`, `inset 0 1px 0` — the specular line that makes it convex.
    static let beadEdgeHighlight = NSColor(white: 1, alpha: 0.16)
    /// `--bead-edge`, `inset 0 -1px 1px` — the under-shadow.
    static let beadEdgeShadow = NSColor.black.withAlphaComponent(0.5)
    /// `.bead:active` — pressed, the inset deepens all the way round, so the
    /// swelling reads as pushed *into* the glass rather than merely darker.
    static let beadEdgePressed = NSColor.black.withAlphaComponent(0.55)

    /// **The hover ring.** A hairline all the way round a control the cursor is
    /// on, drawn *in addition to* whatever that control's hover already does —
    /// the bead still brightens, the ghost still washes.
    ///
    /// The brighten alone is a change of degree, and at notch scale over a busy
    /// stage a degree is not enough to answer "is the cursor on it or beside
    /// it": a bead's fill goes from 11% to 17% of white, which is a difference
    /// you can only see by comparing it with a bead you are *not* hovering. A
    /// ring is a change of kind, and it reads instantly with nothing to compare
    /// against. Same value as the bead's own specular edge, deliberately — the
    /// ring is that edge continued round the control, not a new material.
    static let hoverRing = NSColor(white: 1, alpha: 0.16)

    // MARK: - The slab (design.html §04 `.slab`, the ledge overview)
    //
    // A session, seen edge-on: a pane of the same glass standing on the shelf.
    // Brighter than a bead because it is *further forward* — the overview is the
    // strip lifted off the panel and stood up, and a slab that read as quiet as
    // the chrome around it would look like a placeholder rather than a thing you
    // can pick up.

    /// `.slab` fill, top stop.
    static let slabFillTop = NSColor(white: 1, alpha: 0.20)
    /// `.slab` fill, bottom stop.
    static let slabFillBottom = NSColor(white: 1, alpha: 0.075)
    /// `inset 0 1px 0` — the specular line along the slab's top edge.
    static let slabEdgeHighlight = NSColor(white: 1, alpha: 0.32)
    /// `inset ±1px 0 0` — the two side edges, far quieter than the top.
    static let slabEdgeSide = NSColor(white: 1, alpha: 0.08)
    /// The same, on the slab under the cursor: the whole slab brightens a step
    /// as it rises, which is the only state a slab has.
    static let slabEdgeHighlightHover = NSColor(white: 1, alpha: 0.38)

    static func systemFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func numericFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

/// The chat pane's material (design.html §01 `.glasspanel`, flow.md Material:
/// "The chat surface runs opaque at the top to clear at the bottom; the prompt
/// pill sits where the glass is clearest").
///
/// It is a property of the **panel body**, not of anything drawn inside it: the
/// fade has to carry the fillets, the shoulder and the bottom radius with it, or
/// the silhouette stops being one body (principle 6). `ShellSurfaceView` paints
/// it into the shape it already owns.
enum LedgeGlass {
    struct Stop: Equatable {
        /// Where the stop sits in the **body** — the panel below the cutout
        /// exclusion row. The row itself is the notch and never fades.
        var at: CGFloat
        var color: NSColor
    }

    /// design.html drew `linear-gradient(rgba(5,5,6,.97) 0%, rgba(5,5,6,.66)
    /// 55%, rgba(12,13,18,.18) 100%)` — over the mockup's own dark page.
    ///
    /// **The floor is raised from .18 to .55.** On device, over a bright window,
    /// 18% of a near-black is not a material: a striped or high-contrast
    /// background came through the bottom of the pane essentially intact and the
    /// prompt — ink-2 on that — was unreadable. The blank slot, which is this
    /// same surface with no stage behind it, was the worst case of all.
    ///
    /// The character is unchanged and so is the reason for it: the pane still
    /// runs opaque at the top and clearest at the bottom, and the prompt pill
    /// still sits on the clearest glass in the product (flow.md, Material). It
    /// is simply clear *enough to see through* rather than clear enough to read
    /// the desktop through. `.97 → .74 → .55` keeps the same 55% inflection.
    ///
    /// This carries the legibility on its own. `ShellSurfaceView`'s frost blurs
    /// what is behind as well, which is what makes the bottom look like glass
    /// rather than a scrim — but the contrast does not depend on it, because a
    /// blur is a system effect that cannot be verified off-device.
    /// G2.3 ("a bit more glassy"): the midband at .66 lets the frost's blur
    /// show through where the bubbles float. G2.4 ("frosted textured glass,
    /// not see-through"): the floor rises to .60 — with the blur behind it the
    /// bottom reads as material, not as a window onto the desktop. The
    /// contrast law is measured against the gradient alone, frost excluded,
    /// and a higher floor only raises it.
    static let chat: [Stop] = [
        Stop(at: 0, color: NSColor(srgbRed: 5 / 255, green: 5 / 255, blue: 6 / 255, alpha: 0.97)),
        Stop(at: 0.55, color: NSColor(srgbRed: 5 / 255, green: 5 / 255, blue: 6 / 255, alpha: 0.66)),
        Stop(at: 1, color: NSColor(srgbRed: 12 / 255, green: 13 / 255, blue: 18 / 255, alpha: 0.60)),
    ]
}

/// The shadow ramp — three, and there is never a fourth (principle 15,
/// design.html `--shadow-mini/panel/window`).
///
/// One black glass body casts one of exactly three shadows, chosen by *how far
/// off the wall the surface is*: a swell is barely off it, the panel hangs from
/// it, a parked window has left it altogether. An `NSShadow` or a bare
/// `shadowRadius =` anywhere else in the shell is a defect even when the number
/// happens to be right.
struct LedgeShadow: Equatable {
    /// CSS `offset-y`, in points, positive = downward.
    let yOffset: CGFloat
    /// CSS `blur-radius`, in points.
    let blur: CGFloat
    /// The alpha of the black the shadow is made of.
    let opacity: Float

    /// The hover swell and the mini surface — a breath off the glass.
    static let swell = LedgeShadow(yOffset: 6, blur: 18, opacity: 0.35)
    /// The visit panel, hanging from the notch.
    static let panel = LedgeShadow(yOffset: 14, blur: 34, opacity: 0.45)
    /// The parked window, floating free of the seat entirely.
    static let window = LedgeShadow(yOffset: 18, blur: 40, opacity: 0.50)

    /// CoreAnimation's `shadowRadius` is a Gaussian sigma; CSS's blur radius is
    /// two of them. Stating the tokens in CSS units keeps them literally the
    /// same numbers as design.html — the conversion belongs here, once, not in
    /// every caller's head.
    var shadowRadius: CGFloat { blur / 2 }

    /// How far past a surface's edge the shadow is still visible: the offset
    /// plus two and a half sigmas of blur, beyond which the Gaussian tail is
    /// under one percent of the lit opacity. A window that has to *contain*
    /// its own shadow — the parked window's is drawn into a layer inside its
    /// frame — must leave at least this much round the body, or its edge cuts
    /// the shadow square. That was the parked corner defect, twice over: once
    /// with no margin at all, once with the notch's 28, which this ramp
    /// outreaches by more than half again.
    var reach: CGFloat { ceil(yOffset + shadowRadius * 2.5) }

    /// The offset in *layer* units. Ledge's chrome layers live under flipped
    /// views, where +y is down; an unflipped host has to negate it, which is
    /// why the caller says which it is rather than this guessing.
    func offset(flipped: Bool = true) -> CGSize {
        CGSize(width: 0, height: flipped ? yOffset : -yOffset)
    }

    /// Install the ramp's *geometry* on a layer. Opacity is deliberately left
    /// alone: a shadow that fades in as a surface opens is a state, and states
    /// are the view's business — the token only says what the shadow looks like
    /// once it is there. Use `opacity` for the lit value.
    func applyGeometry(to layer: CALayer, flipped: Bool = true) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = offset(flipped: flipped)
        layer.shadowRadius = shadowRadius
    }
}

/// The motion table — every duration and every spring in the shell (principle
/// 10: motion is the personality, so it cannot be improvised per view).
///
/// Two characters, not four. **pop** arrives: it overshoots once and comes
/// back, which is what makes a surface feel like it grew rather than appeared.
/// **settle** returns: critically damped, no overshoot, because a thing going
/// away that bounces on the way out reads as a glitch. Everything else in here
/// is one of those two at a different response — the damping is the character,
/// the response is the distance.
enum LedgeMotion {
    // MARK: - Durations

    /// A wash, a tint, an ink change — anything that does not move.
    static let fast: TimeInterval = 0.18
    /// A surface moving inside an already-open panel.
    static let move: TimeInterval = 0.38
    /// The notch itself travelling: opening, closing, parking, flying home.
    static let travel: TimeInterval = 0.56

    // MARK: - Springs

    /// A house spring, in the response/damping form CASpringAnimation is derived
    /// from — `response` is the undamped period in seconds, `damping` the ratio
    /// (1 = critical).
    struct Spring: Equatable {
        var response: CGFloat
        var damping: CGFloat

        /// The same spring over a different distance. Response is how far the
        /// surface has to go; the character stays the character.
        func responding(in response: CGFloat) -> Spring {
            Spring(response: response, damping: damping)
        }

        /// True when this spring will overshoot at all — the one bit that
        /// separates the two characters.
        var overshoots: Bool { damping < 1 }

        // MARK: The two characters

        /// **pop** — an arrival. One overshoot, then done.
        static let pop = Spring(response: 0.42, damping: 0.80)
        /// **settle** — a return. No overshoot at all.
        static let settle = Spring(response: 0.45, damping: 1.0)

        // MARK: The roles (each one of the two, at its own distance)

        /// The notch opening into a panel.
        static let open = pop
        /// The panel closing back into the notch.
        static let close = settle
        /// One surface becoming another inside a panel that is already open. A
        /// pop over a shorter distance and held slightly tighter, because the
        /// eye is already on it.
        static let morph = Spring(response: 0.40, damping: 0.85)
        /// The hover's promissory swell — the shortest, loosest pop in the
        /// house. It is a promise, so it has to look eager.
        static let bump = Spring(response: 0.30, damping: 0.75)
    }

    /// `LedgeMotion.pop` / `.settle` read better at a call site that is naming
    /// a character rather than picking a role.
    static let pop = Spring.pop
    static let settle = Spring.settle
}

/// The interaction knobs (flow.md, "Knobs, feel-tuned on device"). They live
/// beside `LedgeMotion` because they are the same kind of fact — the timing of
/// the personality — and because principle 15 allows exactly one source for a
/// number that more than one file reads.
///
/// Every one of these is *starting* values. They are named so the feel test can
/// change one number and see the whole product change with it, which is the
/// only way any of them will ever be right.
enum LedgeInteraction {
    // MARK: - The four knobs

    /// **Th** — how long the pointer has to rest on the notch before the shell
    /// commits to a surface. Below it the notch swells a breath: a promise, not
    /// a surface. At it, the summary (or the visit, for a session that declares
    /// no summary).
    ///
    /// 0.35 read as designed on paper and as *lag* on device; 0.15 was still
    /// slow to Manu's hand (G2.6). 0.1 keeps a breath of promise — a drive-by
    /// across the menu bar does not open anything — but a pointer that has
    /// come to the notch on purpose gets its surface at once. Feel-tuning
    /// continues on device.
    static let hoverThreshold: TimeInterval = 0.1

    /// **Ti** — an ambient notification's dwell. Alert-class holds until acted
    /// on or dismissed, so this number does not apply to it at all
    /// (`NotificationClass`).
    static let notificationDwell: TimeInterval = 6

    /// **Ta** — how long a wing holder may go quiet before the shell takes the
    /// wing back. Holder-declared per flow.md; this is the shell's default for a
    /// holder that declares nothing.
    static let ambientIdle: TimeInterval = 90

    /// **Texit** — how long the pointer must be *fully* away from the visit
    /// before it closes. Never runs while anything is in flight; see
    /// `ExitInhibitor`. 2.5 at ratification; 0.3 since G2.6 — Manu is
    /// feel-tuning the walk-away on device, and a visit that lingers seconds
    /// after the hand has left reads as a window, not a glance.
    static let exitDelay: TimeInterval = 0.3

    // MARK: - The promissory swell (hover < Th)

    /// How much wider the notch gets while it is promising. A few points: the
    /// whole content of the gesture is "I noticed", and anything you could
    /// measure by eye would be a surface instead of a promise.
    static let promiseWidth: CGFloat = 6
    /// …and how much taller. Down *and* out, like every swell (principle 7).
    static let promiseHeight: CGFloat = 2.5
}

extension NSColor {
    func withAlpha(_ alpha: CGFloat) -> NSColor {
        withAlphaComponent(alpha)
    }
}
