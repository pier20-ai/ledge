/** @jsxImportSource react */
// Fixture: an app that re-renders from its panel lifecycle phase via the
// optional onLifecycle export (spec §4.2 — pacing work by panel phase).

export function onLifecycle(phase, ctx) {
  if (phase === "explode") throw new Error("bad phase handler");
  ctx.update({ phase });
}

export default function Phased({ phase = "none" }) {
  return <text content={`phase ${phase}`} />;
}
