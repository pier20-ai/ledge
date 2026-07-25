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
  // Usage: bun src/host.ts [socketPath] [--apps-root <path>]
  const args = Bun.argv.slice(2);
  let socketPath: string | undefined;
  let appsRoot: string | undefined;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === "--apps-root") {
      appsRoot = args[i + 1];
      i += 1;
    } else if (!socketPath && arg && !arg.startsWith("--")) {
      socketPath = arg;
    }
  }
  void runHost({ socketPath, appsRoot });
}
