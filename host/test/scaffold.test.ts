import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { APP_ID, deriveAppId, scaffoldApp, scaffoldFromPrompt } from "../src/scaffold";

// Naming an app after the sentence that asked for it (spec §8, the [+] surface).
//
// The bar is not "a good name" — no heuristic gets that from one sentence. It is
// "a valid id, recognisably about the right thing, and never a collision".

let roots: string[] = [];
afterEach(async () => {
  for (const root of roots) await rm(root, { recursive: true, force: true });
  roots = [];
});

async function tempRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ledge-scaffold-"));
  roots.push(root);
  return root;
}

describe("deriveAppId", () => {
  test("keeps the subject and drops the request around it", () => {
    expect(deriveAppId("a pomodoro timer that dings")).toBe("pomodoro-timer");
    expect(deriveAppId("make me an app that shows the weather")).toBe("weather");
    expect(deriveAppId("Build a chess game")).toBe("chess-game");
  });

  test("survives punctuation, case and runs of whitespace", () => {
    expect(deriveAppId("  Track   my  HABITS, daily! ")).toBe("track-habits");
  });

  test("falls back rather than refusing", () => {
    // Nothing usable: an id still has to come out, because the alternative is
    // telling someone their sentence was not good enough to make an app from.
    expect(deriveAppId("🎧🎧🎧")).toBe("app");
    expect(deriveAppId("")).toBe("app");
    // A sentence of pure glue: the glue *is* the content, so it is used.
    expect(deriveAppId("make me a new app")).toBe("make-me");
  });

  test("never produces something that is not an app id", () => {
    const prompts = [
      "a pomodoro timer",
      "123",
      "!!!",
      "an extremely long request about tracking every single expense I have",
      "-dash-leading",
      "日本語のアプリ",
    ];
    for (const prompt of prompts) {
      expect(APP_ID.test(deriveAppId(prompt))).toBe(true);
    }
  });
});

describe("scaffoldApp", () => {
  test("writes an app.jsx that names itself", async () => {
    const root = await tempRoot();
    const entry = await scaffoldApp(root, "pomodoro");
    expect(entry).toBe(join(root, "pomodoro", "app.jsx"));
    const source = await readFile(entry, "utf8");
    expect(source).toContain('export const meta = { name: "Pomodoro"');
    expect(source).toContain("export default function App");
  });

  test("refuses an id that could not be a directory", async () => {
    const root = await tempRoot();
    await expect(scaffoldApp(root, "Not An Id")).rejects.toThrow("not a valid app id");
    await expect(scaffoldApp(root, "../escape")).rejects.toThrow("not a valid app id");
  });

  test("refuses to write over an app that exists", async () => {
    const root = await tempRoot();
    await scaffoldApp(root, "pomodoro");
    await expect(scaffoldApp(root, "pomodoro")).rejects.toThrow("already exists");
  });
});

describe("scaffoldFromPrompt", () => {
  test("creates the folder and returns the id the shell should switch to", async () => {
    const root = await tempRoot();
    const id = await scaffoldFromPrompt(root, "a pomodoro timer that dings");
    expect(id).toBe("pomodoro-timer");
    expect((await stat(join(root, id, "app.jsx"))).isFile()).toBe(true);
  });

  test("a second app with the same name gets a suffix, not an error", async () => {
    const root = await tempRoot();
    expect(await scaffoldFromPrompt(root, "a pomodoro timer")).toBe("pomodoro-timer");
    // The user asked for another one. Refusing here would be a dead end: the
    // chat surface has no way to rename anything.
    expect(await scaffoldFromPrompt(root, "a pomodoro timer")).toBe("pomodoro-timer-2");
    expect(await scaffoldFromPrompt(root, "a pomodoro timer")).toBe("pomodoro-timer-3");
  });
});
