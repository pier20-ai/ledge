import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ShellSession } from "../src/connection";
import type { Envelope } from "../src/protocol/envelope";
import { Router } from "../src/router";

// **A track change is not a stop.**
//
// G2, on device: on every song change the right wing disappeared and came back.
// The cause was that the app rendered each *sample* faithfully — and between two
// songs both Music and Spotify spend a beat with `current track` unreadable, so
// the honest sample is "nothing playing". That emptied the panel to its
// invitation, unmounted the `<canvas>` the wing mirrors, and released the notch;
// a second later the next title arrived and everything was claimed again.
//
// The fix is that the surfaces describe the *session*, not the sample: a missing
// answer is tolerated for `STOP_GRACE_MS`, the ticker changes in place, and the
// waveform takes a visible **breath** — bars ease to the floor, then swell back
// with the new track's own character — in place of the vanish.
//
// This drives the real `protocol/demo-apps/nowplaying/app.jsx` through the real
// Router, with the session standing in for the shell and answering `ctx.apple`
// as a scripted Music.app: track A, a silent beat, track B, then a real stop.

const HOST_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const NODE_MODULES = join(HOST_DIR, "node_modules");
const DEMO_APPS = join(HOST_DIR, "..", "protocol", "demo-apps");
/** The delimiter players.js formats its one reply line with. */
const SEP = "|~|";

interface Track {
  title: string;
  artist: string;
}

/**
 * The shell, as far as this app can tell: it records what it is sent and
 * answers the two bridges nowplaying uses. `track` is what the fake Music.app
 * currently reports; `null` is the beat between two songs.
 */
class PlayerSession implements ShellSession {
  gen = 1;
  screen = { notchWidth: 189, menubarHeight: 32, scale: 2, maxPanelHeight: 480 };
  sent: Array<{ app: string; type: string; payload: Record<string, unknown> }> = [];
  router: Router | null = null;
  track: Track | null = null;
  /** Every wing request, in order: the string ticker, or null for a release. */
  wings: Array<string | null> = [];
  /** The bar heights of the latest frame the app drew. */
  bars: number[] = [];

  send(app: string, type: string, payload: Record<string, unknown>): void {
    this.sent.push({ app, type, payload });
    if (type === "chrome" && payload.request === "wing") {
      const wing = payload.wing as { text?: string } | null;
      this.wings.push(wing ? (wing.text ?? "") : null);
    }
    if (type === "draw") {
      this.bars = (payload.ops as Array<Record<string, unknown>>)
        .filter((op) => op.op === "rect")
        .map((op) => Number(op.h));
    }
    if (type === "apple") this.answerApple(app, payload);
    if (type === "platform") this.reply(app, "platformResult", { id: payload.id, ok: true });
  }

  private answerApple(app: string, payload: Record<string, unknown>): void {
    const source = String(payload.source ?? "");
    // Artwork is "none" and Spotify is not running: this test is about the
    // wing, and a second player answering would only add noise.
    const value = source.includes("artwork")
      ? "none"
      : source.includes("Spotify")
        ? "off"
        : this.track
          ? ["ok", "playing", this.track.title, this.track.artist, "12", "300"].join(SEP)
          : "idle";
    this.reply(app, "appleResult", { id: payload.id, ok: true, value });
  }

  /** Answers land on the next turn, as a real shell's would. */
  private reply(app: string, type: string, payload: Record<string, unknown>): void {
    queueMicrotask(() => this.router?.onEnvelope(this, { v: 1, app, seq: 1, type, payload }));
  }
}

let roots: string[] = [];
let openRouter: Router | null = null;

/** A temp apps root holding the real app, by symlink per file — see
 * test/radio.test.ts for why per file and not per folder. */
async function appsRootWith(appId: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), `ledge-${appId}-`));
  roots.push(root);
  await symlink(NODE_MODULES, join(root, "node_modules"));
  const source = join(DEMO_APPS, appId);
  await mkdir(join(root, appId), { recursive: true });
  for (const entry of await readdir(source)) {
    // Not the log (the worker makes its own) and not the committed sleeve —
    // `ensureArtwork` prunes stale ones out of the folder it is given.
    if (entry === "console.log" || entry.startsWith("art-")) continue;
    await symlink(join(source, entry), join(root, appId, entry));
  }
  return root;
}

async function waitFor(predicate: () => boolean, timeoutMs = 15000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await Bun.sleep(20);
  }
  throw new Error("timed out waiting for condition");
}

function envelope(app: string, type: string, payload: Record<string, unknown>): Envelope {
  return { v: 1, app, seq: 1, type, payload };
}

afterEach(async () => {
  openRouter?.shutdown();
  openRouter = null;
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
  await Bun.sleep(10);
});

describe("nowplaying across a track change", () => {
  test("the wing is held, the ticker changes in place, and the wave breathes", async () => {
    const root = await appsRootWith("nowplaying");
    const session = new PlayerSession();
    session.track = { title: "Rhubarb", artist: "Aphex Twin" };
    const router = new Router({
      appsRoot: root,
      settingsPath: join(root, "settings.json"),
      watch: false,
    });
    session.router = router;
    openRouter = router;
    await router.bindSession(session);

    router.onEnvelope(
      session,
      envelope("nowplaying", "lifecycle", { phase: "expanded", reduceMotion: false }),
    );

    // Track A: the wing goes up and the wave builds.
    await waitFor(() => session.wings.length >= 1);
    expect(session.wings[0]).toBe("Rhubarb");
    await waitFor(() => Math.max(...session.bars) > 8);

    // ------------------------------------------------- the beat between songs
    session.track = null;
    // Both players broadcast on a track change; the shell forwards it (§6 ext).
    router.onEnvelope(session, envelope("nowplaying", "event", { id: 0, name: "platform", data: {} }));

    // The wave goes quiet — every bar at the floor. This is the breath, and it
    // is the *only* thing that should change: the surface itself stays up.
    await waitFor(() => Math.max(...session.bars) <= 3);
    expect(session.wings).toEqual(["Rhubarb"]);

    // ------------------------------------------------------- track B arrives
    session.track = { title: "Turiya", artist: "Alice Coltrane" };
    router.onEnvelope(session, envelope("nowplaying", "event", { id: 0, name: "platform", data: {} }));

    await waitFor(() => session.wings.length >= 2);
    expect(session.wings[1]).toBe("Turiya");
    // The whole point: no release anywhere in there. The notch never blinked.
    expect(session.wings).toEqual(["Rhubarb", "Turiya"]);
    // …and the wave swells back rather than snapping to full height.
    await waitFor(() => Math.max(...session.bars) > 8);

    // ------------------------------------------------------- a real stop
    session.track = null;
    router.onEnvelope(session, envelope("nowplaying", "event", { id: 0, name: "platform", data: {} }));
    // Now — and only after the grace — the notch goes back to being a notch.
    await waitFor(() => session.wings.at(-1) === null, 12000);
    expect(session.wings).toEqual(["Rhubarb", "Turiya", null]);
  }, 45000);
});
