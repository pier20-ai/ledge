// Ledge's JSX source (tsconfig `jsxImportSource: "@ledge/jsx"`): runtime
// behavior is React's, but the JSX namespace exposes ONLY the Ledge component
// vocabulary (spec §5) — apps get autocomplete for <stack>/<text>/…, and DOM
// elements are compile errors.

import type { ReactElement, ReactNode } from "react";

export { Fragment, jsx, jsxs } from "react/jsx-runtime";

type SemanticColor =
  | "primary"
  | "secondary"
  | "tertiary"
  | "green"
  | "red"
  | "accent"
  | "cyan"
  | "violet";

/** Container background tokens (spec §5 proposal — see protocol/README.md).
 * Semantic names only: the shell owns the palette, so an app can't hard-code a
 * color that a theme change would strand. */
type FillToken =
  | "raised"
  | "raisedHover"
  | "accentTint"
  | "greenTint"
  | "redTint"
  | "violetTint"
  | "black";
/** Container border tokens; always a 1 pt hairline. */
type StrokeToken = "hairline" | "accent" | "green" | "red" | "violet";

/** Wash hue families (spec §5 proposal). A `gradient` names the family only —
 * the shell owns the geometry (hue at the top, transparent by 60% of the
 * height), so every app's wash is the same material and panels stay siblings.
 * Free-form gradients belong inside a `canvas`, where the pixels are yours. */
type GradientToken = "accent" | "green" | "red" | "violet" | "cyan";

/** Pill hue families (design D6 "New kinds"). A tone names a *family* — the
 * shell derives the tint + stroke + ink triple from it, so an app can't pick
 * two of the three and land off-family. */
type PillTone = "accent" | "green" | "red" | "violet" | "cyan" | "neutral";

/** Meter hue families (`progress.color`). The same five words as `gradient`,
 * and for the same reason — the shell owns the ink, so two apps' accent meters
 * are the same accent. Ink shades are deliberately absent: `primary` and
 * friends are *type* colours, and the default already is ink. */
type MeterColor = "accent" | "green" | "red" | "violet" | "cyan";

/** Control height ramp (D8/Q4): s 28 · m 34 (default) · l 40, capsule at every
 * size. A number here would invite the off-ramp values the ruling removed. */
type ControlSize = "s" | "m" | "l";

export interface StackProps {
  axis?: "h" | "v";
  gap?: number;
  pad?: number;
  align?: "leading" | "center" | "trailing";
  distribute?: "fill" | "equal";
  flex?: number;
  scroll?: boolean;
  fill?: FillToken;
  stroke?: StrokeToken;
  /** A soft wash behind the children — combines with `fill`. */
  gradient?: GradientToken;
  radius?: number;
  children?: ReactNode;
  key?: string | number;
}

export interface TextProps {
  content: string;
  /** The one type ramp (spec §5, LedgeMetrics.TypeSize): xs 10 · s 11.5 · m
   * 12.5 · l 15 · xl 30 · `display` 36 · `hero` 48. `display` is a single
   * number that *is* the content (a clock, a score); `hero` is the largest
   * thing Ledge draws and is rationed to one per surface. */
  size?: "xs" | "s" | "m" | "l" | "xl" | "display" | "hero";
  /** `light` exists for the display/hero tier — a 48 pt numeral at `regular`
   * is a wall (design.html `.numeral`). */
  weight?: "light" | "regular" | "medium" | "semibold" | "bold";
  color?: SemanticColor;
  mono?: boolean;
  /** Uppercase **and** track out +6% (spec §5). One prop, because uppercase at
   * natural spacing is a jam — an app that could ask for only half of it would
   * ship the half that looks wrong. The eyebrow treatment. */
  caps?: boolean;
  /** Wrap up to N lines, then tail-truncate. Omitted (or 1) is one line —
   * multi-line is opt-in so nothing ever wraps behind the app's back (law L7). */
  maxLines?: number;
  /** Default true = tail ellipsis. False clips instead, for content where an
   * ellipsis would read as part of the value (a clock, a ticker). */
  truncate?: boolean;
  key?: string | number;
}

/**
 * A hairline rule between rows (spec §5). No props: where it goes is the app's
 * decision, what it looks like is the shell's.
 *
 * It exists because nothing else could draw one — a `stack` with a `stroke`
 * outlines what it contains, and a stack containing nothing is zero points tall.
 * Horizontal only, like `stack scroll` is vertical only: in a row, separation is
 * already `gap` and `spacer`.
 */
export interface DividerProps {
  key?: string | number;
}

export interface ButtonProps {
  label?: string;
  /** Leading SF Symbol, "sf:<name>" (spec §5 proposal). */
  icon?: string;
  /**
   * The two-tier control law (design.html §06). **`ghost`** is the app tier: a
   * bare pure-white glyph with no background, and a `raisedHover` capsule only
   * under the cursor — reach for it before `glass` or `accent` for anything
   * that lives among content, which is nearly everything an app draws.
   *
   * `bead` (Ledge's own convex chrome) is deliberately absent: an app that
   * could name it would make its buttons indistinguishable from the shell's.
   */
  variant?: "plain" | "glass" | "accent" | "ghost";
  /** Height ramp, default "m" (D8/Q4). */
  size?: ControlSize;
  /** Content at .35 alpha, no hover, no press — the shell also stops emitting
   * `click`, so a disabled button is inert on both sides of the wire. */
  disabled?: boolean;
  onClick?: () => void;
  /**
   * A child *instead of* a label — the form §5 has always specified, and the one
   * a list row needs: the whole row is the tap target and its inside is an
   * ordinary tree (a ticker, a sparkline, a price) that no string could be. The
   * child brings the size; `variant="plain"` supplies the hover wash and the
   * press. `label`, `icon` and `size` describe the *other* form and are ignored
   * while a child is present.
   */
  children?: ReactNode;
  key?: string | number;
}

export interface ImageProps {
  /** An SF Symbol (`"sf:<name>"`), or an **absolute** path to a file the app
   * owns — build it from `import.meta.dir`. The picture aspect-fills the `w × h`
   * box and `radius` clips it (see protocol/README.md). */
  src: string;
  w?: number;
  h?: number;
  radius?: number;
  /**
   * A 1 pt hairline ring on the picture itself — the same token vocabulary a
   * `stack` names. Artwork letterboxes: a sleeve whose bitmap does not fill its
   * box, or has not landed yet, still has to keep the frame the layout drew for
   * it. Do not reach for a stroked wrapper stack instead — that double-frames
   * the picture the moment the bitmap *does* fill the box.
   */
  stroke?: StrokeToken;
  key?: string | number;
}

export interface SpacerProps {
  min?: number;
  key?: string | number;
}

export interface ChartProps {
  points: number[];
  color?: SemanticColor;
  fill?: boolean;
  key?: string | number;
}

export interface SliderProps {
  /** In `min`…`max` space (default 0…1), snapped to `step`. */
  value: number;
  min?: number;
  max?: number;
  step?: number;
  /**
   * Value units per second of shell-side self-advance. While it is non-zero and
   * the panel is on screen, the shell moves the thumb itself between commits and
   * a new `value` re-anchors it — so a scrubber glides at 60 fps off a monitor
   * that polls every three seconds. 0 or absent is the static behavior.
   *
   * A drag suspends it; the `change` event still carries the dragged value.
   */
  rate?: number;
  onChange?: (data: { value: number }) => void;
  key?: string | number;
}

export interface InputProps {
  value?: string;
  placeholder?: string;
  onChange?: (data: { value: string }) => void;
  onSubmit?: (data: { value: string }) => void;
  key?: string | number;
}

// The six kinds ratified in design D6 "New kinds" / D8/Q5. Each replaces
// something apps were hand-rolling out of stacks and buttons, so the vocabulary
// grows by six and every app's tree gets smaller. None takes children.

export interface ToggleProps {
  on: boolean;
  disabled?: boolean;
  onChange?: (data: { on: boolean }) => void;
  key?: string | number;
}

export interface SegmentOption {
  id: string;
  label: string;
}

export interface SegmentProps {
  options: SegmentOption[];
  /** The selected option's `id`. Controlled, like every other Ledge prop: the
   * shell reports the tap and the app decides what the value becomes. */
  value: string;
  onChange?: (data: { value: string }) => void;
  key?: string | number;
}

export interface StepperProps {
  value: number;
  min?: number;
  max?: number;
  step?: number;
  /** Display string shown instead of the raw number — the app owns formatting
   * (07:45, 3 cups), because the shell can't know the unit. */
  format?: string;
  onChange?: (data: { value: number }) => void;
  key?: string | number;
}

export interface ProgressProps {
  /** 0…1. Read-only by definition — a progress bar that accepts input is a
   * slider (D6); indeterminate is `spinner`. */
  value: number;
  /** Fraction per second of shell-side self-advance — see `SliderProps.rate`.
   * A five-minute countdown is `rate={1 / 300}` and one commit. */
  rate?: number;
  /** The fill's hue family. **Default is ink, and ink is usually right** — a
   * meter takes a colour when the thing it measures is the point of the panel
   * (design.html §01 draws Focus's running session in accent). A panel where
   * every bar is coloured has said nothing. */
  color?: MeterColor;
  key?: string | number;
}

export interface SpinnerProps {
  key?: string | number;
}

export interface PillProps {
  label: string;
  tone?: PillTone;
  key?: string | number;
}

/**
 * A **panel wing**: the app's content for the zone beside the hardware cutout at
 * the top of its expanded panel. Valid **only as a direct child of the root
 * stack** — a wing nested in a card would render somewhere its parent cannot
 * see, so the wire rejects the whole commit (§3.1).
 *
 * These are not the collapsed §3.3 wings (`ctx.wing`): those are the
 * live-activity areas on the pill and belong to whichever app asked last. This
 * is a zone of the app's own panel, and it only exists while that panel is open.
 *
 * `side` is `"left"` and nothing else. The right zone carries the app's name and
 * the Edit affordance, and an app that could take that over could take away the
 * one control that is supposed to always be there — so `"right"` is a §5
 * validation error, not a request the shell declines.
 */
/**
 * The **mini view** (spec §3.3 extension): what this app shows in the small
 * surface below the notch when it peeks. One per app, mounted as a sibling of
 * the panel's root — like `wing`, this is a zone rather than a child of the
 * layout it appears beside.
 *
 * Declarative on purpose. The app keeps `<mini>` current as its state changes,
 * and `ctx.peek(ms)` only decides *when* it is shown. That is what makes the
 * surface instant: the shell already holds a live view of it, so a peek — or a
 * hover promoting one to the full panel — needs no round trip to the worker.
 * The alternative, a "which view am I in" prop the app re-renders against,
 * costs a worker hop on every hover, which is precisely the gesture that has to
 * feel immediate.
 *
 * Keep it to one line. The surface is sized to a glance — artwork, a title, a
 * subtitle — and it clips rather than growing to fit.
 */
export interface MiniProps {
  children?: ReactNode;
  key?: string | number;
}

/**
 * The **summary** (spec §5, flow.md): what this session shows when the pointer
 * rests on the notch past **Th** — the chess position in plain lingo, the temp
 * and the next hour. A sibling of the panel's root, exactly like `mini`.
 *
 * The difference between the two swells is *who raises the surface*, and that
 * is entirely the shell's decision: a notification is the app interrupting, a
 * summary is the user asking. An app cannot request one and cannot refuse one —
 * it only declares what one would say.
 *
 * Declaring it is what makes a session **heavy**. A session with a `<summary>`
 * shows it on hover; a session without one is its own summary and the same
 * hover opens the visit directly. Now Playing and Focus need no summary; chess
 * and weather owe one.
 *
 * Keep it to one line, like `mini`. The shell adds a trailing chevron of its own
 * — the promise that another click opens the full thing — and an app cannot
 * remove it.
 */
export interface SummaryProps {
  children?: ReactNode;
  key?: string | number;
}

export interface WingProps {
  side: "left";
  children?: ReactNode;
  key?: string | number;
}

/** The phases of a `canvas` drag (spec §4.1 `drag`). `move` arrives throttled
 * shell-side (~30 Hz); `down` and `up` never are, and `up` carries the final
 * position — so the app never has to guess where a coalesced gesture ended. */
export type DragPhase = "down" | "move" | "up";

export interface CanvasProps {
  w: number;
  h: number;
  focusable?: boolean;
  onKey?: (data: { key: string; down: boolean }) => void;
  /** Canvas-local `{x, y}`, the same y-down space as the draw ops (§3.4). */
  onClick?: (data: { x: number; y: number }) => void;
  /**
   * Press-drag-release — what a scrubber, a knob or a sketch surface is made
   * of. The point is **not clamped to the canvas**: a knob dragged past the
   * edge keeps tracking, and what an out-of-range x means is the app's call.
   */
  onDrag?: (data: { phase: DragPhase; x: number; y: number }) => void;
  key?: string | number;
}

export declare namespace JSX {
  type Element = ReactElement;
  type ElementType =
    | keyof IntrinsicElements
    | ((props: never) => Element | null);
  interface ElementChildrenAttribute {
    children: unknown;
  }
  interface IntrinsicElements {
    stack: StackProps;
    text: TextProps;
    button: ButtonProps;
    image: ImageProps;
    spacer: SpacerProps;
    divider: DividerProps;
    chart: ChartProps;
    slider: SliderProps;
    input: InputProps;
    canvas: CanvasProps;
    mini: MiniProps;
    summary: SummaryProps;
    toggle: ToggleProps;
    segment: SegmentProps;
    stepper: StepperProps;
    progress: ProgressProps;
    spinner: SpinnerProps;
    pill: PillProps;
    wing: WingProps;
  }
}
