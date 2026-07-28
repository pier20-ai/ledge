// React, resolved from disk instead of imported.
//
// The rule: **the app's `react` and the reconciler's `react` must be the same
// module instance.** Hooks live in module-level state (`ReactCurrentDispatcher`),
// so two copies mean `dispatcher.useState of null` on an app's first `useState`.
//
// A static `import "react"` here satisfies that in development by accident — one
// node_modules on disk, one instance — and breaks it the moment the host is
// compiled. `bun build --compile` embeds every statically-imported module into
// the binary, while apps in `~/.ledge/apps` keep resolving their own copy off
// disk. Measured, both modes, same probe:
//
//     static import   → interpreted sameInstance:true   compiled sameInstance:FALSE
//     resolved below  → interpreted sameInstance:true   compiled sameInstance:true
//
// The compiled failure is silent at boot and only surfaces as every app crashing
// on its first hook, inside the .app bundle, which is the worst place to find it.
// So React is resolved through `Bun.resolveSync` against the modules root that
// the apps themselves resolve against (`~/.ledge/node_modules`, or the apps
// root's own `node_modules` in the repo). A computed specifier is invisible to
// the bundler, so nothing is embedded and there is exactly one copy in play.
//
// There is deliberately no fallback to a bare `import("react")`. A fallback
// would be a literal specifier — which the bundler *would* embed — so the trap
// this module exists to remove would come back as a rarely-taken branch.

import { resolve } from "node:path";
import type { ComponentType, ReactNode } from "react";

/** The React surface the renderer needs, all from one on-disk copy. */
export interface ReactRuntime {
  createElement(type: ComponentType<Record<string, unknown>>, props: Record<string, unknown>): ReactNode;
  /** `react-reconciler`'s default export — call with a host config. */
  createReconciler(config: unknown): unknown;
  /** `DefaultEventPriority` from react-reconciler/constants. */
  defaultEventPriority: number;
}

/** A module namespace that may or may not have been through an interop wrapper. */
function interop<T>(module: Record<string, unknown>): T {
  return (module.default ?? module) as T;
}

/**
 * Load React + react-reconciler from `modulesRoot` (the directory *containing*
 * `node_modules`, i.e. what `Bun.resolveSync`'s second argument wants).
 *
 * Throws with the root named if the packages aren't there — on a real install
 * that means first-run seeding didn't happen, and a clear error beats a null
 * dispatcher fifty frames later.
 */
export async function loadReactRuntime(modulesRoot: string): Promise<ReactRuntime> {
  // ABSOLUTE, always. `Bun.resolveSync` given a relative directory resolves
  // against the process cwd rather than that directory, so a host started as
  //
  //     cd host && bun src/host.ts --apps-root ../protocol/demo-apps
  //
  // resolved `react` to host/node_modules/react — the host's own copy — while
  // the apps kept resolving demo-apps/node_modules/react. Two real copies, and
  // therefore "Invalid hook call" on the first `useState` and a crash loop for
  // every app that uses hooks. Measured:
  //
  //     resolveSync("react", "../protocol/demo-apps") → host/node_modules/react
  //     resolveSync("react", "<abs>/protocol/demo-apps") → demo-apps/node_modules/react
  //
  // Normalising here rather than only at the caller because this function's
  // whole contract is "resolve react from this root", and a relative root
  // silently meaning somewhere else is precisely the trap it exists to close.
  const root = resolve(modulesRoot);

  let reactPath: string;
  let reconcilerPath: string;
  let constantsPath: string;
  try {
    reactPath = Bun.resolveSync("react", root);
    reconcilerPath = Bun.resolveSync("react-reconciler", root);
    constantsPath = Bun.resolveSync("react-reconciler/constants", root);
  } catch (error) {
    throw new Error(
      `could not resolve react from '${root}' — the apps root needs react + react-reconciler installed (${String(error)})`,
    );
  }

  const [react, reconciler, constants] = await Promise.all([
    import(reactPath) as Promise<Record<string, unknown>>,
    import(reconcilerPath) as Promise<Record<string, unknown>>,
    import(constantsPath) as Promise<Record<string, unknown>>,
  ]);

  const reactExports = interop<{ createElement: ReactRuntime["createElement"] }>(react);
  return {
    createElement: reactExports.createElement,
    createReconciler: interop<(config: unknown) => unknown>(reconciler),
    defaultEventPriority: (constants.DefaultEventPriority ??
      interop<Record<string, number>>(constants).DefaultEventPriority) as number,
  };
}
