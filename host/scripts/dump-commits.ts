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
// Usage: bun scripts/dump-commits.ts <path/to/app.jsx> <out.json> [--order N] [--click N]
//
// The app is imported, so its module body runs (monitors are NOT started — only
// the default export is mounted, with its default props).
//
// `--click N` dispatches a `click` at the **N-th clickable node in mount order**
// (0-based) and appends the commit that re-render produces. That is how a page an
// app only reaches through an interaction gets snapshotted: a mount batch shows
// the list, `--click 0` shows what tapping its first row does. Batches are
// concatenated rather than kept apart because §3.1 applies mutations in array
// order and validates the lot — replaying "mount, then this" is exactly what a
// live shell does, one envelope later.

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

if (!entry || !output) {
  console.error(
    "usage: bun scripts/dump-commits.ts <app.jsx> <out.json> [--order N] [--click N]",
  );
  process.exit(1);
}

let dump;
try {
  dump = await renderAppCommit({ entryPath: entry, order, click });
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

await Bun.write(resolve(output), `${JSON.stringify(dump, null, 2)}\n`);
console.log(
  `[dump-commits] ${dump.app}: ${dump.mutations.length} mutations` +
    `${click === null ? "" : ` (mount + click ${click})`} -> ${output}`,
);
