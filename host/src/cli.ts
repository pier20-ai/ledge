// The `ledge` CLI (spec §8): small, composable, used by agents and humans alike.
//
// Deliberately file-based. The spec lists `new`, `reload`, `logs`, `status` and
// `open`; four of those are answerable from the filesystem, and answering them
// that way means the CLI works whether or not a host is running — which is
// exactly when you reach for `logs`. `reload` writes to `app.jsx`'s mtime and
// lets the watcher do its job (spec §7), so there is no second control channel
// to keep in sync with the first.
//
// `open` is the one verb that genuinely needs to reach a running shell, and it
// is deferred rather than guessed at: standing up an IPC surface for one verb
// buys a new failure mode and nothing else.

import { readFile, stat, utimes } from "node:fs/promises";
import { join, resolve } from "node:path";
import { DEFAULT_ROOT, scanApps } from "./registry";
import { scaffoldApp } from "./scaffold";
import { shootApp } from "./snapshot";

const USAGE = `ledge — the notch app platform

  ledge new <id>          scaffold an app and open it in the notch's world
  ledge list              installed apps, as a table
  ledge status            the same, as JSON (for agents)
  ledge reload <id>       touch the entry point; the watcher does the rest
  ledge logs <id>         what the app printed, and its last crash if any
  ledge shot <id>         render the app's panel to a PNG and print the path

Options:
  --apps-root <path>      default: ~/.ledge/apps
  --lines, -n <count>     console lines to show (logs; default 80)
  --click <n>             press the n-th clickable node first (shot)
  --out <path>            where to write the PNG (shot)
`;

interface Options {
  appsRoot: string;
  args: string[];
  /** How much of `console.log` to show. */
  lines: number;
  /** `shot`: which clickable node to press before rendering. */
  click: number | null;
  /** `shot`: where the PNG goes. */
  out?: string;
}

function parse(argv: string[]): Options {
  const args: string[] = [];
  let appsRoot = DEFAULT_ROOT;
  let lines = 80;
  let click: number | null = null;
  let out: string | undefined;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--apps-root") {
      appsRoot = argv[i + 1] ?? appsRoot;
      i += 1;
    } else if (arg === "--lines" || arg === "-n") {
      const value = Number(argv[i + 1]);
      if (Number.isFinite(value) && value > 0) lines = Math.floor(value);
      i += 1;
    } else if (arg === "--click") {
      const value = Number(argv[i + 1]);
      if (Number.isInteger(value) && value >= 0) click = value;
      i += 1;
    } else if (arg === "--out") {
      out = argv[i + 1] ? resolve(argv[i + 1]!) : undefined;
      i += 1;
    } else if (arg) {
      args.push(arg);
    }
  }
  // Absolute, always: a relative root reaches module resolution and resolves
  // against the process cwd instead (see render/runtime.ts).
  return { appsRoot: resolve(appsRoot), args, lines, click, out };
}

/** Exit code, so tests can drive `main` without killing the process. */
export async function main(argv: string[], log = console.log, err = console.error): Promise<number> {
  const { appsRoot, args, lines, click, out } = parse(argv);
  const [command, target] = args;

  switch (command) {
    case undefined:
    case "help":
    case "--help":
    case "-h":
      log(USAGE);
      return 0;

    case "new": {
      if (!target) {
        err("usage: ledge new <id>");
        return 1;
      }
      // The id IS the directory name (spec §6), so it has to survive being one.
      // Shared with the [+] surface, which derives an id instead of being told
      // one — see scaffold.ts.
      try {
        log(await scaffoldApp(appsRoot, target));
      } catch (error) {
        err(error instanceof Error ? error.message : String(error));
        return 1;
      }
      return 0;
    }

    case "list":
    case "status": {
      const apps = await scanApps(appsRoot);
      if (command === "status") {
        log(JSON.stringify(apps, null, 2));
        return 0;
      }
      if (apps.length === 0) {
        log(`no apps in ${appsRoot}`);
        return 0;
      }
      const width = Math.max(...apps.map((app) => app.id.length));
      for (const app of apps) {
        log(`${app.id.padEnd(width)}  ${app.name}`);
      }
      return 0;
    }

    case "reload": {
      if (!target) {
        err("usage: ledge reload <id>");
        return 1;
      }
      const entry = join(appsRoot, target, "app.jsx");
      if (!(await exists(entry))) {
        err(`no app.jsx at ${entry}`);
        return 1;
      }
      // Touch, don't rewrite: the file is the user's (and the agent's), and the
      // watcher keys on mtime, so there is nothing to gain from a round trip
      // through its contents — and a truncated write would be a real loss.
      const now = new Date();
      await utimes(entry, now, now);
      log(`touched ${entry}`);
      return 0;
    }

    case "logs": {
      if (!target) {
        err("usage: ledge logs <id> [--lines N]");
        return 1;
      }
      // Console output FIRST and crash last, because that is the order they
      // happened in and the order a tail reads: what the app printed, then the
      // thing that stopped it.
      //
      // This command used to print `crash.log` alone, which meant that for a
      // working app — the normal case, and the case an agent is in right after
      // making a change — it printed "it has not crashed" and nothing else.
      // Watching a real agent hit that, then hunt for logs with `find` and
      // `ps aux` and end up tailing the HOST's log, is why console.log exists.
      const appDir = join(appsRoot, target);
      if (!(await exists(appDir))) {
        err(`no app '${target}' in ${appsRoot}`);
        return 1;
      }
      const consolePath = join(appDir, "console.log");
      const crashPath = join(appDir, "crash.log");
      const hasConsole = await exists(consolePath);
      const hasCrash = await exists(crashPath);

      if (hasConsole) {
        const all = (await readFile(consolePath, "utf8")).split("\n");
        // Trailing blank from the final newline; dropping it keeps `--lines 20`
        // meaning twenty lines of output.
        if (all.at(-1) === "") all.pop();
        const tail = all.slice(-lines);
        if (all.length > tail.length) log(`[…${all.length - tail.length} earlier lines]`);
        log(tail.join("\n"));
      }
      if (hasCrash) {
        if (hasConsole) log("");
        log(await readFile(crashPath, "utf8"));
      }
      if (!hasConsole && !hasCrash) {
        // Both absences are informative, and they are different: nothing printed
        // is not the same as never started.
        log(
          `'${target}' has printed nothing and has not crashed.\n` +
            `If you expected output, add a console.log and \`ledge reload ${target}\`.`,
        );
      }
      return 0;
    }

    case "shot": {
      if (!target) {
        err("usage: ledge shot <id> [--click N] [--out <dir>]");
        return 1;
      }
      // Not a screenshot: the app is re-rendered through the real reconciler and
      // the real renderer, with no shell running and no screen-recording grant
      // involved (see src/snapshot.ts). It is the only way an agent editing an
      // app can look at what it wrote.
      try {
        log(await shootApp({ appsRoot, appId: target, click, outDir: out }));
      } catch (error) {
        err(error instanceof Error ? error.message : String(error));
        return 1;
      }
      return 0;
    }

    default:
      err(`unknown command '${command}'\n\n${USAGE}`);
      return 1;
  }
}

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

if (import.meta.main) {
  process.exit(await main(Bun.argv.slice(2)));
}
