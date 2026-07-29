// Record one app's mount commit as JSON, for the Swift snapshot replay.
//
// This renders `app.jsx` once through the *real* reconciler into an in-memory
// sink — the same code path a live worker uses (src/render/session.ts) — and
// writes the resulting spec §3.1 batch to disk. `LedgeShell --snapshots` then
// replays that batch through ProtocolEngine/ProtocolRenderer into a PNG, so the
// picture is evidence about the protocol path rather than about a mock.
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

import { basename, dirname, resolve } from "node:path";
import { InMemorySink } from "../src/render/mutations";
import { createAppSession } from "../src/render/session";
import { loadReactRuntime } from "../src/render/runtime";
import { sanitizeAppMeta } from "../src/worker/meta";

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

const entryPath = resolve(entry);
const appId = basename(dirname(entryPath));
const module = (await import(entryPath)) as {
  default?: (props: Record<string, unknown>) => unknown;
  meta?: unknown;
};
// The same sanitizer the worker runs before posting `meta` (spec §6), so the
// snapshot's catalog row is byte-for-byte the row a live host would publish.
const meta = sanitizeAppMeta(module.meta);

if (typeof module.default !== "function") {
  console.error(`${entryPath} has no default-exported component`);
  process.exit(1);
}

const sink = new InMemorySink();
// React comes from the apps root, same as in a worker — one instance,
// resolved from disk (see src/render/runtime.ts).
const runtime = await loadReactRuntime(dirname(dirname(entryPath)));
const session = createAppSession(module.default as never, sink, runtime);

const mount = sink.commits[0];
if (!mount) {
  console.error(`${entryPath} rendered no commit`);
  process.exit(1);
}

if (click !== null) {
  // `onClick: true` is how a handler crosses the wire (§5), so the mount batch
  // is also the list of what the user could have tapped.
  const clickable = mount.filter(
    (mutation) => mutation.op === "create" && mutation.props.onClick === true,
  );
  const target = clickable[click];
  if (!target || target.op !== "create") {
    console.error(`--click ${click}: only ${clickable.length} clickable nodes in the mount`);
    process.exit(1);
  }
  if (!session.dispatchEvent(target.id, "click", {})) {
    console.error(`--click ${click}: no handler registered for node ${target.id}`);
    process.exit(1);
  }
}

const mutations = sink.commits.flat();

await Bun.write(
  resolve(output),
  `${JSON.stringify(
    {
      app: appId,
      name: meta.name ?? appId,
      icon: meta.icon ?? "sf:square.dashed",
      order,
      ...(meta.panel ? { panel: meta.panel } : {}),
      mutations,
    },
    null,
    2,
  )}\n`,
);

console.log(
  `[dump-commits] ${appId}: ${mutations.length} mutations` +
    `${click === null ? "" : ` (mount + click ${click})`} -> ${output}`,
);
