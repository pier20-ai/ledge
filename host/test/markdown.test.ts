import { describe, expect, test } from "bun:test";
// The editor's renderer, tested from the host suite on purpose: it is the one
// piece of the editor bundle whose behaviour is pure data in, data out, and a
// third test runner nobody remembers to run is worse than an import that
// reaches across a package boundary.
import { renderMarkdown } from "../../editor/src/markdown.js";

// What the builder surface does with agent output (editor/src/markdown.js).
//
// The property under test is never "does it match CommonMark" — it is "does the
// thing an agent actually emitted end up readable". Tables are the case that
// prompted this suite: a before/after table is how these models summarise a
// change, and rendered as a paragraph it arrives as a wall of pipes.

interface Element {
  type: string;
  props: { children?: unknown; className?: string };
}

const kinds = (blocks: unknown[]) => blocks.map((block) => (block as Element).type);

/** Every string anywhere in an element tree, in order. */
function text(node: unknown): string {
  if (node === null || node === undefined || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(text).join("");
  const element = node as Element;
  return text(element.props?.children);
}

/** All elements of a type, depth-first. */
function find(node: unknown, type: string): Element[] {
  if (node === null || typeof node !== "object") return [];
  if (Array.isArray(node)) return node.flatMap((child) => find(child, type));
  const element = node as Element;
  const here = element.type === type ? [element] : [];
  return here.concat(find(element.props?.children, type));
}

describe("markdown in the builder transcript", () => {
  test("a table becomes a table, not a paragraph of pipes", () => {
    // Verbatim from a real turn (the music app's artwork change).
    const blocks = renderMarkdown(
      [
        "| Before | After |",
        "| --- | --- |",
        "| Collapsed wing showed text only | Reuses the mini-player canvas |",
        "| Artwork edge was unframed | Added a subtle white outline |",
      ].join("\n"),
    );

    expect(blocks).toHaveLength(1);
    const table = find(blocks, "table");
    expect(table).toHaveLength(1);
    expect(find(blocks, "th").map(text)).toEqual(["Before", "After"]);
    const rows = find(find(blocks, "tbody"), "tr");
    expect(rows).toHaveLength(2);
    expect(find(rows[0], "td").map(text)).toEqual([
      "Collapsed wing showed text only",
      "Reuses the mini-player canvas",
    ]);
  });

  test("a ragged row is padded to the header rather than shifting the columns", () => {
    const blocks = renderMarkdown("| a | b | c |\n| --- | --- | --- |\n| 1 | 2 |");
    const cells = find(find(blocks, "tbody"), "td");
    expect(cells).toHaveLength(3);
    expect(cells.map(text)).toEqual(["1", "2", ""]);
  });

  test("a sentence containing a pipe is still a sentence", () => {
    // The lookahead for the `| --- |` rule is what makes this true; without it
    // any prose with a pipe in it would open a table.
    const blocks = renderMarkdown("Run `a | b` to pipe it.");
    expect(kinds(blocks)).toEqual(["p"]);
  });

  test("headings and lists survive, including a numbered one", () => {
    const blocks = renderMarkdown(
      ["## Album artwork", "", "- reuses the canvas", "- falls back to text", "", "1. first", "2. second"].join(
        "\n",
      ),
    );
    expect(kinds(blocks)).toEqual(["h4", "ul", "ol"]);
    expect(text(blocks[0])).toBe("Album artwork");
    expect(find(blocks[1], "li").map(text)).toEqual(["reuses the canvas", "falls back to text"]);
    expect(find(blocks[2], "li").map(text)).toEqual(["first", "second"]);
  });

  test("a link renders its label, not the absolute path behind it", () => {
    const blocks = renderMarkdown("[app.jsx](/Users/admin/.ledge/apps/music/app.jsx:430) compiled.");
    const rendered = text(blocks);
    expect(rendered).toContain("app.jsx compiled.");
    expect(rendered).not.toContain("/Users/admin");
  });

  test("fenced code is still verbatim, and an open fence still renders", () => {
    const closed = renderMarkdown("before\n\n```\n| not | a | table |\n```\n");
    expect(kinds(closed)).toEqual(["p", "pre"]);
    expect(text(closed[1])).toBe("| not | a | table |");
    // Mid-stream: the agent is still typing inside the fence.
    expect(kinds(renderMarkdown("```\nhalf a li"))).toEqual(["pre"]);
  });

  test("nothing it emits can be raw HTML", () => {
    // The whole reason this renderer exists rather than a library.
    const blocks = renderMarkdown("<img src=x onerror=alert(1)> | a |\n| --- |\n| <b>no</b> |");
    const json = JSON.stringify(blocks);
    expect(json).not.toContain("dangerouslySetInnerHTML");
    expect(text(blocks)).toContain("<img src=x onerror=alert(1)>");
  });
});
