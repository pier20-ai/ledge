import { describe, expect, test } from "bun:test";
import { relative, resolve } from "node:path";
import { loadReactRuntime } from "../src/render/runtime";

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
});
