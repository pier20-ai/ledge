import React, { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { renderMarkdown } from "./markdown.js";

// Chat mode — the transcript (principle 11: the agent conversation is the
// foundational interface, designed first and held to the highest standard).
//
// This page is one layer of a three-layer surface. Behind it, Swift mounts the
// session's live app tree at reduced prominence and arrests every event that
// would reach it; around it, Swift paints the panel body as glass that runs
// opaque at the top to nearly clear at the bottom. What is here is the
// conversation itself: bubbles floating over that glass, and the pill sitting
// on the clearest part of it.
//
// The laws it is written to (design.html §08, flow.md "Visit modes"):
//
//   · violet is you, cyan is the agent, and neither hue appears anywhere else
//   · at rest only the last exchange lingers; scroll reaches everything
//   · tool activity is an EPHEMERAL shimmer — no status rows, no expansion,
//     no build log, nothing that accumulates
//   · no timestamps except across a real gap
//   · iMessage, never a terminal
//   · word budget everywhere

const GAP = 30 * 60 * 1000; // the silence that earns a timestamp

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
 * they still render in order, so it looks right, but nothing can group them.
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
    case "text": {
      // Deltas merge into the trailing block. A new block — a new bubble — is
      // started only when something else happened in between, which is what
      // preserves the order the agent actually worked in: a coding agent
      // narrates as it works, and one bubble per stretch of narration is
      // exactly how that reads in a conversation.
      const last = turn.blocks[turn.blocks.length - 1];
      if (last) {
        turn.blocks[turn.blocks.length - 1] = last + (event.delta || "");
      } else {
        turn.blocks.push(event.delta || "");
      }
      // The agent started speaking, so whatever it was doing is over as far as
      // this surface is concerned. The shimmer is the *only* place work is
      // reported and it never survives the words that follow it.
      turn.activity = null;
      break;
    }

    case "reasoning":
      // Thinking is activity, not speech. It goes in the shimmer rather than a
      // bubble: for the first minute of a real turn it is frequently the only
      // output, and a pane with nothing moving in it cannot be told from a hung
      // one — but it is not something the agent *said*, so it never persists.
      turn.reasoning = (turn.reasoning || "") + (event.delta || "");
      turn.activity = { kind: "reasoning" };
      break;

    case "tool":
      // ONE line, always the latest. A turn can run twenty commands; listing
      // them turns the transcript into a build log and buries the prose that
      // explains what is happening.
      turn.activity = { kind: "tool", text: describeTool(event) };
      break;

    case "status":
      // Transient by nature ("rate limited — retrying").
      turn.activity = { kind: "status", text: event.text };
      break;

    case "error":
      turn.error = event.message;
      break;

    case "done":
      turn.done = event.status;
      turn.activity = null;
      break;

    default:
      // Unknown events are ignored here but NOT dropped by the bridge — a new
      // event type should cost its own rendering, never the turn around it.
      break;
  }
  return next;
}

function blankTurn(serverTurn, prompt = null) {
  return {
    serverTurn,
    prompt,
    at: Date.now(),
    blocks: [],
    reasoning: "",
    activity: null,
    error: null,
    done: null,
  };
}

const isRunning = (turn) => turn !== undefined && turn.done === null;

/**
 * What a tool call says, as one phrase.
 *
 * "Editing timer.jsx", not "EDITING /Users/you/.ledge/apps/timer/timer.jsx". A
 * shouted label beside a full path is two things to parse and neither of them
 * is a phrase; this line is glanced at rather than read, and the interesting
 * word is the filename.
 */
function describeTool(event) {
  const settled = event.state === "completed";
  const detail = event.detail || "";
  if (event.name === "edit") {
    // Paths are absolute on the wire. Inside one app's folder the directory is
    // the same for every file, so the basename is the only part that varies.
    const names = detail
      .split(",")
      .map((path) => path.trim().split("/").pop())
      .filter(Boolean);
    const what = names.length > 1 ? `${names.length} files` : names[0] || "a file";
    return `${settled ? "edited" : "editing"} ${what}…`;
  }
  return `${settled ? "ran" : "running"} ${detail}…`;
}

/** The shimmer's one line, or null when there is nothing happening. */
function activityLine(turn) {
  const activity = turn.activity;
  if (!activity) return null;
  if (activity.kind === "reasoning") {
    const lines = String(turn.reasoning || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    return lines[lines.length - 1] || "thinking…";
  }
  return activity.text || "working…";
}

/** `14:32`, and only across a gap — the only clock face in the product. */
function clock(at) {
  return new Date(at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

// ----------------------------------------------------------------- the glyphs
// design.html's own paths, copied whole. A glyph before a word, always.

const Attach = () => (
  <svg viewBox="0 0 14 14" width="13" height="13" aria-hidden="true">
    <path d="M7 2.2v9.6M2.2 7h9.6" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
  </svg>
);

const Chevron = ({ up }) => (
  <svg viewBox="0 0 14 14" width="13" height="13" aria-hidden="true">
    <path
      d={up ? "M3.2 8.6 7 4.8l3.8 3.8" : "M3.2 5.4 7 9.2l3.8-3.8"}
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

const Send = () => (
  <svg viewBox="0 0 14 14" width="11" height="11" aria-hidden="true">
    <path
      d="M7 11V3M3.4 6.2 7 2.6l3.6 3.6"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

const Stop = () => (
  <svg viewBox="0 0 14 14" width="11" height="11" aria-hidden="true">
    <rect x="4.2" y="4.2" width="5.6" height="5.6" rx="1.4" fill="currentColor" />
  </svg>
);

const Slate = () => (
  <svg viewBox="0 0 22 22" width="26" height="26" aria-hidden="true">
    <rect x="3" y="3" width="16" height="16" rx="5" fill="none" stroke="currentColor" strokeWidth="1.5" />
    <path d="M3 12.5h16" stroke="currentColor" strokeWidth="1.5" />
    <path
      d="M3 12.5v3.5a5 5 0 0 0 5 5h6a5 5 0 0 0 5-5v-3.5"
      fill="currentColor"
      opacity=".18"
      stroke="none"
    />
  </svg>
);

// ---------------------------------------------------------------- the surface

export function App() {
  const [app, setApp] = useState(null);
  /** null until the host says; `{ installed, name, install }` after. */
  const [agent, setAgent] = useState(null);
  const [turns, setTurns] = useState([]);
  const [draft, setDraft] = useState("");
  /** Cancel is requested, but the turn is not over until `done` says so. */
  const [stopping, setStopping] = useState(false);
  /** ⌄ — the pane is cleared to watch the stage. The pill stays. */
  const [collapsed, setCollapsed] = useState(false);
  /** False once the user scrolls up: streaming must not yank them back. */
  const [following, setFollowing] = useState(true);
  /** Whether there is a stage behind this pane, and how much room it takes. */
  const [stage, setStage] = useState({ present: false, inset: 0 });
  /** The draft outgrew one line: 20 pt corners, controls at the bottom. */
  const [grown, setGrown] = useState(false);

  const viewport = useRef(null);
  const composer = useRef(null);
  const bottom = useRef(null);

  const running = isRunning(turns[turns.length - 1]);
  const blocked = agent !== null && !agent.installed;

  useEffect(
    () =>
      window.ledge.onEvent((event) => {
        if (event.event === "agent") {
          // Not part of any turn: the condition every turn depends on. It
          // arrives once per session, before anything is typed, and it survives
          // switching apps — the agent is missing for all of them or none.
          setAgent({
            installed: event.installed !== false,
            name: event.name || "the agent",
            install: event.install || "",
          });
          return;
        }
        if (event.event === "stage") {
          // Swift owns the stage's geometry; the transcript only needs to know
          // how much of the pane to leave for it.
          setStage({ present: Boolean(event.present), inset: Number(event.inset) || 0 });
          return;
        }
        if (event.event === "created") {
          // The blank slot just became an app's chat. Adopt the id WITHOUT
          // clearing anything: the transcript already holds the prompt that
          // caused this app to exist, and the reply to it is streaming in.
          setApp(event.app);
          return;
        }
        if (event.event === "thread") {
          // Switching apps is a message, not a reload: one web view serves every
          // session, so the page clears its own transcript.
          setApp(event.app);
          setTurns([]);
          setStopping(false);
          setFollowing(true);
          setCollapsed(false);
          return;
        }
        setTurns((current) => reduceEvent(current, event));
        if (event.event === "done") setStopping(false);
      }),
    [],
  );

  // Follow the tail only while the user is already at it. A transcript that
  // scrolls itself while you are reading further up is one you cannot read.
  useLayoutEffect(() => {
    const node = viewport.current;
    if (!node || !following) return;
    node.scrollTop = node.scrollHeight;
  }, [turns, following, collapsed, stage.inset]);

  const onScroll = useCallback(() => {
    const node = viewport.current;
    if (!node) return;
    // A couple of pixels of slack: sub-pixel layout means an exact comparison
    // reads as "not at the bottom" on a transcript that plainly is.
    const atBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 24;
    setFollowing((was) => {
      // Scrolled into the past, the stage behind recedes further (design.html
      // §08). Swift does the dimming; this is the only thing that knows.
      if (was !== atBottom) window.ledge.scrollback(!atBottom);
      return atBottom;
    });
  }, []);

  const jump = useCallback(() => {
    setFollowing(true);
    window.ledge.scrollback(false);
    const node = viewport.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, []);

  const restore = useCallback(() => {
    setCollapsed((was) => {
      if (was) window.ledge.transcript(false);
      return false;
    });
  }, []);

  const submit = useCallback(() => {
    const text = draft.trim();
    // `app === ""` is the blank slot, and it is a legitimate target: the host
    // scaffolds an app for a turn that names none (spec §8). Only `null` — no
    // session has been focused at all — has nobody to talk to.
    if (text === "" || running || app === null || blocked) return;
    window.ledge.send(text);
    setDraft("");
    setGrown(false);
    setFollowing(true);
    // Send restores the pane: you cannot ask for something and then be shown
    // nothing (design.html §08, the pill's third state).
    restore();
    setTurns((current) => current.concat([blankTurn(null, text)]));
  }, [draft, running, app, blocked, restore]);

  const stop = useCallback(() => {
    // Optimistic only as far as the bead: the turn is not over until `done`
    // arrives, and pretending otherwise would let the user type into a turn
    // that is still running.
    window.ledge.cancel();
    setStopping(true);
  }, []);

  const toggle = useCallback(() => {
    setCollapsed((was) => {
      window.ledge.transcript(!was);
      return !was;
    });
    composer.current?.focus();
  }, []);

  /** Esc: interrupt a running turn, otherwise it belongs to the shell. */
  const escape = useCallback(() => {
    if (running && !stopping) {
      stop();
      return;
    }
    window.ledge.escape();
  }, [running, stopping, stop]);

  const onKeyDown = useCallback(
    (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        submit();
        return;
      }
      if (event.key === "Escape") {
        event.preventDefault();
        escape();
      }
    },
    [escape, submit],
  );

  // Esc has to work wherever the focus drifted to — a bead, the pane, a
  // selection inside a bubble. The pill is where the keyboard lives in chat
  // mode, but "lives" is not "is trapped".
  useEffect(() => {
    const onKey = (event) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      escape();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [escape]);

  // Grow with the text, up to three lines (design.html §08). A fixed single
  // line hides what you are about to send; an unbounded one eats the pane.
  useLayoutEffect(() => {
    const node = composer.current;
    if (!node) return;
    node.style.height = "auto";
    const height = Math.min(node.scrollHeight, 54);
    node.style.height = `${height}px`;
    setGrown(height > 18);
  }, [draft]);

  // Keyboard focus lives in the pill, always, in chat mode. Clicking the pane
  // puts it back there — unless the click was selecting words out of a bubble.
  const reclaimFocus = useCallback((event) => {
    if (event.target.closest("button")) return;
    const selection = window.getSelection();
    if (selection && !selection.isCollapsed) return;
    composer.current?.focus();
  }, []);

  const showEmpty = turns.length === 0 && !blocked;
  const placeholder = blocked
    ? `install ${agent.name} first`
    : collapsed
      ? "watching, not touching…"
      : "ask anything…";

  return (
    <div
      className={`pane${collapsed ? " collapsed" : ""}`}
      style={{ "--stage-inset": `${stage.inset}px` }}
      onMouseUp={reclaimFocus}
    >
      <div className="stagegap" />

      {blocked ? (
        // Ledge builds apps with the user's own agent and never talks to a
        // model itself, so this is a condition of the surface rather than a
        // failed turn. One line, and the one command that fixes it.
        <div className="banner" role="status">
          <b>{agent.name} isn't installed.</b> Ledge builds with your agent.
          {agent.install ? <code>{agent.install}</code> : null}
        </div>
      ) : null}

      <div className="scroll" ref={viewport} onScroll={onScroll} role="log" aria-busy={running}>
        <div className="bubbles">
          {showEmpty ? (
            <div className="empty">
              <Slate />
              <div className="eline">
                {app ? `Ask for a change to ${app}.` : "Ask for an app, an answer, a monitor."}
              </div>
            </div>
          ) : null}

          {turns.map((turn, index) => {
            const previous = turns[index - 1];
            const gapped = previous && turn.at - previous.at > GAP;
            const last = index === turns.length - 1;
            const line = last ? activityLine(turn) : null;
            return (
              <article className="turn" key={turn.serverTurn ?? `local:${index}`}>
                {gapped ? <div className="gap">{clock(turn.at)}</div> : null}
                {turn.prompt ? <div className="bubble you">{turn.prompt}</div> : null}
                {turn.blocks.map((text, block) =>
                  text.trim() === "" ? null : (
                    <div className="bubble agent" key={`b${block}`}>
                      {renderMarkdown(text)}
                    </div>
                  ),
                )}
                {turn.error ? <div className="bubble agent trouble">{turn.error}</div> : null}
                {line ? <div className="shimmer">{line}</div> : null}
                {last && isRunning(turn) && !line ? (
                  <div className="shimmer">{stopping ? "stopping…" : "thinking…"}</div>
                ) : null}
                {turn.done === "interrupted" ? <div className="gap">stopped</div> : null}
              </article>
            );
          })}
          <div ref={bottom} />
        </div>
      </div>

      {!following && !collapsed ? (
        <button type="button" className="jump" onClick={jump} title="Jump to latest">
          <Chevron />
        </button>
      ) : null}

      <div className={`pill${grown ? " grown" : ""}`}>
        {/* ⊕ — attach. Intake is deferred by decision (flow.md, Edges: "Drop /
            intake — deferred … designed last"), so this is the shape of the
            control and not yet its behaviour. It is in the pill because the
            pill's anatomy is settled; what it opens is not. */}
        <button type="button" className="icosm" title="Attach" disabled>
          <Attach />
        </button>

        <textarea
          ref={composer}
          value={draft}
          rows={1}
          placeholder={placeholder}
          disabled={app === null || blocked}
          spellCheck={false}
          onChange={(event) => {
            setDraft(event.target.value);
            // Typing restores the pane — you are talking, so the words come back.
            restore();
          }}
          onKeyDown={onKeyDown}
          autoFocus
        />

        {running ? (
          <button
            type="button"
            className="bead"
            onClick={stop}
            disabled={stopping}
            title="Stop this turn (Esc)"
          >
            <Stop />
          </button>
        ) : draft.trim() !== "" ? (
          <button type="button" className="bead" onClick={submit} title="Send (Return)">
            <Send />
          </button>
        ) : stage.present ? (
          <button
            type="button"
            className="toggle"
            onClick={toggle}
            title={collapsed ? "Reopen transcript" : "Collapse transcript"}
          >
            <Chevron up={collapsed} />
          </button>
        ) : null}
      </div>
    </div>
  );
}
