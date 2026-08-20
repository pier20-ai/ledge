import { expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CodexClient, type CodexProcess, spawnCodex } from "../src/codex/client";

test("a JSON-RPC request that receives no reply times out", async () => {
  let exit: (code: number) => void = () => {};
  const process: CodexProcess = {
    write: () => {},
    onLine: () => {},
    onExit: (handler) => {
      exit = handler;
    },
    kill: () => exit(0),
  };
  const client = new CodexClient({
    spawn: () => process,
    requestTimeoutMs: 20,
  });

  await expect(client.initialize()).rejects.toThrow(/initialize timed out/);
  client.kill();
});

test("a noisy app-server cannot block on its stderr pipe", async () => {
  const root = await mkdtemp(join(tmpdir(), "ledge-codex-stderr-"));
  try {
    const script = join(root, "noisy-codex");
    await writeFile(
      script,
      [
        "#!/bin/sh",
        "i=0",
        "while [ \"$i\" -lt 2000 ]; do",
        "  printf 'codex diagnostic xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' >&2",
        "  i=$((i + 1))",
        "done",
        "",
      ].join("\n"),
      { mode: 0o755 },
    );

    const logs: string[] = [];
    const process = spawnCodex(script, (line) => logs.push(line));
    const code = await new Promise<number>((resolve) => process.onExit(resolve));

    expect(code).toBe(0);
    expect(logs.length).toBe(2000);
    expect(logs[0]).toContain("codex diagnostic");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}, 5000);
