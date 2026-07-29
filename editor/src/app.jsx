import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { renderMarkdown } from "./markdown.js";

// The builder surface (spec §8): one app, one conversation.
//
// The whole screen is ~440 pt wide and hangs off a notch, so this is not a chat
// app scaled down — it is a transcript of *changes to one app*, and everything
// here follows from that. There is no history sidebar, no model picker, no
// message actions: the app is the subject, the folder is the memory, and the
// only questions are "what did it say", "what did it touch", and "did it work".

// ---------------------------------------------------------------- turn model

/**
 * The event stream folded into turns.
 *
 * Text arrives as deltas, so a turn's reply is an accumulator rather than a
 * list of messages — and a turn is the unit the user actually thinks in ("I
 * asked for X, here is what happened").
 *
 * The local turn is created optimistically on send, with `serverTurn: null`,
 * and **bound** to the first event that names a turn number. Without that
 * binding the user's prompt and the agent's reply land in two different turns:
 * they still render in order, so it looks right, but nothing can group them —
 * which the moment you want to collapse a finished turn, or anchor one, breaks.
 */
function reduceEvent(turns, event) {
  const next = turns.slice();
  let index = next.findIndex((turn) => turn.serverTurn === event.turn);

  if (index < 0) {
    // Bind the newest unbound turn — the one this reply belongs to.
    const pending = next.findIndex((turn) => turn.serverTurn === null);
    if (pending >= 0) {
      index = pending;
      next[index] = { ...next[index], serverTurn: event.turn };
    } else {
      // An event with no local turn: a resumed thread, or a turn started
      // elsewhere. Render it rather than dropping it — a transcript that hides
      // work the agent did is worse than one with an unattributed entry.
      next.push(blankTurn(event.turn));
      index = next.length - 1;
    }
  }

  const turn = { ...next[index], blocks: next[index].blocks.slice() };
  next[index] = turn;

  switch (event.event) {
    case "text":
    case "reasoning": {
      // Deltas merge into the trailing block of the same kind. A new block is
      // started only when something else happened in between — which is what
      // preserves the order the agent actually worked in.
      const kind = event.event;
      const last = turn.blocks[turn.blocks.length - 1];
      if (last && last.kind === kind) {
        turn.blocks[turn.blocks.length - 1] = { ...last, text: last.text + (event.delta || "") };
      } else {
        turn.blocks.push({ kind, text: event.delta || "" });
      }
      break;
    }

    case "tool": {
      // ONE tool marker per turn, always the latest, always at the position it
      // most recently occurred. A turn can run twenty commands; listing them all
      // turns the transcript into a build log and buries the prose explaining
      // what is happening. What a user needs from a tool call is "what is it
      // doing right now", and that is one line.
      //
      // Blocks stay an ORDERED list rather than tools-then-text: a coding agent
      // narrates as it works, and grouping the tools rewrites that into
      // something it never said.
      turn.blocks = turn.blocks.filter((block) => block.kind !== "tool");
      turn.blocks.push({
        kind: "tool",
        name: event.name,
        detail: event.detail,
        state: event.state,
      });
      break;
    }

    case "status":
      // Transient by nature ("rate limited — retrying"): the latest replaces
      // the last, and `done` clears it.
      turn.status = event.text;
      break;

    case "error":
      turn.error = event.message;
      break;

    case "done":
      turn.done = event.status;
      turn.status = null;
      break;

    default:
      // Unknown events are ignored here but NOT dropped by the bridge — a new
      // event type should cost its own rendering, never the turn around it.
      break;
  }
  return next;
}

function blankTurn(serverTurn, prompt = null) {
  return { serverTurn, prompt, blocks: [], status: null, error: null, done: null };
}

const isRunning = (turn) => turn !== undefined && turn.done === null;

// ---------------------------------------------------------------- rendering

/**
 * What a tool call says, as one sentence.
 *
 * "Editing app.jsx", not "EDITING /Users/you/.ledge/apps/stocks/app.jsx". A
 * shouted label beside a full path is two things to parse and neither of them
 * is a phrase; the panel is narrow, this line is glanced at rather than read,
 * and the interesting word is the filename.
 */
function describeTool(tool) {
  const settled = tool.state === "completed";
  if (tool.name === "edit") {
    // Paths are absolute on the wire. Inside one app's folder the directory is
    // the same for every file, so the basename is the only part that varies —
    // and it is the part being asked about.
    const names = tool.detail
      .split(",")
      .map((path) => path.trim().split("/").pop())
      .filter(Boolean);
    const what = names.length > 1 ? `${names.length} files` : names[0] || "a file";
    return `${settled ? "Edited" : "Editing"} ${what}`;
  }
  return `${settled ? "Ran" : "Running"} ${tool.detail}`;
}

/**
 * The current tool call, as a marker: a labelled rule across the transcript
 * rather than a chip in the flow. A marker reads as "this is what is happening",
 * which is its whole job here — one line, replaced in place, never accumulating.
 */
function ToolMarker({ tool }) {
  const settled = tool.state === "completed";
  return (
    <div className={`marker ${settled ? "marker-done" : "marker-live"}`}>
      <span className="marker-text" title={tool.detail}>
        {describeTool(tool)}
      </span>
    </div>
  );
}

/**
 * The agent's thinking.
 *
 * Shown, not hidden. For the first minute of a real turn this is frequently the
 * ONLY output, and a panel showing three animated dots cannot be told apart from
 * a hung one — which is exactly how the first real edit felt. Styled secondary
 * so it never competes with what the agent actually says.
 */
function Reasoning({ text }) {
  return <div className="reasoning">{text}</div>;
}

function Turn({ turn, anchorRef }) {
  const running = isRunning(turn);
  return (
    <article className="turn" ref={anchorRef}>
      {turn.prompt ? <div className="prompt">{turn.prompt}</div> : null}

      {turn.blocks.map((block, index) => {
        if (block.kind === "tool") return <ToolMarker tool={block} key={`t:${index}`} />;
        if (block.kind === "reasoning") return <Reasoning text={block.text} key={`r:${index}`} />;
        return (
          <div className="reply" key={`x:${index}`}>
            {renderMarkdown(block.text)}
          </div>
        );
      })}

      {/* Something is happening but there is nothing to show yet. Without this
          the panel looks frozen for the seconds before the first token. */}
      {running && turn.blocks.length === 0 && !turn.status ? (
        <div className="thinking" aria-label="Working">
          <i /><i /><i />
        </div>
      ) : null}

      {turn.status ? <div className="status shimmer">{turn.status}</div> : null}
      {turn.error ? <div className="error">{turn.error}</div> : null}

      {/* Only outcomes worth interrupting for. A turn that completed says so by
          simply stopping — a green tick on every reply is noise. */}
      {turn.done === "interrupted" ? <div className="outcome">stopped</div> : null}
      {turn.done === "failed" && !turn.error ? (
        <div className="outcome outcome-failed">the turn failed</div>
      ) : null}
    </article>
  );
}

// ---------------------------------------------------------------- the surface

export function App() {
  const [app, setApp] = useState(null);
  const [turns, setTurns] = useState([]);
  const [draft, setDraft] = useState("");
  /** Cancel is requested, but the turn is not over until `done` says so. */
  const [stopping, setStopping] = useState(false);
  /** False once the user scrolls up: streaming must not yank them back. */
  const [following, setFollowing] = useState(true);

  const viewport = useRef(null);
  const newestTurn = useRef(null);
  const composer = useRef(null);
  /** Set when a turn was just submitted, so the next layout anchors it. */
  const anchorPending = useRef(false);

  const running = isRunning(turns[turns.length - 1]);

  useEffect(
    () =>
      window.ledge.onEvent((event) => {
        if (event.event === "thread") {
          // Switching apps is a message, not a reload: one web view serves every
          // app, so the page clears its own transcript.
          setApp(event.app);
          setTurns([]);
          setStopping(false);
          setFollowing(true);
          return;
        }
        setTurns((current) => reduceEvent(current, event));
        if (event.event === "done") setStopping(false);
      }),
    [],
  );

  // Follow the tail only while the user is already at it. A transcript that
  // scrolls itself while you are reading further up is a transcript you cannot
  // read at all.
  useLayoutEffect(() => {
    const node = viewport.current;
    if (!node) return;

    if (anchorPending.current) {
      // The new turn goes to the TOP of the viewport rather than the bottom, so
      // the question stays visible while the answer streams underneath it. On a
      // panel this short, anchoring to the bottom would push the prompt off
      // screen with the first paragraph.
      anchorPending.current = false;
      setFollowing(true);
      newestTurn.current?.scrollIntoView({ block: "start" });
      return;
    }
    if (following) node.scrollTop = node.scrollHeight;
  }, [turns, following]);

  const onScroll = useCallback(() => {
    const node = viewport.current;
    if (!node) return;
    // A couple of pixels of slack: sub-pixel layout means an exact comparison
    // reads as "not at the bottom" on a transcript that plainly is.
    const atBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 24;
    setFollowing(atBottom);
  }, []);

  const submit = useCallback(() => {
    const text = draft.trim();
    if (text === "" || running || !app) return;
    window.ledge.send(text);
    setDraft("");
    anchorPending.current = true;
    setTurns((current) => current.concat([blankTurn(null, text)]));
  }, [draft, running]);

  const stop = useCallback(() => {
    // Optimistic only as far as the button: the turn is not over until `done`
    // arrives, and pretending otherwise would let the user type into a turn
    // that is still running.
    window.ledge.cancel();
    setStopping(true);
  }, []);

  const onKeyDown = useCallback(
    (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        submit();
        return;
      }
      // The one gesture that has to work without reaching for the mouse.
      if (event.key === "Escape" && running) {
        event.preventDefault();
        stop();
      }
    },
    [running, stop, submit],
  );

  // Grow with the text, up to a few lines. A fixed single line hides what you
  // are about to send; an unbounded one eats the transcript.
  useLayoutEffect(() => {
    const node = composer.current;
    if (!node) return;
    node.style.height = "auto";
    node.style.height = `${Math.min(node.scrollHeight, 96)}px`;
  }, [draft]);

  return (
    <div className="editor">
      <div className="transcript" ref={viewport} onScroll={onScroll} role="log" aria-busy={running}>
        {turns.length === 0 ? (
          <div className="empty">
            {app ? (
              <>
                <p>Ask for a change to <b>{app}</b>.</p>
                <p className="hint">It edits the app's folder and reloads it.</p>
              </>
            ) : (
              <>
                {/* The [+] surface presents this editor with no app behind it.
                    Creating an app from a prompt (spec §8: the host scaffolds
                    first, then starts the session) is not wired up yet, and a
                    composer that accepts text nothing will ever answer is worse
                    than one that says so. */}
                <p>No app selected.</p>
                <p className="hint">
                  Creating an app from here isn't wired up yet — run{" "}
                  <code>ledge new &lt;name&gt;</code>, then edit it from its own panel.
                </p>
              </>
            )}
          </div>
        ) : (
          turns.map((turn, index) => (
            <Turn
              turn={turn}
              key={turn.serverTurn ?? `local:${index}`}
              anchorRef={index === turns.length - 1 ? newestTurn : undefined}
            />
          ))
        )}
      </div>

      {!following && running ? (
        <button type="button" className="jump" onClick={() => setFollowing(true)}>
          Jump to latest
        </button>
      ) : null}

      <div className="composer">
        <textarea
          ref={composer}
          value={draft}
          rows={1}
          placeholder={app ? (running ? "Working…" : "Ask for a change…") : "No app selected"}
          disabled={!app}
          spellCheck={false}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={onKeyDown}
          autoFocus
        />
        {running ? (
          <button
            type="button"
            className="stop"
            onClick={stop}
            disabled={stopping}
            title="Stop this turn (Esc)"
          >
            {stopping ? "Stopping…" : "Stop"}
          </button>
        ) : (
          <button
            type="button"
            className="send"
            onClick={submit}
            disabled={draft.trim() === "" || !app}
            title="Send (Return)"
          >
            Send
          </button>
        )}
      </div>
    </div>
  );
}
