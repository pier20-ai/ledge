// Making a new app, from the CLI and from the notch's [+] surface (spec §8).
//
// Both entry points end up in the same place — a folder with an `app.jsx` in it
// (spec §6) — but they arrive with different information. `ledge new` is given
// an id by a human who knows what they want to call it. The [+] surface is given
// a *sentence*: "a pomodoro timer that dings", typed by someone who is thinking
// about the app, not about the directory it will live in. Asking them to name a
// folder first would put a form in front of the one interaction this product is
// selling.
//
// So the id is derived from what they said, and the derivation is allowed to be
// crude: the id is the folder name and the wire identity, but the name the user
// actually *sees* comes from `meta.name`, which the agent writes as its first
// act. A slightly awkward directory is a cost paid once, in a place nobody
// looks; a naming dialog is a cost paid every single time.

import { mkdir, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";

/** The id rule from spec §6, restated as a predicate: it has to survive being
 * a directory name and an envelope field. */
export const APP_ID = /^[a-z0-9][a-z0-9-]*$/;

/**
 * Words that carry no identity.
 *
 * Everything here is either a request wrapper ("make me an app that…") or
 * grammatical glue. What survives is what the user was actually talking about,
 * which is what the folder should be called. Kept deliberately small — an
 * aggressive list starts eating real words ("show" is glue, "shows" in "shows
 * my calendar" is glue, but "show" in "a show tracker" is the subject) and the
 * failure mode of leaving a word in is a longer name, while the failure mode of
 * removing one is a folder called `tracker`.
 */
const GLUE = new Set([
  "a", "an", "the", "my", "me", "i", "it", "its",
  "make", "build", "create", "write", "give", "add", "new", "please", "can", "you",
  "app", "widget", "thing", "something", "that", "which", "who", "with", "for",
  "of", "to", "in", "on", "and", "or", "is", "are", "be", "will", "would",
  "want", "need", "like", "shows", "showing", "display", "displays", "displaying",
]);

/** How many meaningful words make it into the id. Two is enough to be
 * recognisable in a list and short enough to type; three routinely produced
 * things like `pomodoro-timer-dings`. */
const WORD_LIMIT = 2;

/** Long enough for two real words, short enough to read in a terminal. */
const MAX_LENGTH = 24;

/**
 * Turn a prompt into a candidate app id. Pure — collision handling belongs to
 * the caller, which is the only one that knows what already exists.
 *
 * Returns `"app"` when the prompt has nothing usable in it (an emoji, another
 * script, or a sentence made entirely of glue): a bland id is a far better
 * outcome than refusing to create the app the user just asked for.
 */
export function deriveAppId(prompt: string): string {
  const words = prompt
    .toLowerCase()
    // Anything that is not a letter or digit is a word break. Non-ASCII letters
    // are dropped rather than transliterated: a wrong transliteration is worse
    // than the fallback, and `meta.name` carries the real name regardless.
    .split(/[^a-z0-9]+/)
    .filter(Boolean);

  const meaningful = words.filter((word) => !GLUE.has(word));
  // If the filter ate everything, the "glue" was the content.
  const chosen = (meaningful.length > 0 ? meaningful : words).slice(0, WORD_LIMIT);

  const id = chosen
    .join("-")
    .slice(0, MAX_LENGTH)
    // A trailing dash can only come from truncating mid-join, and an id must
    // start with an alphanumeric (spec §6).
    .replace(/^-+|-+$/g, "")
    .replace(/^[0-9]+$/, "");

  return APP_ID.test(id) ? id : "app";
}

/** An app's starting point. Small on purpose: the fastest way to learn this
 * platform is to change something that already renders. */
export function scaffoldSource(id: string): string {
  // `pomodoro-timer` → `Pomodoro Timer`. This is the name on the app strip until
  // the agent writes its own, and it is the first thing the user sees after
  // asking for the app, so it is worth the two lines: `Pomodoro-timer` reads as
  // a directory that leaked into the UI, because that is exactly what it is.
  const name = id
    .split("-")
    .filter(Boolean)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
  return `/** @jsxImportSource react */
// ${name} — see AGENTS.md at the apps root for the full platform contract.

export const meta = { name: ${JSON.stringify(name)}, icon: "sf:square.dashed" };

export default function App({ status = "ready" }) {
  return (
    <stack axis="v" pad={14} gap={8}>
      <text content={${JSON.stringify(name)}} size="l" weight="bold" />
      <text content={status} color="secondary" />
    </stack>
  );
}

// Background work. Called in a loop, awaited each time — pace it yourself.
// export async function monitor(ctx) {
//   ctx.update({ status: "…" });
//   await Bun.sleep(60_000);
// }
`;
}

/**
 * Create the folder for `id`, or fail if it is taken. Returns the entry path.
 *
 * `mkdir` + `writeFile` rather than a check-then-write: the check is here for
 * the error message, but the write is what makes it real, and between the two
 * the watcher may already have seen the directory appear.
 */
export async function scaffoldApp(appsRoot: string, id: string): Promise<string> {
  if (!APP_ID.test(id)) {
    throw new Error(`'${id}' is not a valid app id — use lowercase letters, digits and dashes`);
  }
  const dir = join(appsRoot, id);
  const entry = join(dir, "app.jsx");
  if (await exists(entry)) throw new Error(`'${id}' already exists at ${dir}`);
  await mkdir(dir, { recursive: true });
  await writeFile(entry, scaffoldSource(id));
  return entry;
}

/**
 * Scaffold an app *named after what the user asked for* — the [+] path.
 *
 * Collisions get a numeric suffix rather than an error. The user asked for a
 * second timer; telling them they already have one, in a chat surface with no
 * way to rename anything, would be a dead end.
 */
export async function scaffoldFromPrompt(appsRoot: string, prompt: string): Promise<string> {
  const base = deriveAppId(prompt);
  for (let attempt = 1; attempt < 100; attempt += 1) {
    const id = attempt === 1 ? base : `${base}-${attempt}`;
    if (await exists(join(appsRoot, id))) continue;
    await scaffoldApp(appsRoot, id);
    return id;
  }
  // A hundred apps whose names all reduce to the same two words. Nothing sane
  // reaches this, but silently overwriting one of them would not be sane either.
  throw new Error(`could not find a free name for '${base}'`);
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}
