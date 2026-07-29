// Rendering an app to a picture, without a screen (spec §3.1, §5).
//
// This exists because an agent editing an app cannot see it. `screencapture`
// returns the wallpaper without a Screen Recording grant — measured, and watched
// in a real Codex transcript, which took a black PNG as evidence and moved on —
// and TCC is not something a CLI can ask for.
//
// So the picture is made the same way the panel is: render `app.jsx` through the
// REAL reconciler into a §3.1 mutation batch, then hand that batch to the shell
// binary's `--snapshots` mode, which replays it through the real ProtocolEngine
// and ProtocolRenderer into a PNG. No running shell, no permissions, no screen.
// What comes out is not a mock of the app, it is the app — the only things it
// cannot show are the parts that need a live host (a monitor's data, a hover).

import { basename, dirname, join, resolve } from "node:path";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { InMemorySink, type Mutation } from "./render/mutations";
import { createAppSession } from "./render/session";
import { loadReactRuntime } from "./render/runtime";
import { sanitizeAppMeta } from "./worker/meta";

/** One app's snapshot batch — the shape `LedgeShell --snapshots` reads. */
export interface CommitDump {
  app: string;
  name: string;
  icon: string;
  order: number;
  panel?: unknown;
  mutations: Mutation[];
}

export interface RenderOptions {
  /** Absolute path to the app's `app.jsx`. */
  entryPath: string;
  /** Position in the strip; only affects which icon is highlighted. */
  order?: number;
  /** Press the N-th clickable node (0-based, mount order) and append the commit
   * that re-render produces — how a page reachable only by interacting gets
   * rendered at all. */
  click?: number | null;
}

/**
 * Mount an app once and return its commit batch.
 *
 * The module body runs (so top-level work happens) but `monitor` does not: this
 * is the app's first frame, with its default props, which is what an author is
 * checking when they ask what it looks like.
 */
export async function renderAppCommit(options: RenderOptions): Promise<CommitDump> {
  const entryPath = resolve(options.entryPath);
  const appId = basename(dirname(entryPath));
  const module = (await import(entryPath)) as {
    default?: (props: Record<string, unknown>) => unknown;
    meta?: unknown;
  };
  if (typeof module.default !== "function") {
    throw new Error(`${entryPath} has no default-exported component`);
  }
  // The same sanitizer the worker runs before posting `meta` (spec §6), so the
  // snapshot's catalog row is byte-for-byte the row a live host would publish.
  const meta = sanitizeAppMeta(module.meta);

  const sink = new InMemorySink();
  // React from the apps root, same as in a worker — one instance, resolved from
  // disk (see src/render/runtime.ts).
  const runtime = await loadReactRuntime(dirname(dirname(entryPath)));
  const session = createAppSession(module.default as never, sink, runtime);

  const mount = sink.commits[0];
  if (!mount) throw new Error(`${entryPath} rendered no commit`);

  if (options.click !== null && options.click !== undefined) {
    // `onClick: true` is how a handler crosses the wire (§5), so the mount batch
    // is also the list of what the user could have pressed.
    const clickable = mount.filter(
      (mutation) => mutation.op === "create" && mutation.props.onClick === true,
    );
    const target = clickable[options.click];
    if (!target || target.op !== "create") {
      throw new Error(
        `--click ${options.click}: this app has ${clickable.length} clickable nodes`,
      );
    }
    if (!session.dispatchEvent(target.id, "click", {})) {
      throw new Error(`--click ${options.click}: node ${target.id} has no handler`);
    }
  }

  return {
    app: appId,
    name: meta.name ?? appId,
    icon: meta.icon ?? "sf:square.dashed",
    order: options.order ?? 0,
    ...(meta.panel ? { panel: meta.panel } : {}),
    // Concatenated rather than kept apart: §3.1 applies mutations in array order
    // and validates the lot, so "mount, then this" is exactly what a live shell
    // sees one envelope later.
    mutations: sink.commits.flat(),
  };
}

/**
 * Where the shell binary is.
 *
 * Installed, the CLI shim is next to it and says so outright (`LEDGE_SHELL_BIN`).
 * In a checkout there is no bundle, so the build products are tried in place —
 * which is also the arrangement the snapshot scripts already use.
 */
export async function findShellBinary(hints: string[] = []): Promise<string | null> {
  const candidates = [
    process.env.LEDGE_SHELL_BIN,
    ...hints,
    // A repo checkout, from anywhere inside it.
    join(process.cwd(), "shell/.build/debug/LedgeShell"),
    join(process.cwd(), "shell/.build/release/LedgeShell"),
    join(process.cwd(), "../shell/.build/debug/LedgeShell"),
    join(process.cwd(), "../shell/.build/release/LedgeShell"),
    "/Applications/Ledge.app/Contents/MacOS/LedgeShell",
    join(process.env.HOME ?? "", "Applications/Ledge.app/Contents/MacOS/LedgeShell"),
  ].filter((path): path is string => Boolean(path));

  for (const candidate of candidates) {
    if (await Bun.file(candidate).exists()) return resolve(candidate);
  }
  return null;
}

export interface ShotOptions {
  appsRoot: string;
  appId: string;
  click?: number | null;
  /** Where the PNG goes. Defaults to a temp file the caller is told about. */
  outDir?: string;
  /** Overrides discovery; injected by tests so nothing runs a real binary. */
  shellBin?: string;
  run?: (bin: string, args: string[]) => Promise<{ ok: boolean; output: string }>;
}

async function runProcess(bin: string, args: string[]): Promise<{ ok: boolean; output: string }> {
  const proc = Bun.spawn([bin, ...args], { stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { ok: code === 0, output: `${out}${err}` };
}

/** Render one app to a PNG and return its path. */
export async function shootApp(options: ShotOptions): Promise<string> {
  const entryPath = join(options.appsRoot, options.appId, "app.jsx");
  if (!(await Bun.file(entryPath).exists())) {
    throw new Error(`no app.jsx at ${entryPath}`);
  }
  const shell = options.shellBin ?? (await findShellBinary());
  if (!shell) {
    throw new Error(
      "could not find the LedgeShell binary — set LEDGE_SHELL_BIN to it " +
        "(inside Ledge.app: Contents/MacOS/LedgeShell)",
    );
  }

  const dump = await renderAppCommit({ entryPath, click: options.click ?? null });
  const commitsDir = await mkdtemp(join(tmpdir(), "ledge-shot-"));
  const outDir = options.outDir ?? commitsDir;
  try {
    await Bun.write(join(commitsDir, `${options.appId}.json`), JSON.stringify(dump));
    const run = options.run ?? runProcess;
    const result = await run(shell, ["--snapshots", outDir, "--commits", commitsDir]);
    if (!result.ok) throw new Error(`the shell could not render it: ${result.output.trim()}`);

    // The shell also writes its own chrome surfaces (the idle pill, the [+]
    // card) into the output directory; the app's own PNG is the one named after
    // it. Checked rather than assumed, so a rename upstream is an error here
    // instead of a path to a file that does not exist.
    const png = join(outDir, `${options.appId}.png`);
    if (!(await Bun.file(png).exists())) {
      const wrote = (await readdir(outDir)).join(", ");
      throw new Error(`the shell wrote no ${options.appId}.png (it wrote: ${wrote || "nothing"})`);
    }
    return png;
  } finally {
    if (outDir !== commitsDir) await rm(commitsDir, { recursive: true, force: true });
  }
}
