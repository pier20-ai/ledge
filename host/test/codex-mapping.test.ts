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

  // A turn that FAILED still arrives as turn/completed — TurnStatus is
  // "completed" | "interrupted" | "failed" | "inProgress". Emitting a bare
  // `done` for all of them renders a failed build as a success, which is the
  // worst possible lie for a surface whose job is telling you whether your app
  // changed.
  test("done carries how the turn ended, not just that it ended", () => {
    expect(toBuilderEvent("turn/completed", { turn: { status: "completed" } }))
      .toEqual({ event: "done", status: "completed" });
    expect(toBuilderEvent("turn/completed", { turn: { status: "failed" } }))
      .toEqual({ event: "done", status: "failed" });
    expect(toBuilderEvent("turn/completed", { turn: { status: "interrupted" } }))
      .toEqual({ event: "done", status: "interrupted" });
    // An absent or unexpected status must not read as a failure.
    expect(toBuilderEvent("turn/completed", { turn: {} }))
      .toEqual({ event: "done", status: "completed" });

    // turn/started is bookkeeping — the shell already knows it asked.
    expect(toBuilderEvent("turn/started", { threadId: "x", turn: {} })).toBeNull();
  });

  // The real shape is `{ error: TurnError, willRetry, threadId, turnId }`.
  // Reading `params.message` type-checks and yields "unknown error" for every
  // real failure — including the one that matters most, not being logged in.
  test("an error reports what actually went wrong", () => {
    expect(
      toBuilderEvent("error", {
        error: { message: "stream disconnected before completion", additionalDetails: null },
        willRetry: false,
        threadId: "x",
        turnId: "y",
      }),
    ).toEqual({ event: "error", message: "stream disconnected before completion" });

    // additionalDetails is where the useful half usually is.
    expect(
      toBuilderEvent("error", {
        error: { message: "request failed", additionalDetails: "401 Unauthorized" },
        willRetry: false,
      }),
    ).toEqual({ event: "error", message: "request failed\n401 Unauthorized" });
  });

  test("a retryable error is weather, not an outcome", () => {
    // Codex retries on its own; a red banner for something that resolves itself
    // a second later trains the user to ignore the banner.
    expect(
      toBuilderEvent("error", {
        error: { message: "rate limited" },
        willRetry: true,
      }),
    ).toEqual({ event: "status", text: "rate limited — retrying" });
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

  // A real turn produced a commandExecution whose command was a shell heredoc
  // containing a 500-word essay. The detail is for display, it crosses a socket
  // to get there, and it lands on a chip one line tall.
  test("a huge tool detail is truncated to one readable line", () => {
    const command = `/bin/zsh -lc "wc -w <<'EOF'\n${"word ".repeat(2000)}\nEOF"`;
    const event = toBuilderEvent("item/started", {
      item: { type: "commandExecution", id: "exec-1", command },
    });
    const detail = (event as { detail: string }).detail;
    expect(detail.length).toBeLessThanOrEqual(200);
    expect(detail.endsWith("…")).toBe(true);
    // Newlines collapse: a chip is one line, not a transcript.
    expect(detail).not.toContain("\n");
  });

  test("an unknown notification is ignored, not crashed on", () => {
    // app-server is experimental and its surface is ~510 types; new ones will
    // appear before we know about them.
    expect(toBuilderEvent("thread/goal/updated", {})).toBeNull();
    expect(toBuilderEvent("item/started", {})).toBeNull();
  });
});
