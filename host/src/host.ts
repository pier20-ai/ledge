// Host entry: connect to the shell, and drive the full pipeline — registry →
// worker supervision → the router (multiplexer). The Router owns per-app worker
// supervision, crash/backoff, hot reload, and all envelope translation; this
// file just wires it to the ShellConnection's lifecycle.

import { mkdir } from "node:fs/promises";
import { join } from "node:path";
import { ShellConnection } from "./connection";
import { DEFAULT_ROOT } from "./registry";
import { Router } from "./router";

const HOST_VERSION = "0.4.0";

export interface RunHostOptions {
  socketPath?: string;
  appsRoot?: string;
}

/**
 * Exit when stdin reaches EOF — the shell's half of shutdown, and the only half
 * that is actually reliable.
 *
 * `Ledge.app` launches the host as a child with a pipe on stdin and never writes
 * to it. When the shell exits the pipe's write end closes and this resolves, so
 * the host (and every app worker, and every subprocess an app spawned — chess
 * runs Stockfish) goes down with it.
 *
 * `applicationWillTerminate` on the Swift side is NOT sufficient: it does not run
 * on SIGKILL or on a crash, which is exactly when an orphaned host is most likely
 * and most annoying — it holds the socket and fights the next launch. A closed
 * pipe is delivered by the kernel no matter how the parent died.
 */
async function exitOnStdinEOF(stop: () => void): Promise<void> {
  try {
    // Reading to completion IS the wait; we never expect any actual bytes.
    for await (const _chunk of Bun.stdin.stream()) {
      // Ignore input. A parent that writes to us is not part of the contract.
    }
  } catch {
    // A broken pipe is the same signal as a clean EOF: the parent is gone.
  }
  console.log("[ledge-host] parent closed stdin — shutting down");
  stop();
  process.exit(0);
}

export interface RunningHost {
  connection: ShellConnection;
  router: Router;
  stop(): void;
}

export async function runHost(options: RunHostOptions = {}): Promise<RunningHost> {
  const ledgeDir = join(process.env.HOME ?? "~", ".ledge");
  const appsRoot = options.appsRoot ?? DEFAULT_ROOT;
  const socketPath = options.socketPath ?? join(ledgeDir, "ledge.sock");
  await mkdir(appsRoot, { recursive: true });

  const router = new Router({ appsRoot });

  const connection = new ShellConnection(
    { socketPath, hostVersion: HOST_VERSION },
    {
      onReady: (session) => {
        console.log(`[ledge-host] connected, gen ${session.gen}`);
        void router.bindSession(session);
      },
      onEnvelope: (session, envelope) => router.onEnvelope(session, envelope),
      onClose: (reason) => {
        console.log(`[ledge-host] disconnected: ${reason}`);
        router.clearSession();
      },
    },
  );
  connection.start();

  return {
    connection,
    router,
    stop: () => {
      connection.stop();
      router.shutdown();
    },
  };
}

if (import.meta.main) {
  // Usage: ledge [socketPath] [--apps-root <path>] [--exit-on-stdin-eof]
  const args = Bun.argv.slice(2);
  let socketPath: string | undefined;
  let appsRoot: string | undefined;
  let exitOnEOF = false;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--apps-root") {
      appsRoot = args[i + 1];
      i += 1;
    } else if (arg === "--exit-on-stdin-eof") {
      // Set by Ledge.app so the host cannot outlive the shell (see above).
      exitOnEOF = true;
    } else if (!socketPath && arg && !arg.startsWith("--")) {
      socketPath = arg;
    }
  }
  void runHost({ socketPath, appsRoot }).then((host) => {
    if (exitOnEOF) void exitOnStdinEOF(host.stop);
  });
}
