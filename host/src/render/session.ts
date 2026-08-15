// One app's render session (spec §6): `ctx.update(patch)` shallow-merges into
// an in-memory props object and schedules a re-render of the default export.
// This is the sole monitor → UI bridge; persistence is the app's own business.

import type { ComponentType } from "react";
import type { MutationSink } from "./mutations";
import { createLedgeRenderer, type LedgeRenderer } from "./reconciler";
import type { ReactRuntime } from "./runtime";

export interface AppSession {
  /** Shallow-merge and re-render. */
  update(patch: Record<string, unknown>): void;
  /** Current merged props (rebuilt from scratch by a fresh monitor on reload). */
  readonly props: Record<string, unknown>;
  dispatchEvent: LedgeRenderer["dispatchEvent"];
  unmount(): void;
}

export function createAppSession(
  App: ComponentType<Record<string, unknown>>,
  sink: MutationSink,
  runtime: ReactRuntime,
  /** Props to mount with, before any `ctx.update`. A live worker always starts
   * empty (the app's own defaults are the first frame); this is for the snapshot
   * harness's `--props`, which needs to see a data-driven state without an app
   * having to grow a throwaway preview module. */
  initialProps: Record<string, unknown> = {},
): AppSession {
  const renderer = createLedgeRenderer(sink, runtime);
  let props: Record<string, unknown> = { ...initialProps };

  const render = () => renderer.render(runtime.createElement(App, props));
  render();

  return {
    update(patch) {
      props = { ...props, ...patch };
      render();
    },
    get props() {
      return props;
    },
    dispatchEvent: (id, name, data) => renderer.dispatchEvent(id, name, data),
    unmount: () => renderer.unmount(),
  };
}
