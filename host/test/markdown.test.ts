import { describe, expect, test } from "bun:test";
// The editor's renderer, tested from the host suite on purpose: it is the one
// piece of the editor bundle whose behaviour is pure data in, data out, and a
// third test runner nobody remembers to run is worse than an import that
// reaches across a package boundary.
import { renderMarkdown } from "../../editor/src/markdown.js";

// What chat mode does with agent output (editor/src/markdown.js).
//
// The property under test is never "does it match CommonMark" — it is "does the
// thing an agent actually emitted read as a sentence in a bubble". That test
// changed when the transcript did: this text now lands inside a chat bubble
// (design.html §08 — "iMessage, never a terminal · no agent chrome anywhere"),
// and the document idioms the old renderer supported are exactly what dragged
// it back towards a build log. Tables, fences and headings are therefore
// asserted to be *gone* — reduced to lines, not preserved.

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

describe("markdown in the transcript", () => {
  test("a table becomes lines, not a grid and not a wall of pipes", () => {
    // Verbatim from a real turn (the music app's artwork change). A table in a
    // 76%-wide bubble is unreadable as a grid; the pipes are worse.
    const blocks = renderMarkdown(
      [
        "| Before | After |",
        "| --- | --- |",
        "| Collapsed wing showed text only | Reuses the mini-player canvas |",
        "| Artwork edge was unframed | Added a subtle white outline |",
      ].join("\n"),
    );

    expect(kinds(blocks)).toEqual(["p"]);
    expect(find(blocks, "table")).toHaveLength(0);
    expect(text(blocks)).toBe(
      [
        "Before · After",
        "Collapsed wing showed text only · Reuses the mini-player canvas",
        "Artwork edge was unframed · Added a subtle white outline",
      ].join("\n"),
    );
  });

  test("a ragged row loses its empty cells rather than its meaning", () => {
    const blocks = renderMarkdown("| a | b | c |\n| --- | --- | --- |\n| 1 | 2 |");
    expect(text(blocks)).toBe("a · b · c\n1 · 2");
  });

  test("a sentence containing a pipe is still a sentence", () => {
    const blocks = renderMarkdown("Run `a | b` to pipe it.");
    expect(kinds(blocks)).toEqual(["p"]);
    expect(text(blocks)).toBe("Run a | b to pipe it.");
  });

  test("a heading is a bold line; lists survive, including a numbered one", () => {
    const blocks = renderMarkdown(
      ["## Album artwork", "", "- reuses the canvas", "- falls back to text", "", "1. first", "2. second"].join(
        "\n",
      ),
    );
    // No h4: a turn is a few sentences and has no sections.
    expect(kinds(blocks)).toEqual(["p", "ul", "ol"]);
    expect(find(blocks[0], "strong")).toHaveLength(1);
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

  test("a fence keeps its words and loses its box", () => {
    // The code lives in the app's folder and on the stage above; a scrolling
    // black box repeating it inside a bubble is the terminal aesthetic §08
    // forbids. The lines themselves are still what the agent said.
    const closed = renderMarkdown("before\n\n```\n| not | a | table |\n```\n");
    expect(kinds(closed)).toEqual(["p", "p"]);
    expect(find(closed, "pre")).toHaveLength(0);
    expect(text(closed[1])).toBe("| not | a | table |");
    // Mid-stream: the agent is still typing inside the fence.
    expect(kinds(renderMarkdown("```\nhalf a li"))).toEqual(["p"]);
  });

  test("nothing it emits can be raw HTML", () => {
    // The whole reason this renderer exists rather than a library.
    const blocks = renderMarkdown("<img src=x onerror=alert(1)> | a |\n| --- |\n| <b>no</b> |");
    const json = JSON.stringify(blocks);
    expect(json).not.toContain("dangerouslySetInnerHTML");
    expect(text(blocks)).toContain("<img src=x onerror=alert(1)>");
    expect(text(blocks)).toContain("<b>no</b>");
  });
});
