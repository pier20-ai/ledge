// Codex app-server notifications → spec §3.6 `builder` events.
//
// This is the whole "adapter per agent" the spec asks for: the shell never sees
// Codex's wire format, and swapping agents means writing another one of these.
//
// Every shape below was measured against a real conversation (see
// scripts/codex-harness.ts), not read off the docs page — four of them are not
// what the documentation implies, and each of those was a silent bug:
//
//   * a FAILED turn still arrives as `turn/completed`
//   * `error` params are `{ error: { message } }`, not `{ message }`
//   * a `fileChange` item carries `changes: [{ path }]`, not `path`
//   * tool details can be kilobytes

export type Json = Record<string, unknown>;

/** Codex's own turn outcomes. A turn that failed still *completes*. */
export type TurnStatus = "completed" | "interrupted" | "failed";

/** The spec §3.6 builder event stream, as the shell receives it. */
export type BuilderEvent =
  /** The host scaffolded an app for a turn that named none (spec §4.3: "`app`
   * may name a not-yet-existing id when coming from the [+] surface"). It
   * carries no fields — the envelope's `app` IS the answer, and the shell moves
   * its editor onto it. Not a Codex event: the only builder event the host
   * originates itself. */
  | { event: "created" }
  | { event: "text"; delta: string }
  /** The agent's own thinking, streamed. Secondary to `text`, but the only
   * thing on screen during the long opening stretch of a turn. */
  | { event: "reasoning"; delta: string }
  | { event: "tool"; name: string; detail: string; state: "started" | "completed" }
  | { event: "status"; text: string }
  /** The turn ended — `status` says how. Not always a success. */
  | { event: "done"; status: TurnStatus }
  | { event: "error"; message: string };

/**
 * Longest tool detail worth sending.
 *
 * Not a guess: a real turn produced a `commandExecution` whose command was a
 * shell heredoc containing a 500-word essay — several kilobytes, bound for a
 * chip one line tall, across a socket. Nobody reads past the first eighty
 * characters of a command.
 */
const MAX_DETAIL = 200;

function truncate(text: string): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  return oneLine.length > MAX_DETAIL ? `${oneLine.slice(0, MAX_DETAIL - 1)}…` : oneLine;
}

/**
 * Map one Codex notification to a builder event, or null to ignore it.
 *
 * The ignore list is the point. Codex emits reasoning traces, token counts,
 * plan updates and thread bookkeeping continuously; a builder that forwarded
 * all of it would be a debug log wearing a chat's clothes. Ledge shows what the
 * agent *said* and what it *did*.
 */
export function toBuilderEvent(method: string, params: Json): BuilderEvent | null {
  switch (method) {
    case "item/agentMessage/delta":
      return { event: "text", delta: String(params.delta ?? "") };

    // Reasoning was originally dropped as noise. That was wrong, and it showed
    // up as the worst possible failure: a real turn spent 60 s emitting nothing
    // but reasoning, so the panel showed three animated dots and the user could
    // not tell a working build from a hung one. Reasoning is frequently the ONLY
    // thing a turn produces for its first minute — it is not noise, it is the
    // evidence that anything is happening at all.
    case "item/reasoning/summaryTextDelta":
    case "item/reasoning/textDelta":
      return { event: "reasoning", delta: String(params.delta ?? "") };

    case "item/started":
    case "item/completed": {
      const item = params.item as
        | { type?: string; command?: string; changes?: Array<{ path?: string }> }
        | undefined;
      if (!item) return null;
      const state = method === "item/started" ? "started" : "completed";
      if (item.type === "commandExecution") {
        return { event: "tool", name: "run", detail: truncate(String(item.command ?? "")), state };
      }
      if (item.type === "fileChange") {
        // `changes: [{ path, kind }]`, NOT `path` — measured against a real
        // turn, where assuming `item.path` produced a tool chip with no file
        // name on it and nothing to say it was wrong.
        const paths = (item.changes ?? []).map((change) => change.path).filter(Boolean);
        return { event: "tool", name: "edit", detail: truncate(paths.join(", ")), state };
      }
      // Ignored on purpose: `userMessage` (we sent it), and `reasoning`, which
      // Codex emits around every step.
      return null;
    }

    case "turn/completed": {
      // A turn that FAILED still arrives here — `TurnStatus` is
      // "completed" | "interrupted" | "failed" | "inProgress". Emitting a bare
      // `done` for all of them would render a failed build as a success, which
      // is the worst possible lie for a surface whose whole job is telling you
      // whether your app changed.
      const turn = params.turn as { status?: string } | undefined;
      const status = turn?.status;
      return {
        event: "done",
        status: status === "failed" || status === "interrupted" ? status : "completed",
      };
    }

    case "error": {
      // `{ error: TurnError, willRetry, threadId, turnId }` — NOT `{ message }`.
      // Reading params.message gave "unknown error" for every real failure,
      // including the one that matters most: not being logged in.
      const error = params.error as { message?: string; additionalDetails?: string } | undefined;
      const message = error?.message ?? "unknown error";
      // A retryable error is not an outcome, it is weather. Showing it as an
      // error would put a red banner in front of the user for something that
      // resolves itself a second later.
      if (params.willRetry === true) {
        return { event: "status", text: `${message} — retrying` };
      }
      return {
        event: "error",
        message: error?.additionalDetails ? `${message}\n${error.additionalDetails}` : message,
      };
    }

    default:
      return null;
  }
}
