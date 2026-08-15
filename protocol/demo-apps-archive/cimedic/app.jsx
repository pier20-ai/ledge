/** @jsxImportSource react */
// CI Medic — watch a repo's GitHub Actions, and when one goes red, have the
// user's own agent read the failing log and say what broke
// (docs/design/app-ideas.md, agentic wave).
//
// The loop: `gh run list` every two minutes → a run id that is newly `failure`
// → `gh run view --log-failed` for the tail → **`ctx.agent`** with a
// `{ diagnosis, suggestion, confidence }` schema → a notification with
// [Rerun] [Open] plus `ctx.expand()`. While anything is red the collapsed notch
// carries "CI ✗ <workflow>"; all green releases it.
//
// Ledge never calls a model API (spec §8). `ctx.agent` spawns whatever agent
// CLI the user already installed, in this app's own folder, for one headless
// turn. No agent installed, or one already busy on this app's previous turn, is
// not an error — the incident card simply says the diagnosis is unavailable and
// the two buttons still work. A CI watcher whose value evaporates without an
// LLM would not be worth installing.
//
// ── Configuration ──────────────────────────────────────────────────────────
//
// `config.json`, next to this file (see `config.example.json`):
//
//     { "owner": "cli", "repo": "cli", "workflow": "CI" }
//
// `workflow` is optional and filters by workflow *name*. A missing, unreadable
// or incomplete config is not a crash and not an empty panel: it is a setup
// card naming the exact path to create. Same for `gh` itself — absent from
// PATH, or present but not authenticated, is a setup card that says which.
//
// ── Testing seam: LEDGE_GH_CMD ─────────────────────────────────────────────
//
// Every `gh` invocation goes through one command template read from
// **`LEDGE_GH_CMD`** (default: `gh`), parsed like a command line — whitespace
// separates, quotes group — and interpolated into `Bun.$` as an argv array:
//
//     LEDGE_GH_CMD="/path/to/fake-gh.sh" bun src/host.ts …
//
// This exists so a test, a demo, or a development run can drive the whole
// red-run → diagnose → rerun cycle off a fixture script instead of hammering
// the real GitHub API. It is the same seam `LEDGE_AGENT_CMD` gives the agent
// (host/src/agent.ts), for the same reason: verification should cost neither a
// rate limit nor a token.
//
// **The monitor never throws** (spec §6 rule 2). `gh` exiting nonzero, a
// truncated JSON payload, a network outage: each one ends in a status line and
// the last-known runs, never a crash-and-backoff loop.

export const meta = { name: "CI Medic", icon: "sf:stethoscope" };

// ---------------------------------------------------------------- constants

const POLL_MS = 2 * 60_000;
const CONFIG_PATH = `${import.meta.dir}/config.json`;
/** What `gh run view --log-failed` is trimmed to before it reaches the agent.
 * The tail is where the error is; the head is 4 000 lines of `Set up job`. */
const LOG_TAIL_BYTES = 4_000;
const RUN_LIMIT = 5;
const RUN_FIELDS =
  "databaseId,displayTitle,workflowName,headBranch,status,conclusion,url,createdAt,event";

/** The `gh` argv. Read once at module load — an env var that changes under a
 * running worker would make two passes disagree about what they are talking to. */
const GH = parseCommand(Bun.env.LEDGE_GH_CMD?.trim() || "gh");

/** Split a command template the way a person means it: whitespace separates,
 * quotes group. Deliberately NOT a shell — no globbing, no `&&` — matching
 * `parseCommand` in host/src/agent.ts, and for the same reason: an env var that
 * names a program should not also be an injection surface. */
function parseCommand(command) {
  const argv = [];
  let current = "";
  let quote = null;
  let started = false;
  for (const char of command) {
    if (quote) {
      if (char === quote) quote = null;
      else current += char;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      started = true;
      continue;
    }
    if (/\s/.test(char)) {
      if (started) argv.push(current);
      current = "";
      started = false;
      continue;
    }
    current += char;
    started = true;
  }
  if (started) argv.push(current);
  return argv.length > 0 ? argv : ["gh"];
}

// ---------------------------------------------------------------- config

/** Read and validate `config.json`. Returns `{ ok: false, reason }` rather than
 * throwing: a missing config is the normal state of a freshly installed app,
 * not an exception. Re-read every pass, so dropping the file in takes effect
 * without a reload. */
async function readConfig() {
  let raw;
  try {
    raw = await Bun.file(CONFIG_PATH).json();
  } catch (error) {
    const missing = !(await Bun.file(CONFIG_PATH).exists());
    return {
      ok: false,
      reason: missing ? "no config.json yet" : `config.json is not valid JSON (${error?.message ?? error})`,
    };
  }
  const owner = typeof raw?.owner === "string" ? raw.owner.trim() : "";
  const repo = typeof raw?.repo === "string" ? raw.repo.trim() : "";
  if (!owner || !repo) return { ok: false, reason: "config.json needs both \"owner\" and \"repo\"" };
  const workflow = typeof raw?.workflow === "string" && raw.workflow.trim() ? raw.workflow.trim() : null;
  return { ok: true, owner, repo, workflow, slug: `${owner}/${repo}` };
}

// ---------------------------------------------------------------- gh
//
// Three calls, all through `Bun.$` with the argv array interpolated, all
// `.nothrow()`: a nonzero `gh` is information, not an exception.

async function ghAvailable() {
  try {
    const result = await Bun.$`${GH} auth status`.nothrow().quiet();
    if (result.exitCode === 0) return { ok: true };
    const message = (result.stderr.toString() || result.stdout.toString()).trim();
    return {
      ok: false,
      reason: message.includes("not logged")
        ? "gh is installed but not authenticated — run `gh auth login`"
        : `gh auth status failed: ${firstLine(message) || `exit ${result.exitCode}`}`,
    };
  } catch (error) {
    // ENOENT: `gh` is not on PATH at all.
    return { ok: false, reason: `gh not found on PATH (${error?.message ?? error})` };
  }
}

async function listRuns(config) {
  const result = await Bun.$`${GH} run list --repo ${config.slug} --limit ${String(RUN_LIMIT)} --json ${RUN_FIELDS}`
    .nothrow()
    .quiet();
  if (result.exitCode !== 0) {
    throw new Error(firstLine(result.stderr.toString()) || `gh run list exited ${result.exitCode}`);
  }
  const parsed = JSON.parse(result.stdout.toString());
  if (!Array.isArray(parsed)) throw new Error("gh run list did not return a list");
  const runs = parsed.map(normalizeRun).filter((run) => run.id > 0);
  return config.workflow ? runs.filter((run) => run.workflow === config.workflow) : runs;
}

function normalizeRun(row) {
  return {
    id: Number(row?.databaseId ?? 0),
    title: String(row?.displayTitle ?? "").trim() || "(no title)",
    workflow: String(row?.workflowName ?? "").trim() || "workflow",
    branch: String(row?.headBranch ?? "").trim() || "—",
    status: String(row?.status ?? "").trim(),
    conclusion: String(row?.conclusion ?? "").trim(),
    url: String(row?.url ?? "").trim(),
    at: String(row?.createdAt ?? "").trim(),
  };
}

/** The failing job's log, tail-trimmed. `tail -c` rather than a JS slice
 * because the log can be tens of megabytes and there is no reason to bring all
 * of it into the worker's heap to throw 99 % of it away. */
async function failedLog(runId) {
  const result = await Bun.$`${GH} run view ${String(runId)} --log-failed | tail -c ${String(LOG_TAIL_BYTES)}`
    .nothrow()
    .quiet();
  const text = result.stdout.toString().trim();
  if (text) return text;
  // Logs expire, and a rerun in flight has none yet — both are "no log", not
  // a failure of this app.
  return "";
}

const firstLine = (text) => String(text).split("\n").find((line) => line.trim()) ?? "";

// ---------------------------------------------------------------- diagnosis

/** The schema `ctx.agent` appends to the prompt and parses the reply against
 * (host/src/agent.ts: one retry, then it gives up). */
const DIAGNOSIS_SCHEMA = {
  diagnosis: "string — one sentence naming what actually broke",
  suggestion: "string — one concrete next step",
  confidence: "number between 0 and 1",
};

/**
 * One headless turn of the user's own agent over the failing log. Never throws
 * and never rejects: `ctx.agent` answers `{ ok: false, error }` for a missing
 * CLI, a busy app (one turn per app at a time — a monitor must not queue turns
 * that each spend the user's money), a timeout or a nonzero exit, and every one
 * of those becomes "diagnosis unavailable" on the card.
 */
async function diagnose(ctx, run, log) {
  if (!log) return { available: false, note: "no log available for this run" };

  const prompt = [
    `A GitHub Actions run failed. Workflow "${run.workflow}" on branch "${run.branch}", commit "${run.title}".`,
    "This is the tail of the failing job's log:",
    "```",
    log,
    "```",
    "Say what actually broke and what to do about it. Be specific and short.",
  ].join("\n");

  const result = await ctx.agent(prompt, { schema: DIAGNOSIS_SCHEMA, timeoutMs: 90_000 });
  if (!result?.ok) {
    console.log(`agent: ${result?.error ?? "no result"}`);
    return { available: false, note: shortError(result?.error) };
  }

  const json = result.json ?? {};
  const diagnosis = typeof json.diagnosis === "string" ? json.diagnosis.trim() : "";
  if (!diagnosis) {
    // The turn succeeded but the shape did not; the raw text is still worth
    // more than nothing, so it becomes the diagnosis.
    const text = typeof result.text === "string" ? result.text.trim() : "";
    if (!text) return { available: false, note: "the agent replied with nothing" };
    return { available: true, diagnosis: text.slice(0, 300), suggestion: "", confidence: null };
  }
  return {
    available: true,
    diagnosis,
    suggestion: typeof json.suggestion === "string" ? json.suggestion.trim() : "",
    confidence: typeof json.confidence === "number" ? json.confidence : null,
  };
}

/** Turn `ctx.agent`'s error into something that fits on one line of a card. */
function shortError(error) {
  const text = String(error ?? "").trim();
  if (!text) return "the agent turn failed";
  if (text.includes("no agent CLI")) return "no agent CLI installed — install `claude`, or set LEDGE_AGENT_CMD";
  if (text.includes("busy")) return "the agent is busy with the previous run";
  if (text.includes("timed out")) return "the agent turn timed out";
  // ENOENT/posix_spawn is a misconfigured LEDGE_AGENT_CMD, and the raw spawn
  // error is a stack trace wearing a sentence's clothes.
  if (text.includes("ENOENT") || text.includes("posix_spawn")) {
    return "the configured agent command could not be run (check LEDGE_AGENT_CMD)";
  }
  return firstLine(text).slice(0, 160);
}

// ---------------------------------------------------------------- state

let ctxRef = null;
/** Run ids already announced. A run only produces one notification, ever. */
const announced = new Set();
let firstPassDone = false;
let runs = [];
let incident = null; // { run, diagnosis } — the red run on screen, or null
let setup = { reason: "starting…" }; // non-null while the app cannot do its job
let notificationId = 0;
let lastSignature = "";
let lastWing = "";

// ---------------------------------------------------------------- actions
//
// Both reach the component as props and both go out through `Bun.$` — a rerun
// is `gh`, and opening a run page is `open`, which is the platform doing what
// the platform does (spec §6: ctx carries only what the app's process cannot).

async function rerun() {
  if (!incident) return;
  const run = incident.run;
  console.log(`rerun -> ${run.id}`);
  const result = await Bun.$`${GH} run rerun ${String(run.id)}`.nothrow().quiet();
  if (result.exitCode === 0) {
    // A rerun makes the incident stale: the run is queued again, and the next
    // pass will report whatever it becomes.
    incident = { ...incident, rerunning: true };
    console.log(`rerun requested for ${run.id}`);
  } else {
    const message = firstLine(result.stderr.toString()) || `exit ${result.exitCode}`;
    incident = { ...incident, actionError: message };
    console.log(`rerun failed: ${message}`);
  }
  publish();
}

/** Named `openRun`, not `open`: `Bun.$\`open …\`` below is the macOS command,
 * and a JS function called `open` sitting next to it reads like a recursion
 * bug that it is not. */
async function openRun() {
  const url = incident?.run?.url;
  if (!url) return;
  console.log(`open -> ${url}`);
  await Bun.$`open ${url}`.nothrow().quiet();
}

const onRerun = () => void rerun();
const onOpen = () => void openRun();

/** App-level events (protocol/README.md — id 0): the notification's buttons.
 * `default` (a click on the banner body) just opens the panel — reading a
 * notification is not the same gesture as acting on it. */
export function onEvent(name, data, ctx) {
  if (name !== "notification") return;
  const id = Number(data?.id);
  const action = String(data?.action ?? "");
  if (id !== notificationId) {
    console.log(`notification #${id} ${action} — not the current incident`);
    return;
  }
  console.log(`notification #${id} -> ${action}`);
  if (action === "rerun") void rerun();
  else if (action === "open") void openRun();
  else ctx.expand();
}

// ---------------------------------------------------------------- publishing

function viewProps() {
  return {
    setup,
    runs,
    incident: incident
      ? {
          run: incident.run,
          diagnosis: incident.diagnosis,
          rerunning: incident.rerunning ?? false,
          actionError: incident.actionError ?? null,
        }
      : null,
    onRerun,
    onOpen,
  };
}

function signature(props) {
  return JSON.stringify([
    props.setup,
    props.runs.map((run) => [run.id, run.status, run.conclusion]),
    props.incident,
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

/** The collapsed notch: red only. A CI watcher that owns the notch when
 * everything passes is a CI watcher you turn off. */
function publishWing() {
  if (!ctxRef) return;
  const red = runs.find(isRed);
  const text = red ? `CI ✗ ${red.workflow}` : "";
  if (text === lastWing) return;
  lastWing = text;
  ctxRef.wing(text ? { text } : null);
  console.log(text ? `wing -> ${text}` : "wing released (all green)");
}

const isRed = (run) => run.conclusion === "failure" || run.conclusion === "timed_out";

// ---------------------------------------------------------------- monitor

export async function monitor(ctx) {
  try {
    ctxRef = ctx;

    const config = await readConfig();
    if (!config.ok) {
      setup = { reason: config.reason, path: CONFIG_PATH };
      publish();
      publishWing();
      await Bun.sleep(POLL_MS);
      return;
    }

    // Checked once per pass, not once per process: `gh auth login` in another
    // terminal should fix this app without restarting it.
    const gh = await ghAvailable();
    if (!gh.ok) {
      setup = { reason: gh.reason, path: CONFIG_PATH, repo: config.slug, gh: GH.join(" ") };
      publish();
      publishWing();
      await Bun.sleep(POLL_MS);
      return;
    }
    setup = null;

    runs = await listRuns(config);
    console.log(`${config.slug}: ${runs.length} runs, ${runs.filter(isRed).length} red`);

    // The newest failing run this pass. On the FIRST pass, older red runs are
    // marked as already-announced: a watcher that opens with three notifications
    // about last week is noise, but staying silent about a repo that is red
    // right now would make the app useless the moment you install it.
    const red = runs.filter(isRed);
    if (!firstPassDone) {
      firstPassDone = true;
      for (const run of red.slice(1)) announced.add(run.id);
    }

    const fresh = red.find((run) => !announced.has(run.id));
    if (fresh) {
      announced.add(fresh.id);
      await raise(ctx, fresh);
    } else if (incident && !runs.some((run) => run.id === incident.run.id && isRed(run))) {
      // The run that was on screen is no longer red (a rerun went green, or it
      // fell off the list). Put the panel back to the run list.
      console.log(`incident ${incident.run.id} cleared`);
      incident = null;
    }

    publish();
    publishWing();
  } catch (error) {
    // Spec §6 rule 2: a `gh` blip must not become a crash loop.
    console.log(`monitor pass failed: ${error?.stack ?? error}`);
    setup = { reason: firstLine(error?.message ?? String(error)), path: CONFIG_PATH, transient: true };
    publish();
  }
  await Bun.sleep(POLL_MS);
}

/** A newly red run: pull the log, ask the agent, put it on screen, notify. */
async function raise(ctx, run) {
  console.log(`RED: #${run.id} ${run.workflow} on ${run.branch} — ${run.title}`);
  // `pending` is the flag the panel spins on. It has to be an explicit field:
  // the card cannot tell "the agent is thinking" from "the agent is not going to
  // answer" by looking at `note`, and sniffing the copy for it would make the
  // spinner a property of a string.
  incident = { run, diagnosis: { available: false, pending: true, note: "diagnosing…" } };
  publish();

  const log = await failedLog(run.id);
  const diagnosis = await diagnose(ctx, run, log);
  // A rerun pressed from the banner while the agent was thinking already
  // replaced the incident; do not stomp it with a stale diagnosis.
  if (incident?.run.id === run.id) {
    incident = { ...incident, diagnosis };
    publish();
  }

  notificationId = ctx.notify(
    diagnosis.available ? diagnosis.diagnosis.slice(0, 160) : `${run.workflow} failed on ${run.branch}`,
    {
      title: `CI ✗ ${run.workflow}`,
      attention: true,
      actions: [
        { id: "rerun", label: "Rerun" },
        { id: "open", label: "Open" },
      ],
    },
  );
  ctx.expand();
}

// ---------------------------------------------------------------- the panel

/** The friendly dead end. It names the exact path to create and the exact
 * shape to put in it — a setup card that says "not configured" and stops is a
 * card that makes the user go and read the source. */
function Setup({ setup: state }) {
  return (
    <stack axis="v" pad={14} gap={10}>
      {/* Panel wing (spec §5) in place of a title row: the shell names the app,
          and the status this row carried used to sit under the camera. */}
      <wing side="left">
        <text content="●" size="xs" color="secondary" />
        <text content="setup" size="s" weight="semibold" color="accent" />
      </wing>

      <stack axis="v" gap={8} pad={12} fill="raised" stroke="hairline" radius={12}>
        <stack axis="h" gap={8}>
          <image src="sf:stethoscope" w={18} h={18} />
          <text content={state.reason ?? "not configured"} size="s" weight="semibold" truncate />
        </stack>

        <text content="Create this file:" size="xs" weight="medium" color="secondary" />
        <stack pad={8} radius={8} fill="black">
          <text content={state.path ?? "config.json"} size="xs" color="cyan" mono truncate />
        </stack>

        <text content="with:" size="xs" weight="medium" color="secondary" />
        <stack pad={8} radius={8} fill="black">
          <text
            content={'{ "owner": "cli", "repo": "cli", "workflow": "CI" }'}
            size="xs"
            color="green"
            mono
            truncate
          />
        </stack>

        <text
          content={'"workflow" is optional. gh must be installed and authenticated (gh auth login).'}
          size="xs"
          color="tertiary"
        />
      </stack>

      {state.repo ? (
        <stack axis="h" gap={6}>
          <text content={state.repo} size="xs" weight="medium" color="tertiary" mono truncate />
          <spacer />
          <text content={state.gh ?? "gh"} size="xs" weight="medium" color="tertiary" mono />
        </stack>
      ) : null}
    </stack>
  );
}

/** The incident: what broke, what the agent thinks, and the two things a person
 * would do about it. */
function Incident({ incident: state, onRerun, onOpen }) {
  const run = state.run;
  const diagnosis = state.diagnosis ?? {};
  const confidence =
    typeof diagnosis.confidence === "number"
      ? `${Math.round(Math.max(0, Math.min(1, diagnosis.confidence)) * 100)}% sure`
      : null;

  return (
    <stack axis="v" pad={14} gap={10}>
      <wing side="left">
        <text content="●" size="xs" color="red" />
        <text
          content={state.rerunning ? "rerunning…" : "failed"}
          size="s"
          weight="semibold"
          color={state.rerunning ? "accent" : "red"}
        />
      </wing>

      <stack axis="v" gap={6} pad={12} fill="redTint" stroke="red" radius={12}>
        <stack axis="h" gap={8}>
          <text content={run.workflow} size="m" weight="bold" truncate />
          <spacer />
          <text content={`#${run.id}`} size="xs" weight="medium" color="tertiary" mono />
        </stack>
        <text content={run.title} size="s" color="secondary" truncate />
        <stack axis="h" gap={6}>
          <image src="sf:arrow.triangle.branch" w={12} h={12} />
          <text content={run.branch} size="xs" weight="semibold" color="violet" mono truncate />
          <spacer />
        </stack>
      </stack>

      {/* The agent's turn, or an honest absence of one. `maxLines` is what makes
          prose possible here (§5, law L7): the shell wraps and then tail-truncates
          at the line count, which caps the card's height so a chatty agent cannot
          push the buttons off the panel. */}
      <stack axis="v" gap={6} pad={12} fill="raised" stroke="hairline" radius={12}>
        <stack axis="h" gap={7}>
          <text content="Diagnosis" size="xs" weight="bold" color="secondary" />
          <spacer />
          {/* While `ctx.agent` is running there is nothing to label yet, so the
              spinner takes the tag's place rather than the card saying
              "unavailable" about a turn that has not finished (D6: spinner —
              cimedic while ctx.agent runs). */}
          {diagnosis.pending ? (
            <spinner />
          ) : (
            <text
              content={diagnosis.available ? (confidence ?? "agent") : "unavailable"}
              size="xs"
              weight="medium"
              color={diagnosis.available ? "cyan" : "tertiary"}
              mono
            />
          )}
        </stack>
        {diagnosis.available ? (
          <stack axis="v" gap={6}>
            <text content={diagnosis.diagnosis} size="s" weight="medium" maxLines={3} />
            {diagnosis.suggestion ? (
              // align="start" (§5) so the arrow sits on the suggestion's FIRST
              // line rather than floating at the middle of a wrapped block.
              <stack axis="h" gap={7} align="start">
                <text content="→" size="s" weight="bold" color="green" />
                <text content={diagnosis.suggestion} size="s" color="secondary" maxLines={3} />
              </stack>
            ) : null}
          </stack>
        ) : (
          <text
            content={diagnosis.note ?? "diagnosis unavailable"}
            size="s"
            color="tertiary"
            maxLines={2}
          />
        )}
      </stack>

      {state.actionError ? (
        <text content={state.actionError} size="xs" weight="medium" color="red" truncate />
      ) : null}

      <stack axis="h" gap={8} distribute="equal">
        <button label="Rerun" icon="sf:arrow.clockwise" variant="accent" onClick={() => onRerun?.()} />
        <button label="Open" icon="sf:arrow.up.right.square" variant="glass" onClick={() => onOpen?.()} />
      </stack>
    </stack>
  );
}

const RUN_TONE = {
  success: { color: "green", mark: "✓" },
  failure: { color: "red", mark: "✗" },
  timed_out: { color: "red", mark: "✗" },
  cancelled: { color: "secondary", mark: "•" },
  skipped: { color: "secondary", mark: "•" },
};

function RunRow({ run }) {
  const tone = run.status !== "completed" ? { color: "accent", mark: "◐" } : (RUN_TONE[run.conclusion] ?? RUN_TONE.cancelled);
  return (
    <stack axis="h" gap={8} pad={8} fill="raised" stroke="hairline" radius={10}>
      <text content={tone.mark} size="s" weight="bold" color={tone.color} mono />
      <stack axis="v" gap={2}>
        <text content={run.title} size="s" weight="semibold" truncate />
        <text content={`${run.workflow} · ${run.branch}`} size="xs" color="tertiary" truncate />
      </stack>
      <spacer />
    </stack>
  );
}

// Mount state (what scripts/snapshot-demos.sh dumps — the monitor never runs
// there, and nothing is read from disk at import): the setup card, which is
// also genuinely what a freshly installed, unconfigured CI Medic shows.
export default function CIMedic({
  setup: state = { reason: "no config.json yet", path: CONFIG_PATH },
  runs: rows = [],
  incident: current = null,
  onRerun,
  onOpen,
}) {
  if (state) return <Setup setup={state} />;
  if (current) return <Incident incident={current} onRerun={onRerun} onOpen={onOpen} />;

  const green = rows.filter((run) => run.conclusion === "success").length;
  return (
    <stack axis="v" pad={14} gap={8}>
      <wing side="left">
        <text content="●" size="xs" color="green" />
        <text content={`${green}/${rows.length} green`} size="s" weight="semibold" color="secondary" />
      </wing>

      {rows.length === 0 ? (
        <stack axis="h" pad={12} fill="raised" stroke="hairline" radius={10}>
          <spacer />
          <text content="No runs yet" size="s" weight="medium" color="secondary" />
          <spacer />
        </stack>
      ) : (
        rows.map((run) => <RunRow key={run.id} run={run} />)
      )}
    </stack>
  );
}
