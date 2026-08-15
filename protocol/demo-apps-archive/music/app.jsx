/** @jsxImportSource react */
// Music — live Now Playing, driven entirely by `ctx.apple` (spec §6). The panel
// keeps the mockup's layout language (art tile, title/artist, scrub bar,
// transport) but every part of it is now real: the metadata comes back from
// AppleScript, the buttons send Apple events, and the scrub bar seeks.
//
// **Two players, never launched.** Music.app and Spotify are queried in that
// order, and each query is guarded by a System Events process check *before* the
// `tell application` block is entered:
//
//     tell application "System Events" to set isUp to (name of processes) contains "Music"
//     if not isUp then return "off"
//     tell application "Music" … end tell
//
// This matters more than it looks. `tell application "Music"` is what sends the
// Apple event that would *launch* Music, and a now-playing widget that starts
// iTunes because you glanced at the notch is a bug with a very long memory.
// Compiling the block is harmless (NSAppleScript reads terminology from the
// app's sdef on disk, verified against a non-running app); entering it is not,
// so the guard is a hard `return` and never a `try`.
//
// **Pacing is `onLifecycle`'s job** (spec §4.2): 3 s while the panel is open,
// 15 s while it is collapsed. The monitor runs either way — it has to, or the
// wing would go stale — it just asks less often when nobody is looking.
//
// **The poll is the truth; the notification is the latency fix.** A three-second
// poll is the right cadence for reconciling with a player that can be driven
// from anywhere, and a terrible cadence for *noticing*: a track change took up
// to three seconds to reach the notch, and the scrub bar moved in three-second
// steps. Two additions fix both without touching the poll:
//
//   - `ctx.platform.observe("distributedNotification", …)` on Music's and
//     Spotify's own playback broadcasts (§6 extension). Either one fires an
//     id-0 `platform` event, which triggers an immediate (250 ms-debounced)
//     poll — so a track change appears essentially instantly and the poll stays
//     the authority on what is actually loaded.
//   - `rate` on the scrub bar (§5): the slider advances itself at one second
//     per second while the music plays, and each poll re-anchors it. The app
//     commits three times a minute and the bar glides at 60 fps.
//
// Observing is passive: the notification is a broadcast the OS makes anyway, so
// it does not launch anything and does not weaken the guard discipline above.
//
// **Artwork** (the file-image `src`, protocol/README.md):
//   - Spotify hands out `artwork url of current track`, an https URL, which the
//     app fetches itself and writes next to app.jsx.
//   - Music.app has no URL, so AppleScript writes `raw data of artwork 1 of
//     current track` straight to a file with `open for access` / `write`.
// Either way the file is named `art-<hash>.jpg` after the track, NOT a stable
// `artwork.jpg`: the shell's file-image view only re-decodes when the *path*
// changes (LedgeFileImageView.apply), so a stable name would show track 1's
// sleeve for the rest of the session. Failure at any step is not an error — it
// falls back to the tinted placeholder tile the mockup always had.
//
// **The monitor never throws** (spec §6 rule 2): every AppleScript call is
// wrapped, and a refused Automation prompt or a quitting player ends in the
// quiet "Nothing playing" card rather than a crash-and-backoff loop.

import { readdir, unlink } from "node:fs/promises";

export const meta = { name: "Music", icon: "sf:music.note" };

// ---------------------------------------------------------------- pacing

const POLL_EXPANDED_MS = 3_000;
const POLL_COLLAPSED_MS = 15_000;

/** How long a `platform` event waits for its neighbours before forcing a poll.
 * Both players emit a small burst around a track change (state, then track,
 * sometimes position), and each Apple event costs real milliseconds — so the
 * burst is collapsed into one read. Short enough to still read as instant. */
const WAKE_DEBOUNCE_MS = 250;

/** The OS broadcasts each player already makes when playback changes. Watching
 * them is passive — nothing here sends an Apple event, so the never-launch
 * guard discipline in the header is untouched. */
const PLAYBACK_NOTIFICATIONS = [
  "com.apple.Music.playerInfo",
  "com.spotify.client.PlaybackStateChanged",
];

// The panel phase, from onLifecycle. Collapsed until the shell says otherwise —
// the notch starts closed, and guessing "open" would poll 5× too fast for the
// first 15 seconds of every session.
let expanded = false;

// ---------------------------------------------------------------- AppleScript

// A field separator that cannot plausibly occur in a track title. AppleScript's
// type system is bigger than JSON's, so the shell hands back whatever the script
// *printed* (protocol/README.md) — which means an app that wants structure
// builds a string, exactly as it would in a terminal.
const SEP = "|~|";

/** Escape a JS string into an AppleScript string literal. Track paths come from
 * `import.meta.dir`, so this is belt-and-braces rather than untrusted input —
 * but a folder with a quote in it should not silently produce a syntax error. */
const asString = (value) => `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;

/** The launch guard every script in this file starts with. `process` is the
 * process name in System Events' list, which is what a running app is. */
const guard = (process) => `
tell application "System Events" to set isUp to (name of processes) contains ${asString(process)}
if not isUp then return "off"`;

/**
 * One player's state as a single delimited line. Both players answer the same
 * shape, so the JS side has one parser:
 *
 *   off                                        the app is not running
 *   idle${SEP}<state>                          running, but nothing is loaded
 *   ok${SEP}<state>${SEP}<title>${SEP}<artist>${SEP}<album>${SEP}<pos>${SEP}<dur>
 *
 * `player position` is seconds in both players; `duration` is seconds in Music
 * and **milliseconds** in Spotify, which is normalized in `parseState` rather
 * than in the script — one place, next to the thing that knows about players.
 */
function stateScript(player) {
  return `${guard(player.process)}
set D to ${asString(SEP)}
tell application ${asString(player.target)}
	set theState to (player state as text)
	try
		set thePos to (player position as text)
	on error
		set thePos to "0"
	end try
	try
		set theTrack to current track
		set theName to (name of theTrack) as text
		set theArtist to (artist of theTrack) as text
		set theAlbum to (album of theTrack) as text
		set theDuration to (duration of theTrack) as text
	on error
		return "idle" & D & theState
	end try
	return "ok" & D & theState & D & theName & D & theArtist & D & theAlbum & D & thePos & D & theDuration
end tell`;
}

/** A transport command, or a seek. Guarded exactly like the state query — a
 * "next track" that launches the player is the same bug as a poll that does. */
function commandScript(player, command) {
  return `${guard(player.process)}
tell application ${asString(player.target)}
	${command}
end tell
return "ok"`;
}

/**
 * Music.app's artwork, written to `path` by AppleScript itself. `open for
 * access` is a Standard Additions command and must live OUTSIDE the
 * `tell application "Music"` block — inside it, `open` is Music's own command
 * and the script opens the file *in the player*.
 */
function musicArtworkScript(player, path) {
  return `${guard(player.process)}
set artData to missing value
tell application ${asString(player.target)}
	if player state is stopped then return "none"
	try
		set artData to raw data of artwork 1 of current track
	on error
		return "none"
	end try
end tell
if artData is missing value then return "none"
set outRef to open for access (POSIX file ${asString(path)}) with write permission
set eof outRef to 0
write artData to outRef
close access outRef
return "ok"`;
}

/** Spotify publishes a plain https artwork URL, so the fetch is the app's own. */
function spotifyArtworkScript(player) {
  return `${guard(player.process)}
tell application ${asString(player.target)}
	try
		return (artwork url of current track) as text
	on error
		return "none"
	end try
end tell`;
}

// ---------------------------------------------------------------- players
//
// Music first: on a Mac with both, the Apple one is the one the media keys and
// the system Now Playing widget follow, so it is the one the notch should agree
// with. `durationUnit` is the whole per-player difference in the metadata.

const PLAYERS = [
  { id: "music", process: "Music", target: "Music", label: "Music", durationUnit: 1 },
  { id: "spotify", process: "Spotify", target: "Spotify", label: "Spotify", durationUnit: 1000 },
];

// ---------------------------------------------------------------- state

let ctxRef = null; // the monitor's ctx, kept for the button callbacks (spec §6)
let current = null; // the last parsed player state, or null
let artworkKey = ""; // the track the artwork file on disk belongs to
let artworkPath = null; // that file, or null when we fell back to the placeholder
let lastWing = "";
let lastSignature = "";
let cleanedArtwork = false;
let observed = false; // the playback notifications have been registered
let wakeTimer = null; // the debounce behind a `platform` event
let polling = false; // one read at a time: an event and the monitor can collide

const PLAYING = new Set(["playing", "fast forwarding", "rewinding"]);

/** Parse one `stateScript` reply. Returns null for "off" / "idle" / anything
 * unrecognized — a malformed line is the same as no player, never a throw. */
function parseState(player, reply) {
  if (typeof reply !== "string") return null;
  const parts = reply.split(SEP);
  if (parts[0] !== "ok" || parts.length < 7) return null;

  const [, state, title, artist, album, position, duration] = parts;
  const seconds = Number(position);
  const total = Number(duration) / player.durationUnit;
  if (!title) return null;

  return {
    player: player.id,
    label: player.label,
    playing: PLAYING.has(state.toLowerCase()),
    title,
    artist,
    album,
    position: Number.isFinite(seconds) ? Math.max(0, seconds) : 0,
    duration: Number.isFinite(total) && total > 0 ? total : 0,
  };
}

/** Ask each player in turn; the first one that is running AND has a track wins.
 * A player that is running but stopped does not win — it would beat a Spotify
 * that is actually playing to the panel. */
async function readPlayers(ctx) {
  for (const player of PLAYERS) {
    let reply;
    try {
      reply = await ctx.apple.script(stateScript(player));
    } catch (error) {
      // A rejected Automation prompt, a compile error, a 10 s timeout: all of
      // them mean "no answer from this player", none of them mean "crash".
      console.log(`${player.id}: ${error?.message ?? error}`);
      continue;
    }
    if (reply === "off") continue;
    const state = parseState(player, reply);
    if (state) return state;
  }
  return null;
}

// ---------------------------------------------------------------- artwork

/** A stable, filesystem-safe id for a track. The artwork path is derived from
 * it, and the path is what makes the shell re-decode (see the header). */
function trackKey(state) {
  return Bun.hash(`${state.player}\u0000${state.title}\u0000${state.artist}\u0000${state.album}`)
    .toString(36);
}

/** Delete artwork files from previous runs/tracks. The app folder is the app's
 * own business (spec §6), but "its own business" is not a licence to grow a
 * sleeve cache forever. */
async function pruneArtwork(keep) {
  try {
    const names = await readdir(import.meta.dir);
    await Promise.all(
      names
        .filter((name) => name.startsWith("art-") && name.endsWith(".jpg") && name !== keep)
        .map((name) => unlink(`${import.meta.dir}/${name}`).catch(() => {})),
    );
  } catch {
    // An unreadable app folder is not something a music panel should die over.
  }
}

/** Fetch Spotify's artwork URL into `path`. Returns true if a file landed. */
async function fetchArtwork(url, path) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(6_000) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const bytes = await response.arrayBuffer();
    if (bytes.byteLength < 256) throw new Error("suspiciously small image");
    await Bun.write(path, bytes);
    return true;
  } catch (error) {
    console.log(`artwork fetch failed: ${error?.message ?? error}`);
    return false;
  }
}

/**
 * Make sure the artwork file on disk matches `state`, and return its path (or
 * null for the placeholder). Only runs when the track changed — pulling a JPEG
 * out of Music.app every 3 s would be an Apple event per poll for a picture
 * that has not moved.
 */
async function refreshArtwork(ctx, state) {
  const key = trackKey(state);
  if (key === artworkKey) return artworkPath;
  artworkKey = key;
  artworkPath = null;

  const name = `art-${key}.jpg`;
  const path = `${import.meta.dir}/${name}`;
  const player = PLAYERS.find((entry) => entry.id === state.player);
  if (!player) return null;

  try {
    if (player.id === "spotify") {
      const url = await ctx.apple.script(spotifyArtworkScript(player));
      if (typeof url === "string" && url.startsWith("http")) {
        if (await fetchArtwork(url, path)) artworkPath = path;
      }
    } else {
      const reply = await ctx.apple.script(musicArtworkScript(player, path));
      // The script wrote the bytes itself; trust it only as far as the file.
      if (reply === "ok" && (await Bun.file(path).exists())) artworkPath = path;
    }
  } catch (error) {
    console.log(`artwork failed: ${error?.message ?? error}`);
  }

  await pruneArtwork(artworkPath ? name : null);
  if (artworkPath) console.log(`artwork -> ${name}`);
  return artworkPath;
}

// ---------------------------------------------------------------- transport
//
// Every control is one guarded Apple event. They reach the component as props
// (it never sees ctx), the same ownership split the Alarm and Settings apps use.

async function send(command) {
  if (!ctxRef || !current) return;
  const player = PLAYERS.find((entry) => entry.id === current.player);
  if (!player) return;
  try {
    await ctxRef.apple.script(commandScript(player, command));
    console.log(`${player.id}: ${command}`);
  } catch (error) {
    console.log(`${player.id}: ${command} failed — ${error?.message ?? error}`);
    return;
  }
  // Re-read straight away rather than waiting out the poll: a play button that
  // takes three seconds to change shape feels broken even when it worked.
  await tick(ctxRef);
}

const onPlayPause = () => void send("playpause");
const onNext = () => void send("next track");
const onPrevious = () => void send("previous track");

/** The scrub bar is a real seek — both players accept `set player position to`
 * in **seconds**, and the slider now works in seconds too (its `min`/`max` are
 * the track's own scale, §5), so there is no scaling left to do. Optimistically
 * moved locally first, because the poll that would confirm it is up to three
 * seconds away. */
function onSeek(seconds) {
  if (!current || current.duration <= 0) return;
  const position = Math.max(0, Math.min(current.duration, seconds));
  current = { ...current, position };
  publish();
  void send(`set player position to ${position.toFixed(2)}`);
}

// ---------------------------------------------------------------- publishing

function viewProps() {
  if (!current) {
    return { track: null, artwork: null, onPlayPause, onNext, onPrevious, onSeek };
  }
  return {
    track: {
      title: current.title,
      artist: current.artist,
      album: current.album,
      label: current.label,
      playing: current.playing,
      position: current.position,
      duration: current.duration,
    },
    artwork: artworkPath,
    onPlayPause,
    onNext,
    onPrevious,
    onSeek,
  };
}

/** A cheap signature of the picture, so a 3 s poll of a paused player costs
 * zero commits. Position is rounded to the second the panel actually shows. */
function signature(props) {
  const track = props.track;
  return JSON.stringify([
    track && [
      track.title,
      track.artist,
      track.album,
      track.label,
      track.playing,
      Math.floor(track.position),
      Math.round(track.duration),
    ],
    props.artwork,
  ]);
}

function publish() {
  if (!ctxRef) return;
  const props = viewProps();
  const next = signature(props);
  if (next === lastSignature) return;
  lastSignature = next;
  ctxRef.update(props);
}

/** The collapsed notch (spec §3.3 extension): the title, and only while the
 * music is actually playing. A wing that says "♪ Nightcall" over a player that
 * has been paused since yesterday is noise wearing a signal's clothes. */
function publishWing() {
  if (!ctxRef) return;
  const text = current && current.playing ? `♪ ${current.title}` : "";
  if (text === lastWing) return;
  lastWing = text;
  ctxRef.wing(text ? { text } : null);
  console.log(text ? `wing -> ${text}` : "wing released");
}

/**
 * The mini view (spec §3.3 extension): when the song changes, say so under the
 * notch for a few seconds.
 *
 * Only on a genuine change of *track* — not on play/pause, not on a seek, and
 * never on the first poll after a reload, which would peek at whatever happened
 * to be playing when you saved a file. The wing already carries "what is on";
 * this is for the moment it becomes something else.
 */
function peekIfTrackChanged(ctx, previousTrack) {
  if (!current || !current.playing) return;
  const key = trackKey(current);
  if (!previousTrack || key === previousTrack) return;
  ctx.peek(4000);
}

// ---------------------------------------------------------------- monitor

/** One poll. Separated from `monitor` so a transport command — or a playback
 * notification — can force one immediately after it lands. Guarded against
 * overlap: an event and a monitor pass can arrive in the same tick, and two
 * concurrent reads would just be twice the Apple events for one answer. */
async function tick(ctx) {
  if (polling) return;
  polling = true;
  try {
    const previousTrack = current ? trackKey(current) : null;
    const state = await readPlayers(ctx);
    current = state;
    if (state) {
      await refreshArtwork(ctx, state);
    } else if (artworkKey) {
      artworkKey = "";
      artworkPath = null;
      await pruneArtwork(null);
    }
    publish();
    publishWing();
    peekIfTrackChanged(ctx, previousTrack);
  } finally {
    polling = false;
  }
}

/**
 * Register the playback broadcasts once per worker (spec §6 extension).
 * Registration is idempotent shell-side, and released for us on every lifecycle
 * transition — so "once per worker" is the whole lifetime story.
 */
async function ensureObservers(ctx) {
  if (observed || !ctx.platform) return;
  observed = true;
  for (const name of PLAYBACK_NOTIFICATIONS) {
    try {
      await ctx.platform.observe("distributedNotification", name);
      console.log(`observing ${name}`);
    } catch (error) {
      // A shell that cannot observe is a shell where the 3 s poll is all we
      // have — which is exactly what this app did before, so it is a log line
      // and not a failure.
      console.log(`observe ${name} failed: ${error?.message ?? error}`);
    }
  }
}

/** A playback notification fired: poll now rather than at the next beat. The
 * debounce collapses the small burst both players emit around a track change
 * into one read. */
function wake() {
  if (!ctxRef) return;
  if (wakeTimer) clearTimeout(wakeTimer);
  wakeTimer = setTimeout(() => {
    wakeTimer = null;
    // A throw inside a timer is an unhandled rejection, not an app crash the
    // supervisor can see — so it is caught here as carefully as in `monitor`.
    void tick(ctxRef).catch((error) => {
      console.log(`wake poll failed: ${error?.message ?? error}`);
    });
  }, WAKE_DEBOUNCE_MS);
}

/** App-level events (§4.1, id 0). `platform` is the observed OS broadcast; its
 * `userInfo` is deliberately ignored — the poll is what says what is playing,
 * and this only says *when* to ask. */
export function onEvent(name, data, ctx) {
  if (name !== "platform") return;
  ctxRef = ctxRef ?? ctx;
  wake();
}

export async function monitor(ctx) {
  try {
    ctxRef = ctx;
    await ensureObservers(ctx);
    if (!cleanedArtwork) {
      // Sleeves from a previous run belong to tracks nobody is playing now.
      cleanedArtwork = true;
      await pruneArtwork(null);
    }
    await tick(ctx);
  } catch (error) {
    // A throw here is an app crash with backoff (spec §6 rule 2). Nothing above
    // should throw; if it ever does, the panel goes quiet instead of dying.
    console.log(`poll failed: ${error?.stack ?? error}`);
    current = null;
    publish();
    publishWing();
  }
  await Bun.sleep(expanded ? POLL_EXPANDED_MS : POLL_COLLAPSED_MS);
}

/** Panel phase → poll rate (spec §4.2). The monitor keeps running while
 * collapsed because the wing does; it just costs one Apple event per 15 s. */
export function onLifecycle(phase) {
  if (phase === "expanded") expanded = true;
  else if (phase === "collapsed" || phase === "hidden") expanded = false;
}

// ---------------------------------------------------------------- the panel

/** mm:ss, and "−mm:ss" for the remaining side. Guards a duration of 0, which is
 * what a stream reports. */
function clock(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const whole = Math.floor(seconds);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
}

/** The art tile: the real sleeve when we have one, the mockup's tinted stand-in
 * when we don't. Two different component kinds on purpose — the shell builds a
 * file-image view and an `sf:` symbol view from different classes, so swapping
 * `src` between them would not be a partial update anyway. */
/** `size` because the mini view shows the same sleeve smaller — one component,
 * two surfaces, rather than a second near-copy that drifts. */
function Artwork({ artwork, size = 46 }) {
  const radius = size >= 40 ? 9 : 6;
  if (artwork) return <image src={artwork} w={size} h={size} radius={radius} />;
  return <stack fill="accentTint" stroke="hairline" radius={radius} pad={size / 2} />;
}

/** The quiet card: no player running, or running with nothing loaded. No
 * transport, because there is nothing to transport. This is also the mount
 * state scripts/snapshot-demos.sh dumps — the monitor never runs there, so what
 * the snapshot shows is honestly what a fresh, silent Mac shows. */
function Idle() {
  return (
    <stack axis="v" pad={16} gap={12}>
      {/* Panel wing (spec §5): the shell names the app, so the old "Now Playing"
          title row said nothing the chrome did not already say — and put the
          player badge under the camera housing while it was at it. */}
      <wing side="left">
        <text content="●" size="xs" color="secondary" />
        <text content="no player" size="s" weight="semibold" color="secondary" />
      </wing>

      <stack axis="h" gap={12}>
        <stack fill="raised" stroke="hairline" radius={9} pad={23} />
        <stack axis="v" gap={3}>
          <text content="Nothing playing" size="m" weight="semibold" color="secondary" />
          {/* "quiet", not "closed": this card is also what a running player
              with nothing loaded looks like, and the panel should not claim
              more than it checked. */}
          <text content="Music and Spotify are quiet" size="s" color="tertiary" />
        </stack>
        <spacer />
      </stack>
    </stack>
  );
}

export default function Music({ track = null, artwork = null, onPlayPause, onNext, onPrevious, onSeek }) {
  if (!track) return <Idle />;

  const duration = track.duration > 0 ? track.duration : 0;
  const remaining = duration > 0 ? duration - track.position : 0;

  return (
    <stack axis="v" pad={16} gap={12}>
      <wing side="left">
        <text content="●" size="xs" color={track.playing ? "green" : "secondary"} />
        <text content={track.label} size="s" weight="semibold" color="secondary" />
      </wing>

      {/* The peek surface (§3.3 extension). Kept rendered and current at all
          times — `ctx.peek` only decides *when* it is shown, so the shell
          already holds a live view and a track change appears instantly. One
          line: sleeve, title, artist. */}
      <mini>
        <stack axis="h" gap={10}>
          <Artwork artwork={artwork} size={30} />
          <text content={track.title} size="m" weight="semibold" truncate />
          <text content={track.artist} size="s" color="secondary" truncate />
        </stack>
      </mini>

      <stack axis="h" gap={12}>
        <Artwork artwork={artwork} />
        <stack axis="v" gap={3}>
          <text content={track.title} size="m" weight="semibold" truncate />
          <text
            content={track.album ? `${track.artist} — ${track.album}` : track.artist}
            size="s"
            color="secondary"
            truncate
          />
        </stack>
        <spacer />
      </stack>

      {/* §5's position control is a slider, so the scrub bar carries a knob and
          the accent fill. It works in **seconds** — `min`/`max` are the track's
          own scale — and `rate` is what makes it move between polls: one second
          of value per second of wall clock while the music plays, zero while it
          is paused, re-anchored by every commit. `onChange` is a real seek. */}
      <stack axis="v" gap={4}>
        <slider
          value={track.position}
          min={0}
          max={duration > 0 ? duration : 1}
          rate={track.playing && duration > 0 ? 1 : 0}
          onChange={(data) => onSeek?.(data?.value ?? 0)}
        />
        <stack axis="h">
          <text content={clock(track.position)} size="xs" weight="medium" color="secondary" />
          <spacer />
          <text
            content={duration > 0 ? `−${clock(remaining)}` : "live"}
            size="xs"
            weight="medium"
            color="secondary"
          />
        </stack>
      </stack>

      {/* Icon-only transport: a `button` with an `sf:` icon and an empty label
          is the §5 vocabulary's answer to a round glyph control. */}
      <stack axis="h" gap={10}>
        <spacer />
        <button label="" icon="sf:backward.fill" variant="glass" onClick={() => onPrevious?.()} />
        <button
          label=""
          icon={track.playing ? "sf:pause.fill" : "sf:play.fill"}
          variant="accent"
          onClick={() => onPlayPause?.()}
        />
        <button label="" icon="sf:forward.fill" variant="glass" onClick={() => onNext?.()} />
        <spacer />
      </stack>
    </stack>
  );
}
