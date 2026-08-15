// The page's half of the JS↔Swift bridge. Imported first by `main.jsx` so the
// globals exist before React mounts — Swift evaluates `__ledgeDeliver` as soon
// as the page reports ready, and a delivery into a page whose bundle has not
// finished evaluating is simply lost.

const listeners = new Set();

// A short replay buffer. Swift queues events until `ready()`, but `ready()`
// fires when this module runs and React mounts a tick or two later, so the
// first events of a turn would otherwise land with nobody listening.
const replay = [];
const REPLAY_LIMIT = 512;

function post(message) {
  const handler =
    window.webkit &&
    window.webkit.messageHandlers &&
    window.webkit.messageHandlers.ledge;
  // Absent when the bundle is opened in a plain browser for styling work. Not
  // an error: the surface should still render, it just talks to nobody.
  if (handler) handler.postMessage(message);
}

function dispatch(event) {
  if (listeners.size === 0) {
    replay.push(event);
    if (replay.length > REPLAY_LIMIT) replay.shift();
    return;
  }
  for (const listener of listeners) {
    try {
      listener(event);
    } catch (error) {
      // One bad subscriber must not stop the stream reaching the others, and
      // must not throw back into Swift's `evaluateJavaScript`.
      console.error("[ledge] listener threw", error);
    }
  }
}

window.__ledgeDeliver = dispatch;

window.ledge = {
  /// Subscribe to the builder stream. Returns an unsubscribe function.
  onEvent(callback) {
    listeners.add(callback);
    if (replay.length > 0) {
      const buffered = replay.splice(0, replay.length);
      for (const event of buffered) callback(event);
    }
    return () => listeners.delete(callback);
  },
  /// Start a turn. Empty/whitespace input is dropped Swift-side.
  send(text) {
    post({ type: "input", text: String(text) });
  },
  /// Interrupt the running turn.
  cancel() {
    post({ type: "cancel" });
  },
  /// The pill's ⌄/⌃. The pane clears itself; Swift needs to know because the
  /// panel is a different height with no transcript in it, and because the
  /// stage behind gets its prominence back (flow.md, "Visit modes").
  transcript(collapsed) {
    post({ type: "transcript", collapsed: Boolean(collapsed) });
  },
  /// The user scrolled into the past, or came back to the latest. The stage
  /// behind recedes while they are back there (design.html §08).
  scrollback(past) {
    post({ type: "scrollback", past: Boolean(past) });
  },
  /// Esc, with no turn to interrupt. Forwarded explicitly rather than left to
  /// WebKit's responder-chain behaviour: whether an unhandled key event escapes
  /// a focused `<textarea>` inside a `WKWebView` is not a contract anybody
  /// wrote down, and "Esc closes the visit" is flow.md's Transitions table.
  escape() {
    post({ type: "escape" });
  },
  /// Tell Swift the page can receive events. Called once, below.
  ready() {
    post({ type: "ready" });
  },
};

window.ledge.ready();
