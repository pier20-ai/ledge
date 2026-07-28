import React, { useCallback, useEffect, useRef, useState } from "react";
import { renderMarkdown } from "./markdown.js";

// PLACEHOLDER UI. The deliverable behind this file is the bridge and the build
// pipeline; the styling is meant to be replaced wholesale. What is worth
// keeping is the reduction below — the event stream folded into a list of
// turns — because that is the shape the protocol actually delivers.

/// One `builder` stream folded into renderable turns. Text arrives as deltas,
/// so a turn's assistant message is an accumulator, not a message list.
function reduce(turns, event) {
  const next = turns.slice();
  let turn = next[next.length - 1];
  if (!turn || turn.turn !== event.turn) {
    turn = { turn: event.turn, text: "", tools: [], status: null, done: null, error: null };
    next.push(turn);
  } else {
    turn = { ...turn, tools: turn.tools.slice() };
    next[next.length - 1] = turn;
  }

  switch (event.event) {
    case "text":
      turn.text += event.delta || "";
      break;
    case "tool": {
      // A `started` tool is replaced in place by its `completed` twin rather
      // than appended, so a long edit is one chip that settles instead of two.
      const index = turn.tools.findIndex(
        (tool) => tool.name === event.name && tool.state === "started",
      );
      const chip = { name: event.name, detail: event.detail, state: event.state };
      if (index >= 0) turn.tools[index] = chip;
      else turn.tools.push(chip);
      break;
    }
    case "status":
      turn.status = event.text;
      break;
    case "done":
      turn.done = event.status;
      break;
    case "error":
      turn.error = event.message;
      break;
    default:
      break;
  }
  return next;
}

function Turn({ turn }) {
  return (
    <div className="turn">
      {turn.prompt ? <div className="prompt">{turn.prompt}</div> : null}
      {turn.tools.map((tool, index) => (
        <div className={`tool ${tool.state}`} key={`${tool.name}${index}`}>
          <span className="tool-name">{tool.name}</span>
          <span className="tool-detail">{tool.detail}</span>
        </div>
      ))}
      {turn.text ? <div className="text">{renderMarkdown(turn.text)}</div> : null}
      {turn.status ? <div className="status">{turn.status}</div> : null}
      {turn.error ? <div className="error">{turn.error}</div> : null}
      {turn.done && turn.done !== "completed" ? (
        <div className={`done ${turn.done}`}>{turn.done}</div>
      ) : null}
    </div>
  );
}

export function App() {
  const [app, setApp] = useState(null);
  const [turns, setTurns] = useState([]);
  const [running, setRunning] = useState(false);
  const [draft, setDraft] = useState("");
  const scroller = useRef(null);

  useEffect(
    () =>
      window.ledge.onEvent((event) => {
        if (event.event === "thread") {
          // Switching apps is a message, not a reload: one web view serves
          // every app, so the page clears its own transcript.
          setApp(event.app);
          setTurns([]);
          setRunning(false);
          return;
        }
        setTurns((current) => reduce(current, event));
        if (event.event === "done" || event.event === "error") setRunning(false);
      }),
    [],
  );

  // Follow the tail. A transcript the user has to chase is a transcript that
  // reads as broken while a turn streams.
  useEffect(() => {
    const node = scroller.current;
    if (node) node.scrollTop = node.scrollHeight;
  }, [turns]);

  const submit = useCallback(() => {
    const text = draft.trim();
    if (text === "") return;
    window.ledge.send(text);
    setDraft("");
    setRunning(true);
    setTurns((current) =>
      current.concat([
        { turn: -Date.now(), prompt: text, text: "", tools: [], status: null, done: null, error: null },
      ]),
    );
  }, [draft]);

  const onKeyDown = useCallback(
    (event) => {
      // Return sends; shift-return is a newline. Escape interrupts, which is
      // the one gesture that has to work without reaching for the mouse.
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        submit();
        return;
      }
      if (event.key === "Escape" && running) {
        event.preventDefault();
        window.ledge.cancel();
        setRunning(false);
      }
    },
    [running, submit],
  );

  return (
    <div className="editor">
      <div className="transcript" ref={scroller}>
        {turns.length === 0 ? (
          <div className="empty">
            {app ? `Ask for a change to ${app}.` : "No app selected."}
          </div>
        ) : (
          turns.map((turn, index) => <Turn turn={turn} key={`${turn.turn}:${index}`} />)
        )}
      </div>
      <div className="composer">
        <textarea
          value={draft}
          rows={1}
          placeholder="Ask for a change…"
          spellCheck={false}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={onKeyDown}
          autoFocus
        />
        {running ? (
          <button type="button" className="stop" onClick={() => { window.ledge.cancel(); setRunning(false); }}>
            Stop
          </button>
        ) : null}
      </div>
    </div>
  );
}
