// Record one app's mount commit as JSON, for the Swift snapshot replay.
//
// This renders `app.jsx` once through the *real* reconciler into an in-memory
// sink — the same code path a live worker uses (src/render/session.ts) — and
// writes the resulting spec §3.1 batch to disk. `LedgeShell --snapshots` then
// replays that batch through ProtocolEngine/ProtocolRenderer into a PNG, so the
// picture is evidence about the protocol path rather than about a mock.
//
// Usage: bun scripts/dump-commits.ts <path/to/app.jsx> <out.json> [--order N]
//
// The app is imported, so its module body runs (monitors are NOT started — only
// the default export is mounted, with its default props).

import { basename, dirname, resolve } from "node:path";
import { InMemorySink } from "../src/render/mutations";
import { createAppSession } from "../src/render/session";
import { sanitizeAppMeta } from "../src/worker/meta";

const args = Bun.argv.slice(2);
const positional = args.filter((arg) => !arg.startsWith("--"));
const entry = positional[0];
const output = positional[1];
const orderFlag = args.indexOf("--order");
const order = orderFlag >= 0 ? Number(args[orderFlag + 1] ?? 0) : 0;

if (!entry || !output) {
  console.error("usage: bun scripts/dump-commits.ts <app.jsx> <out.json> [--order N]");
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
createAppSession(module.default as never, sink);

const mutations = sink.commits[0];
if (!mutations) {
  console.error(`${entryPath} rendered no commit`);
  process.exit(1);
}

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

console.log(`[dump-commits] ${appId}: ${mutations.length} mutations -> ${output}`);
