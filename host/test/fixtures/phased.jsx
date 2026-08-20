/** @jsxImportSource react */
// Fixture: an app that re-renders from its panel lifecycle phase via the
// optional onLifecycle export (spec §4.2 — pacing work by panel phase), and
// reports `ctx.reduceMotion` alongside it, which rides the same message.

export function onLifecycle(phase, ctx) {
  if (phase === "explode") throw new Error("bad phase handler");
  // Read as a property, not from an argument: the value has to be current when
  // a frame loop asks, and the callback is only the nudge.
  ctx.update({ phase, still: ctx.reduceMotion });
}

export default function Phased({ phase = "none", still = false }) {
  return <text content={`phase ${phase}${still ? " still" : ""}`} />;
}
