import { describe, expect, test } from "bun:test";
import { toBuilderEvent } from "../scripts/codex-harness";

// Codex app-server notification → spec §3.6 `builder` event.
//
// Every payload below was **captured from a real turn** (a file edit in a temp
// folder), not written from the docs. That matters: the first version of this
// mapping read `item.path` for a file change, which type-checks, looks right,
// and produces a tool chip with no filename on it — the real item carries
// `changes: [{ path, kind }]`.
//
// Nothing here spawns Codex. The harness (scripts/codex-harness.ts) is the
// thing that talks to a real one, by hand, and spends real quota.

describe("Codex notification → builder event", () => {
  test("agent message deltas become streamed text", () => {
    expect(
      toBuilderEvent("item/agentMessage/delta", {
        threadId: "019fa9a2",
        turnId: "019fa9a2",
        itemId: "msg_00a4",
        delta: "hello from ",
      }),
    ).toEqual({ event: "text", delta: "hello from " });
  });

  test("a shell command becomes a tool event carrying the command", () => {
    const item = {
      type: "commandExecution",
      id: "exec-694a1140",
      command: "/bin/zsh -lc \"sed -n '1,120p' app.jsx\"",
    };
    expect(toBuilderEvent("item/started", { item })).toEqual({
      event: "tool",
      name: "run",
      detail: "/bin/zsh -lc \"sed -n '1,120p' app.jsx\"",
      state: "started",
    });
    expect(toBuilderEvent("item/completed", { item })).toMatchObject({ state: "completed" });
  });

  test("a file change reports the paths it touched", () => {
    // The real shape. `item.path` does not exist.
    const item = {
      type: "fileChange",
      id: "call_5XwFtrqb",
      changes: [{ path: "/tmp/app/app.jsx", kind: { type: "update" } }],
    };
    expect(toBuilderEvent("item/started", { item })).toEqual({
      event: "tool",
      name: "edit",
      detail: "/tmp/app/app.jsx",
      state: "started",
    });
  });

  test("the turn ending is the only 'done'", () => {
    expect(toBuilderEvent("turn/completed", { threadId: "x", turn: {} })).toEqual({ event: "done" });
    // turn/started is bookkeeping — the shell already knows it asked.
    expect(toBuilderEvent("turn/started", { threadId: "x", turn: {} })).toBeNull();
  });

  test("the noisy majority is ignored", () => {
    // Everything Codex emits around a step. A builder that forwarded these
    // would be a debug log wearing a chat's clothes.
    const ignored: Array<[string, Record<string, unknown>]> = [
      ["item/started", { item: { type: "reasoning", id: "rs_00a4" } }],
      ["item/completed", { item: { type: "reasoning", id: "rs_00a4" } }],
      ["item/started", { item: { type: "userMessage", id: "u1" } }],
      ["turn/diff/updated", { threadId: "x", diff: "diff --git a/app.jsx" }],
      ["thread/tokenUsage/updated", { threadId: "x" }],
      ["item/reasoning/summaryTextDelta", { delta: "thinking" }],
    ];
    for (const [method, params] of ignored) {
      expect(toBuilderEvent(method, params)).toBeNull();
    }
  });

  test("an unknown notification is ignored, not crashed on", () => {
    // app-server is experimental and its surface is ~510 types; new ones will
    // appear before we know about them.
    expect(toBuilderEvent("thread/goal/updated", {})).toBeNull();
    expect(toBuilderEvent("item/started", {})).toBeNull();
  });
});
