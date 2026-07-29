import { describe, expect, test } from "bun:test";
import { relative, resolve } from "node:path";
import { loadReactRuntime, resolveReactPaths } from "../src/render/runtime";

// The React single-instance rule (src/render/runtime.ts). The app's `react` and
// the reconciler's `react` must be the SAME module instance — two copies is
// "Invalid hook call" on the first useState, and a crash loop for every app that
// uses hooks.
//
// This suite exists because that has now broken twice, both times silently and
// both times only outside the paths the other tests take:
//
//   1. `bun build --compile` embedded React while apps resolved their own.
//   2. A RELATIVE --apps-root resolved against the process cwd instead of the
//      apps root, so `cd host && bun src/host.ts --apps-root ../protocol/demo-apps`
//      loaded host/node_modules/react for the reconciler and
//      demo-apps/node_modules/react for the apps.
//
// Both produced a working host and a broken app, which is the worst shape a bug
// can have here.

const HOST_ROOT = resolve(import.meta.dir, "..");

describe("react runtime resolution", () => {
  test("a relative apps root resolves to the same React as an absolute one", async () => {
    // The exact shape of the reported crash: run from host/, point at a sibling.
    const relativeRoot = relative(process.cwd(), HOST_ROOT) || ".";

    const [fromRelative, fromAbsolute] = await Promise.all([
      loadReactRuntime(relativeRoot),
      loadReactRuntime(HOST_ROOT),
    ]);

    // Identity, not deep equality: hooks live in module-level state, so two
    // structurally-identical copies are exactly the failure.
    expect(fromRelative.createElement).toBe(fromAbsolute.createElement);
    expect(fromRelative.createReconciler).toBe(fromAbsolute.createReconciler);
    expect(fromRelative.defaultEventPriority).toBe(fromAbsolute.defaultEventPriority);
  });

  test("a root with no react says so, naming the root", async () => {
    // A clear error beats a null hooks dispatcher fifty frames later — on a real
    // install this means first-run seeding did not happen.
    expect(loadReactRuntime("/nonexistent/apps/root")).rejects.toThrow(
      /could not resolve react from '\/nonexistent\/apps\/root'/,
    );
  });

  test("the loaded runtime is usable, not merely present", async () => {
    const runtime = await loadReactRuntime(HOST_ROOT);
    expect(typeof runtime.createElement).toBe("function");
    expect(typeof runtime.createReconciler).toBe("function");
    // DefaultEventPriority is a real react-reconciler constant; 0 would mean we
    // picked up an interop wrapper's empty default instead of the module.
    expect(runtime.defaultEventPriority).toBeGreaterThan(0);
  });

  // Resolution moved to the HOST thread (src/render/runtime.ts, ReactPaths):
  // `Bun.resolveSync` on a bare specifier walks node_modules through a
  // PROCESS-GLOBAL filesystem cache, and several worker threads doing that at
  // once segfaults Bun 1.3.9 — symbolized as allocators.BSSMap.getOrPut ←
  // RealFS.readDirectoryWithIterator ← Resolver.loadAsFile ← Bun__resolveSync.
  // Measured: the host suite panicked 4 times in 14 runs before, 0 in 30 after.
  test("pre-resolved paths give the same runtime as resolving in place", async () => {
    const paths = resolveReactPaths(HOST_ROOT);
    const [handed, resolved] = await Promise.all([
      loadReactRuntime(HOST_ROOT, paths),
      loadReactRuntime(HOST_ROOT),
    ]);
    expect(handed.createElement).toBe(resolved.createElement);
    expect(handed.createReconciler).toBe(resolved.createReconciler);
  });

  test("handed paths are USED, not merely accepted", async () => {
    // The point of the change is that a worker given paths does no resolution of
    // its own. A path that cannot possibly resolve proves it: if the loader
    // quietly fell back to resolving `react` itself, this would succeed.
    await expect(
      loadReactRuntime(HOST_ROOT, {
        react: "/nowhere/react/index.js",
        reconciler: "/nowhere/react-reconciler/index.js",
        constants: "/nowhere/constants.js",
      }),
    ).rejects.toThrow();
  });
});