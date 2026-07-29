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

const USAGE = `ledge — the notch app platform

  ledge new <id>          scaffold an app and open it in the notch's world
  ledge list              installed apps, as a table
  ledge status            the same, as JSON (for agents)
  ledge reload <id>       touch the entry point; the watcher does the rest
  ledge logs <id>         the app's last crash and recent console output

Options:
  --apps-root <path>      default: ~/.ledge/apps
`;

interface Options {
  appsRoot: string;
  args: string[];
}

function parse(argv: string[]): Options {
  const args: string[] = [];
  let appsRoot = DEFAULT_ROOT;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--apps-root") {
      appsRoot = argv[i + 1] ?? appsRoot;
      i += 1;
    } else if (arg) {
      args.push(arg);
    }
  }
  // Absolute, always: a relative root reaches module resolution and resolves
  // against the process cwd instead (see render/runtime.ts).
  return { appsRoot: resolve(appsRoot), args };
}

/** Exit code, so tests can drive `main` without killing the process. */
export async function main(argv: string[], log = console.log, err = console.error): Promise<number> {
  const { appsRoot, args } = parse(argv);
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
        err("usage: ledge logs <id>");
        return 1;
      }
      const crash = join(appsRoot, target, "crash.log");
      if (!(await exists(crash))) {
        log(`no crash.log for '${target}' — it has not crashed since its last clean start`);
        return 0;
      }
      log(await readFile(crash, "utf8"));
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
