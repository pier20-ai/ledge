// Commit mutations (spec §3.1). One React commit → one batch, applied by the
// shell in array order, all-or-nothing.

export type Props = Record<string, unknown>;

export type Mutation =
  | { op: "create"; id: number; kind: string; props: Props }
  | { op: "insert"; parent: number; id: number; before: number | null }
  | { op: "update"; id: number; props: Props }
  | { op: "remove"; id: number }
  | { op: "setRoot"; id: number };

/** Where commit batches land. The worker sends them to the host multiplexer;
 * tests use an in-memory sink. */
export interface MutationSink {
  commit(mutations: Mutation[]): void;
}

export class InMemorySink implements MutationSink {
  readonly commits: Mutation[][] = [];

  commit(mutations: Mutation[]): void {
    this.commits.push(mutations);
  }

  /** All mutations across commits, flattened, for shape assertions. */
  get all(): Mutation[] {
    return this.commits.flat();
  }
}
