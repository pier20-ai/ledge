// Record one app's mount commit as JSON, for the Swift snapshot replay.
//
// A thin wrapper over src/snapshot.ts, which does the rendering and is also what
// `ledge shot` runs — one implementation, so the picture in a snapshot suite and
// the picture an agent asks for cannot come from different code.
//
// It renders `app.jsx` once through the *real* reconciler into an in-memory sink
// — the same code path a live worker uses (src/render/session.ts) — and writes
// the resulting spec §3.1 batch to disk. `LedgeShell --snapshots` then replays
// that batch through ProtocolEngine/ProtocolRenderer into a PNG, so the picture
// is evidence about the protocol path rather than about a mock.
//
// Usage:
//   bun scripts/dump-commits.ts <path/to/app.jsx> <out.json> \
//       [--order N] [--click N] [--props '<json>'] [--wing]
//
// The app is imported, so its module body runs (monitors are NOT started — only
// the default export is mounted, with its default props — unless `--wing`).
//
// `--click N` dispatches a `click` at the **N-th clickable node in mount order**
// (0-based) and appends the commit that re-render produces. That is how a page an
// app only reaches through an interaction gets snapshotted: a mount batch shows
// the list, `--click 0` shows what tapping its first row does. Batches are
// concatenated rather than kept apart because §3.1 applies mutations in array
// order and validates the lot — replaying "mount, then this" is exactly what a
// live shell does, one envelope later.
//
// `--props '<json>'` mounts with those props instead of the component's own
// defaults. Every data-driven app has an empty state and a real one, and the real
// one used to be reachable only by writing a throwaway preview module beside the
// app — a second source of truth about what the app looks like. This is the
// object a monitor would have handed it via `ctx.update`:
//
//     --props '{"track":{"title":"Rhubarb","artist":"Aphex Twin","done":0.4}}'
//
// `--wing` runs `monitor(ctx)` for ~400 ms against a recording `ctx` and keeps
// the first `ctx.wing` / `ctx.draw` it produces, so the app's *signature* — the
// collapsed pill it puts up — is rendered too, into `<app>-wing.png`. Bridge
// calls never settle (there is no host here), so an app that gets no further
// than its first `await ctx.apple…` produces no wing and says so.

import { resolve } from "node:path";
import { renderAppCommit } from "../src/snapshot";

const args = Bun.argv.slice(2);
const positional = args.filter((arg) => !arg.startsWith("--"));
const entry = positional[0];
const output = positional[1];
const orderFlag = args.indexOf("--order");
const order = orderFlag >= 0 ? Number(args[orderFlag + 1] ?? 0) : 0;
const clickFlag = args.indexOf("--click");
const click = clickFlag >= 0 ? Number(args[clickFlag + 1] ?? 0) : null;
const propsFlag = args.indexOf("--props");
const wing = args.includes("--wing");

if (!entry || !output) {
  console.error(
    "usage: bun scripts/dump-commits.ts <app.jsx> <out.json> " +
      "[--order N] [--click N] [--props '<json>'] [--wing]",
  );
  process.exit(1);
}

let props: Record<string, unknown> = {};
if (propsFlag >= 0) {
  const raw = args[propsFlag + 1];
  try {
    const parsed = JSON.parse(raw ?? "");
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error("not a JSON object");
    }
    props = parsed as Record<string, unknown>;
  } catch (error) {
    // Named loudly: a mistyped --props that silently rendered the empty state
    // would be a snapshot quietly asserting the wrong thing.
    console.error(`--props: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  }
}

let dump;
try {
  dump = await renderAppCommit({ entryPath: entry, order, click, props, wing });
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

await Bun.write(resolve(output), `${JSON.stringify(dump, null, 2)}\n`);
console.log(
  `[dump-commits] ${dump.app}: ${dump.mutations.length} mutations` +
    `${click === null ? "" : ` (mount + click ${click})`}` +
    `${propsFlag < 0 ? "" : ` (props: ${Object.keys(props).join(", ") || "none"})`}` +
    `${!wing ? "" : dump.wing ? ` (wing: ${JSON.stringify(dump.wing)})` : " (no wing captured)"}` +
    ` -> ${output}`,
);
// `--wing` ran the app's monitor, which parks forever and leaves its timers
// behind (spec §6). The dump is written; nothing is waiting on this process.
if (wing) process.exit(0);
