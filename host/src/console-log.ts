// `console.log` from an app, on disk (spec §7).
//
// It exists because of a specific failure, watched in a real Codex transcript:
// the agent finished a change, wanted to know whether it worked, ran
// `ledge logs music`, was told the app had not crashed — and then spent three
// tool calls doing `find . -name '*log' -exec tail`, `ps aux | rg ledge`, and
// finally `tail -200 ~/.ledge/host.log`, which is the HOST's log and not the
// app's. The app had been printing exactly what it wanted to know the whole
// time, into a ring buffer in memory that only ever reached disk if the app
// crashed.
//
// So: an app's console output goes to `console.log` in its own folder, always,
// crash or no crash. It is the one file an agent can tail to answer "did my
// change do anything", which is the question it asks after every edit.
//
// Two properties matter more than throughput:
//
//   * **Bounded.** A monitor that logs every second, left running for a week, is
//     otherwise a disk-filling bug in a file nobody looks at. Trimmed to the
//     tail, which is the half anyone reads.
//   * **Non-blocking.** Writes are batched behind a short debounce, so an app in
//     a print loop costs one write per tick rather than one per line, and a
//     write that fails is a logged nuisance rather than an app-level failure.

import { appendFile, stat, writeFile } from "node:fs/promises";

/** Trim once the file passes this; the tail below is what survives. */
export const MAX_BYTES = 256 * 1024;
/** Kept when trimming — enough to hold the whole of a normal session. */
export const KEEP_BYTES = 128 * 1024;
/** Long enough to batch a print loop, short enough that a human tailing the
 * file sees output arrive as it happens. */
const FLUSH_MS = 150;

export interface ConsoleLogOptions {
  /** Absolute path to the app's `console.log`. */
  path: string;
  /** Reported, never thrown: logging must not be able to break an app. */
  onError?: (error: unknown) => void;
  /** Test seam — a timer that can be driven by hand. */
  schedule?: (fn: () => void, ms: number) => void;
}

export class ConsoleLog {
  private readonly path: string;
  private readonly onError: (error: unknown) => void;
  private readonly schedule: (fn: () => void, ms: number) => void;
  private buffer: string[] = [];
  /** The tail of the write chain — writes are serialized through it, so two
   * flushes can never interleave an append with a trim. */
  private flushing: Promise<void> = Promise.resolve();
  private scheduled = false;

  constructor(options: ConsoleLogOptions) {
    this.path = options.path;
    this.onError = options.onError ?? (() => {});
    this.schedule = options.schedule ?? ((fn, ms) => void setTimeout(fn, ms).unref?.());
  }

  /** Queue one already-formatted line (`log: hello`). */
  write(line: string): void {
    this.buffer.push(line);
    if (this.scheduled) return;
    this.scheduled = true;
    this.schedule(() => {
      this.scheduled = false;
      void this.flush();
    }, FLUSH_MS);
  }

  /**
   * Write everything queued, and everything that queues up behind it.
   *
   * Awaiting this has to mean "the lines I wrote are on disk", which is why it
   * joins an in-flight write rather than returning early when one is running:
   * a `flush()` that silently declined to wait is a test that reads an empty
   * file and a shutdown that loses the last thing an app said.
   */
  flush(): Promise<void> {
    this.flushing = this.flushing.then(() => this.drain());
    return this.flushing;
  }

  private async drain(): Promise<void> {
    while (this.buffer.length > 0) {
      const pending = this.buffer;
      this.buffer = [];
      try {
        await appendFile(this.path, `${pending.join("\n")}\n`);
        await this.trim();
      } catch (error) {
        this.onError(error);
      }
    }
  }

  /**
   * Mark a new run. A reload is the boundary an agent reads against — "did my
   * change do anything" means "since the reload" — and without a marker the
   * file is one undifferentiated stream.
   */
  mark(label: string): void {
    this.write(`--- ${label} ---`);
  }

  /** Keep the tail once the file grows past the cap. Whole lines only: half a
   * line at the top of a log reads as corruption. */
  private async trim(): Promise<void> {
    let size: number;
    try {
      size = (await stat(this.path)).size;
    } catch {
      return;
    }
    if (size <= MAX_BYTES) return;
    const text = await Bun.file(this.path).text();
    const tail = text.slice(-KEEP_BYTES);
    const start = tail.indexOf("\n");
    await writeFile(this.path, `[…earlier output trimmed]\n${tail.slice(start + 1)}`);
  }
}
