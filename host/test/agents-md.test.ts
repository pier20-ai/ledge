import { describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InMemorySink, type Mutation } from "../src/render/mutations";
import { loadReactRuntime } from "../src/render/runtime";
import { createAppSession } from "../src/render/session";
import type { mountApp } from "./helpers/react-runtime";

// AGENTS.md + REFERENCE.md are the platform's contract with the coding agents
// that write apps (spec §8). Their failure mode is silent and slow: a kind or a
// ctx call ships, nobody updates the docs, and from then on every agent writes
// apps as though the feature does not exist — or invents a plausible API that
// does not.
//
// So the docs are asserted against the SOURCE, the same way a new §5 kind
// without a fixture already fails the shell suite. This does not check that the
// prose is good; it checks that nothing is missing, which is the part that rots.
//
// COVERAGE IS ASSERTED ACROSS THE PAIR. AGENTS.md is the short orientation and
// REFERENCE.md is the API; which of them holds a given table is an editorial
// decision that should be free to change, but a name present in neither is a
// feature no agent will ever use. The split itself is checked separately, below
// — a reference nobody is pointed at is the same failure in a different place.

const HOST_DIR = join(import.meta.dir, "..");
const DOCS_DIR = join(HOST_DIR, "..", "protocol", "demo-apps");
const AGENTS_MD = join(DOCS_DIR, "AGENTS.md");
const REFERENCE_MD = join(DOCS_DIR, "REFERENCE.md");

const agents = await Bun.file(AGENTS_MD).text();
const reference = await Bun.file(REFERENCE_MD).text();
/** Both, for the coverage assertions — see the note above. */
const doc = `${agents}\n${reference}`;

/** Element names from the JSX vocabulary's `IntrinsicElements` block. */
async function intrinsicElements(): Promise<string[]> {
  const source = await Bun.file(join(HOST_DIR, "src", "ledge-jsx", "jsx-runtime.ts")).text();
  const block = /interface IntrinsicElements \{([\s\S]*?)\n  \}/.exec(source);
  if (!block?.[1]) throw new Error("could not find IntrinsicElements in jsx-runtime.ts");
  return [...block[1].matchAll(/^\s{4}([a-z][a-zA-Z]*):/gm)].map((match) => match[1]!);
}

/** Member names of an interface block in ctx.ts (methods and properties). */
async function ctxMembers(interfaceName: string): Promise<string[]> {
  const source = await Bun.file(join(HOST_DIR, "src", "worker", "ctx.ts")).text();
  const block = new RegExp(`export interface ${interfaceName} \\{([\\s\\S]*?)\\n\\}`).exec(source);
  if (!block?.[1]) throw new Error(`could not find interface ${interfaceName} in ctx.ts`);
  return [...block[1].matchAll(/^ {2}([a-z][a-zA-Z]*)[(?:]/gm)].map((match) => match[1]!);
}

describe("AGENTS.md tracks the real API", () => {
  test("every component kind is documented", async () => {
    const missing = (await intrinsicElements()).filter(
      // Documented in the component table as `| \`name\` |`.
      (kind) => !new RegExp(`\`${kind}\``).test(doc),
    );
    expect(missing).toEqual([]);
  });

  test("every ctx call is documented", async () => {
    const members = [
      ...(await ctxMembers("Ctx")),
      ...(await ctxMembers("AppleBridge")),
      ...(await ctxMembers("PlatformBridge")),
    ];
    // `apple` and `platform` are namespaces; their members are listed as
    // `ctx.apple.script` etc., so matching the bare name covers both forms.
    const missing = members.filter((name) => !doc.includes(name));
    expect(missing).toEqual([]);
  });

  // Documentation that does not run is documentation that is wrong. The `mini`
  // example originally showed `<mini>` as a sibling of the panel stack inside a
  // fragment, which renders TWO roots — the shell rejects the whole commit, so
  // an agent copying the snippet got a resync instead of a view. Nothing caught
  // it, because every test asked about the *implementation*.
  //
  // So the snippet is compiled and rendered here, and asserted against the rule
  // the shell actually enforces: exactly one root, with `mini` parented to it.
  test("the documented mini example renders a single valid root", async () => {
    const block = /```jsx\n(const NOTHING_PLAYING[\s\S]*?)```/.exec(doc);
    expect(block?.[1]).toBeTruthy();

    const dir = await mkdtemp(join(tmpdir(), "ledge-doc-"));
    try {
      // The apps root the snippet resolves react from, exactly as an app would.
      await symlink(join(HOST_DIR, "node_modules"), join(dir, "node_modules"));
      await mkdir(join(dir, "docapp"), { recursive: true });
      const file = join(dir, "docapp", "app.jsx");
      await Bun.write(file, `/** @jsxImportSource react */\n${block![1]}`);

      const module = (await import(file)) as {
        default: Parameters<typeof mountApp>[0];
      };
      const sink = new InMemorySink();
      createAppSession(module.default, sink, await loadReactRuntime(dir));

      const mutations = sink.commits[0] ?? [];
      const roots = mutations.filter((m) => m.op === "setRoot");
      // A fragment of siblings produces two — the bug this test exists for.
      expect(roots.length).toBe(1);

      const rootId = (roots[0] as Extract<Mutation, { op: "setRoot" }>).id;
      const mini = mutations.find((m) => m.op === "create" && m.kind === "mini");
      expect(mini).toBeTruthy();
      const miniId = (mini as Extract<Mutation, { op: "create" }>).id;

      // ShadowTree requires a zone kind to be a DIRECT child of the root.
      const insert = mutations.find(
        (m): m is Extract<Mutation, { op: "insert" }> => m.op === "insert" && m.id === miniId,
      );
      expect(insert?.parent).toBe(rootId);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  // The pair only works if the short half sends you to the long one. An agent
  // that never learns REFERENCE.md exists is an agent working from the
  // orientation alone, which is exactly the state that had one searching $HOME
  // for Swift sources.
  test("AGENTS.md stays short and points at the reference", () => {
    const lines = agents.split("\n").length;
    expect(lines).toBeLessThan(160);
    expect(agents).toContain("REFERENCE.md");
    // Not just a mention: a table of what is in it, by section.
    expect(agents).toMatch(/REFERENCE\.md.*Components/s);
  });

  test("the rules that break apps are stated", () => {
    // Each of these has actually cost someone a debugging session.
    // These belong in the half an agent always reads, not the lookup.
    expect(agents).toContain("@jsxImportSource react");
    expect(agents).toContain("crash.log");
    expect(doc).toContain("import.meta.dir");
    // The React single-instance rule (host/src/render/runtime.ts).
    expect(doc.toLowerCase()).toContain("same");
    expect(doc).toMatch(/useState of null|second copy|same React instance/i);
  });
});
