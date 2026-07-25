import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { Envelope } from "../src/protocol/envelope";
import { ShellConnection, type ShellSession } from "../src/connection";
import { FakeShell } from "../src/fakes/fake-shell";
import { scanApps } from "../src/registry";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";

let cleanup: Array<() => void> = [];
afterEach(() => {
  for (const fn of cleanup) fn();
  cleanup = [];
});

function tempSocketPath(): string {
  return join(tmpdir(), `ledge-test-${crypto.randomUUID().slice(0, 8)}.sock`);
}

describe("hello exchange", () => {
  test("host connects, exchanges hellos, then sends catalog", async () => {
    const socketPath = tempSocketPath();
    const shell = new FakeShell({ socketPath });
    shell.start();
    cleanup.push(() => shell.stop());

    let readySession: ShellSession | null = null;
    const connection = new ShellConnection(
      { socketPath, hostVersion: "test", reconnect: false },
      {
        onReady: (session) => {
          readySession = session;
          session.send("", "catalog", { apps: [] });
        },
        onEnvelope: () => {},
        onClose: () => {},
      },
    );
    connection.start();
    cleanup.push(() => connection.stop());

    const hello = await shell.waitFor((e) => e.type === "hello");
    expect(hello.app).toBe("");
    expect(hello.payload.host).toBe("test");

    const catalog = await shell.waitFor((e) => e.type === "catalog");
    expect(catalog.seq).toBeGreaterThan(hello.seq);
    expect(readySession!.gen).toBe(1);
    expect(readySession!.screen.notchWidth).toBe(189);
  });

  test("frames injected by the shell reach the delegate after hello", async () => {
    const socketPath = tempSocketPath();
    const shell = new FakeShell({ socketPath });
    shell.start();
    cleanup.push(() => shell.stop());

    const received: Envelope[] = [];
    const connection = new ShellConnection(
      { socketPath, hostVersion: "test", reconnect: false },
      {
        onReady: () => {},
        onEnvelope: (_session, envelope) => received.push(envelope),
        onClose: () => {},
      },
    );
    connection.start();
    cleanup.push(() => connection.stop());

    await shell.waitFor((e) => e.type === "hello");
    shell.send("", "resyncRequest", { app: "stocks" });

    const deadline = Date.now() + 2000;
    while (received.length === 0 && Date.now() < deadline) {
      await Bun.sleep(20);
    }
    expect(received.map((e) => e.type)).toEqual(["resyncRequest"]);
  });

  test("reconnects with a fresh generation after a drop", async () => {
    const socketPath = tempSocketPath();
    const shell = new FakeShell({ socketPath });
    shell.start();
    cleanup.push(() => shell.stop());

    const gens: number[] = [];
    const connection = new ShellConnection(
      { socketPath, hostVersion: "test", minBackoffMs: 30, maxBackoffMs: 60 },
      {
        onReady: (session) => gens.push(session.gen),
        onEnvelope: () => {},
        onClose: () => {},
      },
    );
    connection.start();
    cleanup.push(() => connection.stop());

    await shell.waitFor((e) => e.type === "hello");
    shell.disconnect();

    const deadline = Date.now() + 3000;
    while (gens.length < 2 && Date.now() < deadline) {
      await Bun.sleep(25);
    }
    expect(gens).toEqual([1, 2]);
  });
});

describe("registry", () => {
  test("scans app folders containing app.jsx, skipping everything else", async () => {
    const root = await mkdtemp(join(tmpdir(), "ledge-apps-"));
    await mkdir(join(root, "stocks"));
    await writeFile(join(root, "stocks", "app.jsx"), "export default () => null");
    await mkdir(join(root, "empty-dir"));
    await mkdir(join(root, ".hidden"));
    await writeFile(join(root, "AGENTS.md"), "docs");

    const apps = await scanApps(root);
    expect(apps.map((a) => a.id)).toEqual(["stocks"]);
    expect(apps[0]!.name).toBe("Stocks");
    expect(apps[0]!.order).toBe(0);
  });

  test("returns empty for a missing root", async () => {
    expect(await scanApps("/nonexistent/ledge-root")).toEqual([]);
  });
});
