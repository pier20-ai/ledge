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
import { createCtx } from "./worker/ctx";
import { sanitizeAppMeta } from "./worker/meta";
import type { WingSpec } from "./worker/wing";

/** One app's snapshot batch — the shape `LedgeShell --snapshots` reads. */
export interface CommitDump {
  app: string;
  name: string;
  icon: string;
  order: number;
  panel?: unknown;
  mutations: Mutation[];
  /** `--wing`: the collapsed-notch surface this app asked for (spec §3.3), and
   * the last frame it drew into it (§3.4). Absent unless `--wing` was passed and
   * the app produced one. */
  wing?: WingSpec;
  wingOps?: unknown[];
  /** Every canvas the app painted during the same window, keyed by node id
   * (§3.4). The shell replays these as `draw` envelopes after the commit, which
   * is the only way a **panel** canvas is visible to a snapshot at all: three of
   * the nine demo apps (weather, chess, blocks) are a canvas and nothing else,
   * and their whole signature used to render as an empty well.
   *
   * Keys are strings because JSON object keys are. Same capture as `wingOps` —
   * that field is just this map's one interesting entry, kept for the pill. */
  draws?: Record<string, unknown[]>;
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
  /** Mount with these props instead of the component's own defaults — the
   * `--props` flag. Every data-driven app otherwise needs a throwaway preview
   * module to be seen in any state but empty. */
  props?: Record<string, unknown>;
  /** Run `monitor(ctx)` briefly against a recording `ctx` and keep the first
   * wing/draw it produces (`--wing`). */
  wing?: boolean;
  /** How long to let the monitor and its timers run under `--wing`. */
  wingMs?: number;
}

/** Default `--wing` window: long enough for a monitor's first pass and a few
 * frames of whatever interval it starts, short enough to stay a dev tool. */
const WING_WINDOW_MS = 400;

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
    monitor?: unknown;
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
  const session = createAppSession(module.default as never, sink, runtime, options.props ?? {});

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

  const captured = options.wing
    ? await captureWing({
        monitor: module.monitor,
        session,
        mount,
        windowMs: options.wingMs ?? WING_WINDOW_MS,
      })
    : null;

  // Concatenated rather than kept apart: §3.1 applies mutations in array order
  // and validates the lot, so "mount, then this" is exactly what a live shell
  // sees one envelope later.
  const mutations = sink.commits.flat();
  // Frames are kept only for canvases that exist in the batch being replayed,
  // and that has to be measured against **every** commit rather than the mount:
  // a monitor that calls `ctx.update` re-renders the app, and the canvas an
  // empty-state app grows on its second render is exactly the one worth seeing
  // (weather's pane arrives that way).
  const draws = filterDraws(captured?.frames, mutations);

  return {
    app: appId,
    name: meta.name ?? appId,
    icon: meta.icon ?? "sf:square.dashed",
    order: options.order ?? 0,
    ...(meta.panel ? { panel: meta.panel } : {}),
    ...(captured?.wing ? { wing: captured.wing } : {}),
    ...(captured?.ops ? { wingOps: captured.ops } : {}),
    ...(Object.keys(draws).length > 0 ? { draws } : {}),
    mutations,
  };
}

/** Keep the frames whose canvas is in the tree, keyed by id (JSON keys are
 * strings). A draw at an id the app has since unmounted is dropped here rather
 * than replayed at nothing. */
function filterDraws(
  frames: Map<number, unknown[]> | undefined,
  mutations: Mutation[],
): Record<string, unknown[]> {
  if (!frames) return {};
  const canvases = new Set<number>();
  for (const mutation of mutations) {
    if (mutation.op === "create" && mutation.kind === "canvas") canvases.add(mutation.id);
    if (mutation.op === "remove") canvases.delete(mutation.id);
  }
  const draws: Record<string, unknown[]> = {};
  for (const [id, ops] of frames) {
    if (canvases.has(id)) draws[String(id)] = ops;
  }
  return draws;
}

/**
 * `--wing`: run the app's monitor for a moment and keep what it asked the notch
 * for — **and every frame it painted while doing so**.
 *
 * The second half is what makes a canvas app reviewable. A `canvas` node's
 * pixels never appear in a commit: they arrive as §3.4 `draw` frames, out of a
 * loop the monitor starts. So a snapshot of weather, chess or blocks used to be
 * an empty slab — the app's entire signature, missing, in the one picture that
 * is supposed to be evidence. This already ran the monitor and already recorded
 * every canvas's ops; it simply threw all but the wing's away.
 *
 * Latest frame wins per canvas, which is the coalescing rule the shell applies
 * anyway (§3.4) and the right one here: what a snapshot wants is the app's
 * settled state, not its first frame.
 *
 * An app's *signature* — the thing it puts in the collapsed pill — was until now
 * the one surface a snapshot could not show, because a wing is never in the
 * mount tree: it is published imperatively from a monitor or the frame loop the
 * monitor starts. So this runs the real `monitor(ctx)` against the real
 * `createCtx`, with an io that records instead of posting, and lets it and its
 * timers run for a fixed window.
 *
 * Deliberately best-effort, and deliberately not awaited: most monitors park on
 * `await new Promise(() => {})` and never return, and a bridge call (`ctx.apple`,
 * `ctx.platform`) never settles here because there is no host to answer it. An
 * app that gets no further than its first `await` simply produces no wing, and
 * the caller says so.
 *
 * The `ctx.draw` fallback is what makes it useful for apps whose wing is only
 * held while something is playing: if the app drew a frame into a `canvas` node
 * but never called `ctx.wing`, that node is put in the right wing at its own
 * declared width — which is exactly where the app would mirror it.
 */
async function captureWing(options: {
  monitor: unknown;
  session: { update(patch: Record<string, unknown>): void };
  mount: Mutation[];
  windowMs: number;
}): Promise<{
  wing: WingSpec | null;
  ops: unknown[] | null;
  frames: Map<number, unknown[]>;
}> {
  if (typeof options.monitor !== "function") {
    return { wing: null, ops: null, frames: new Map() };
  }

  let wing: WingSpec | null = null;
  const frames = new Map<number, unknown[]>();
  const { ctx } = createCtx({
    post: (msg) => {
      if (msg.type === "wing") wing = msg.wing;
      else if (msg.type === "draw") frames.set(msg.id, msg.ops);
    },
    update: (patch) => options.session.update(patch),
  });

  // Fire and forget: a monitor that parks forever is the normal case (spec §6
  // rule 1 pacing lives inside it), and a throw is the app's business, not this
  // tool's.
  void (async () => {
    try {
      await (options.monitor as (ctx: unknown) => unknown)(ctx);
    } catch {
      /* an app that crashes without a host is still allowed to have drawn */
    }
  })();
  await Bun.sleep(options.windowMs);

  // No wing, but it drew something: put that canvas in the right wing itself.
  if (!wing && frames.size > 0) {
    const [id] = [...frames.keys()];
    const node = options.mount.find(
      (mutation) => mutation.op === "create" && mutation.id === id && mutation.kind === "canvas",
    );
    const width = node && node.op === "create" ? Number(node.props.w) : 0;
    if (width > 0) wing = { canvas: { id: id as number, w: Math.round(width) } };
  }

  const canvasId = (wing as WingSpec | null)?.canvas?.id;
  const ops = canvasId === undefined ? null : (frames.get(canvasId) ?? null);
  // Every canvas the app painted, not only the pill's — the panel's wells are
  // the whole point. The caller decides which of them are still in the tree.
  return { wing, ops, frames };
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
