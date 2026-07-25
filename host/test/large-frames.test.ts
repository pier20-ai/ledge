import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ShellConnection, type ShellSession } from "../src/connection";
import { FakeShell } from "../src/fakes/fake-shell";

// Regression: a macOS unix socket takes ~8 KiB per write() call, and Bun
// reports the partial count rather than buffering the rest. Before the
// FrameWriter, any frame past that ceiling was truncated mid-stream — the
// receiver read body bytes as the next frame's length and closed the
// connection (an unbounded reconnect loop in production). A real stocks-grid
// mount was 10 467 bytes; chess is far bigger. These tests push frames well
// past the ceiling in both directions over a real unix socket.

function tempSocketPath(): string {
  return join(tmpdir(), `ledge-large-${crypto.randomUUID().slice(0, 8)}.sock`);
}

/** A payload whose framed size is ~`bytes`. */
function bulkyPayload(bytes: number): Record<string, unknown> {
  return { blob: "x".repeat(bytes) };
}

let cleanup: Array<() => void> = [];
afterEach(async () => {
  for (const fn of cleanup) fn();
  cleanup = [];
  await Bun.sleep(10);
});

describe("frames larger than one socket write", () => {
  test("host → shell: a ~200 KiB envelope arrives intact and the connection survives", async () => {
    const socketPath = tempSocketPath();
    const shell = new FakeShell({ socketPath });
    shell.start();
    cleanup.push(() => shell.stop());

    let readySession: ShellSession | null = null;
    const closes: string[] = [];
    const connection = new ShellConnection(
      { socketPath, hostVersion: "test", reconnect: false },
      {
        onReady: (session) => {
          readySession = session;
          session.send("bulk", "commit", bulkyPayload(200_000));
          // A small frame right behind the big one proves ordering holds
          // across the queued remainder.
          session.send("bulk", "commit", { after: true });
        },
        onEnvelope: () => {},
        onClose: (reason) => closes.push(reason),
      },
    );
    connection.start();
    cleanup.push(() => connection.stop());

    const big = await shell.waitFor(
      (e) => e.type === "commit" && typeof e.payload.blob === "string",
      5000,
    );
    expect((big.payload.blob as string).length).toBe(200_000);

    const follower = await shell.waitFor(
      (e) => e.type === "commit" && e.payload.after === true,
      5000,
    );
    expect(follower.seq).toBeGreaterThan(big.seq);
    expect(readySession).not.toBeNull();
    expect(closes).toEqual([]);
  }, 15000);

  test("shell → host: a ~200 KiB injected frame arrives intact", async () => {
    const socketPath = tempSocketPath();
    const shell = new FakeShell({ socketPath });
    shell.start();
    cleanup.push(() => shell.stop());

    const box: { received: string | null } = { received: null };
    const connection = new ShellConnection(
      { socketPath, hostVersion: "test", reconnect: false },
      {
        onReady: () => {},
        onEnvelope: (_session, envelope) => {
          if (envelope.type === "commit" && typeof envelope.payload.blob === "string") {
            box.received = envelope.payload.blob as string;
          }
        },
        onClose: () => {},
      },
    );
    connection.start();
    cleanup.push(() => connection.stop());

    await shell.waitFor((e) => e.type === "hello");
    shell.send("bulk", "commit", bulkyPayload(200_000));

    const deadline = Date.now() + 5000;
    while (box.received === null && Date.now() < deadline) {
      await Bun.sleep(20);
    }
    expect(box.received?.length).toBe(200_000);
  }, 15000);
});
