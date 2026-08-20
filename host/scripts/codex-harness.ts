// A standalone driver for `codex app-server` — the bench the builder was built
// on (spec §8).
//
// The client and the event mapping now live in `src/codex/`, where the host
// uses them; this file is the CLI that drives them by hand. It imports rather
// than duplicates ON PURPOSE: a harness that has drifted from the code it was
// meant to de-risk is worse than no harness, because you still trust it.
//
//   bun scripts/codex-harness.ts <appDir> "<prompt>" [--resume <threadId>] [--raw]
//
// NOTE: this spends the user's own Codex quota. Nothing in `bun test` runs it.

import { resolve } from "node:path";
import { CodexClient } from "../src/codex/client";
import { toBuilderEvent, type TurnStatus } from "../src/codex/events";

// ---------------------------------------------------------------- the CLI

async function main(): Promise<number> {
  const argv = Bun.argv.slice(2);
  const raw = argv.includes("--raw");
  const resumeAt = argv.indexOf("--resume");
  const resumeId = resumeAt >= 0 ? argv[resumeAt + 1] : undefined;
  const positional = argv.filter(
    (arg, index) => !arg.startsWith("--") && argv[index - 1] !== "--resume",
  );
  const [appDir, prompt] = positional;

  if (!appDir || !prompt) {
    console.error(
      'usage: bun scripts/codex-harness.ts <appDir> "<prompt>" [--resume <threadId>] [--raw]',
    );
    return 1;
  }

  const cwd = resolve(appDir);
  const client = new CodexClient({ log: (line) => console.error(line) });
  let finished = false;

  client.onRequest = (method, params) => {
    // With approvalPolicy "never" these should not arrive. If one does, say so
    // loudly and approve — a silently unanswered request wedges the turn, and
    // guessing quietly would hide a wrong trust model.
    console.error(`[harness] server request: ${method} ${JSON.stringify(params).slice(0, 200)}`);
    return { decision: "approved" };
  };

  let outcome: TurnStatus = "completed";
  client.onNotification = (method, params) => {
    if (raw) console.error(`[raw] ${method} ${JSON.stringify(params).slice(0, 300)}`);
    const event = toBuilderEvent(method, params);
    if (!event) return;
    if (event.event === "text") process.stdout.write(event.delta);
    else console.log(`\n[${event.event}] ${JSON.stringify(event)}`);
    if (event.event === "done") {
      outcome = event.status;
      finished = true;
    }
  };

  const info = await client.initialize();
  console.error(`[harness] connected: ${String(info.userAgent ?? "?")}`);

  const threadId = resumeId
    ? await client.resumeThread(resumeId, cwd)
    : await client.startThread(cwd);
  console.error(`[harness] thread ${threadId} in ${cwd}`);
  console.error(`[harness] resume with: --resume ${threadId}\n`);

  // Interrupt, then WAIT for the turn to actually end. Exiting straight away
  // would leave the outcome unobserved — and the outcome is the point: an
  // interrupted turn still arrives as `turn/completed`, with status
  // "interrupted". The Stop button in the editor needs exactly this, so the
  // harness has to prove it rather than assume it.
  process.on("SIGINT", () => {
    console.error("\n[harness] interrupting…");
    void client.interrupt(threadId);
    setTimeout(() => {
      if (!finished) {
        console.error("[harness] no turn/completed after interrupt");
        process.exit(130);
      }
    }, 10_000);
  });

  await client.startTurn(threadId, prompt);

  // turn/start returns when the turn is accepted, not when it ends; the stream
  // is what says it is over.
  const deadline = Date.now() + 10 * 60_000;
  while (!finished && Date.now() < deadline) await Bun.sleep(50);
  console.log();
  if (!finished) console.error("[harness] timed out waiting for turn/completed");
  else console.error(`[harness] turn ${outcome}`);
  client.kill();
  // Nonzero for a turn that did not succeed, so this composes in a shell.
  return finished && outcome === "completed" ? 0 : 1;
}

if (import.meta.main) process.exit(await main());
