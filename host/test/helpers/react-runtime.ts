// Test-side React runtime.
//
// Tests resolve React through `loadReactRuntime` exactly as a worker does —
// against the host package's own node_modules — rather than importing it
// statically. That keeps the tests on the real resolution path, which is the
// path that differs between `bun test` and `bun build --compile` (see
// src/render/runtime.ts).

import { join } from "node:path";
import { loadReactRuntime } from "../../src/render/runtime";
import { createLedgeRenderer, type LedgeRenderer } from "../../src/render/reconciler";
import { createAppSession, type AppSession } from "../../src/render/session";
import type { MutationSink } from "../../src/render/mutations";

/** host/ — the package whose node_modules holds react + react-reconciler. */
const HOST_ROOT = join(import.meta.dir, "..", "..");

export const reactRuntime = await loadReactRuntime(HOST_ROOT);

/** `createAppSession` with the runtime already supplied. */
export function mountApp(
  App: Parameters<typeof createAppSession>[0],
  sink: MutationSink,
): AppSession {
  return createAppSession(App, sink, reactRuntime);
}

/** `createLedgeRenderer` with the runtime already supplied. */
export function makeRenderer(sink: MutationSink): LedgeRenderer {
  return createLedgeRenderer(sink, reactRuntime);
}
