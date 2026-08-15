import React from "react";

// A deliberately small markdown renderer that emits **React elements**, never
// HTML strings. Agent output is untrusted text — a real markdown library that
// hands back HTML would put a `dangerouslySetInnerHTML` on the one surface in
// Ledge that renders something a model wrote. React escapes text children by
// construction, so this file cannot inject markup even if it is wrong.
//
// **It got smaller on purpose.** This text lands inside a chat bubble now
// (design.html §08: "iMessage, never a terminal · no agent chrome anywhere"),
// and a bubble has no room — and no licence — for a code block, a table or a
// heading hierarchy. Every one of those is a document idiom, and each of them
// dragged the transcript back towards a build log:
//
//   - fences render as their own plain lines. The agent's code lives in the
//     app's folder and on the stage above; a scrolling black box repeating it
//     inside a bubble is the terminal aesthetic the design forbids.
//   - tables collapse to one line per row, cells joined by `·`. The wall of
//     pipes a raw table produces is unreadable at this width either way; this
//     at least reads as a phrase.
//   - headings become a bold line. A turn is a few sentences; it has no
//     sections.
//
// What survives is what a sentence is made of: emphasis, lists, and the label
// of a link. Anything else renders as its own literal characters, which is the
// correct failure mode for a transcript.

const INLINE = /(`[^`]+`|\*\*[^*]+\*\*|\*[^*\n]+\*|\[[^\]]+\]\([^)]*\))/g;
const LINK = /^\[([^\]]+)\]\(([^)]*)\)$/;

function inline(text, keyPrefix) {
  const parts = String(text).split(INLINE).filter((part) => part !== "");
  return parts.map((part, index) => {
    const key = `${keyPrefix}:${index}`;
    // Inline code keeps its *emphasis*, not its typeface: a monospace chip in a
    // bubble is a terminal peeking through. `timer.jsx` is a name in a sentence.
    if (part.startsWith("`") && part.endsWith("`") && part.length > 1) {
      return React.createElement("em", { key }, part.slice(1, -1));
    }
    if (part.startsWith("**") && part.endsWith("**") && part.length > 3) {
      return React.createElement("strong", { key }, part.slice(2, -2));
    }
    if (part.startsWith("*") && part.endsWith("*") && part.length > 2) {
      return React.createElement("em", { key }, part.slice(1, -1));
    }
    const link = LINK.exec(part);
    if (link) {
      // The LABEL, not the target. Nothing on this surface can follow a link —
      // the page is file:// under a strict CSP with no navigation — so an <a>
      // would be a control that does nothing, and the raw URL is usually an
      // absolute path several times wider than the panel.
      return React.createElement("span", { key, className: "link" }, link[1]);
    }
    return part;
  });
}

/** `| a | b |` → `a · b`. Leading/trailing pipes are optional in the wild. */
function flattenRow(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim())
    .filter((cell) => cell !== "")
    .join(" · ");
}

/** A `| --- | :-: |` rule. It says nothing once the table is prose; drop it. */
function isDivider(line) {
  const text = line.trim();
  return /^\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?$/.test(text) && text.includes("-");
}

const isTableRow = (line) => line.trim().startsWith("|");

export function renderMarkdown(source) {
  const lines = String(source).split("\n");
  const blocks = [];
  let paragraph = [];
  let fenced = false;
  let list = null;

  const key = (prefix) => `${prefix}${blocks.length}`;

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    const text = paragraph.join("\n");
    blocks.push(React.createElement("p", { key: key("p") }, inline(text, key("p"))));
    paragraph = [];
  };

  const flushList = () => {
    if (!list) return;
    const { ordered, items } = list;
    list = null;
    blocks.push(
      React.createElement(
        ordered ? "ol" : "ul",
        { key: key("l") },
        items.map((item, index) =>
          React.createElement("li", { key: index }, inline(item, `${key("l")}:${index}`)),
        ),
      ),
    );
  };

  const flush = () => {
    flushParagraph();
    flushList();
  };

  for (const line of lines) {
    // A fence is a boundary between paragraphs and nothing else. The lines
    // inside it are kept — they are what the agent said — but they are lines.
    if (line.startsWith("```")) {
      flush();
      fenced = !fenced;
      continue;
    }

    if (line.trim() === "") {
      flush();
      continue;
    }

    if (fenced) {
      paragraph.push(line);
      continue;
    }

    if (isDivider(line)) continue;

    if (isTableRow(line)) {
      flushList();
      const row = flattenRow(line);
      if (row !== "") paragraph.push(row);
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flush();
      blocks.push(
        React.createElement(
          "p",
          { key: key("h") },
          React.createElement("strong", null, inline(heading[2], key("h"))),
        ),
      );
      continue;
    }

    const bullet = /^\s*[-*+]\s+(.*)$/.exec(line);
    const numbered = /^\s*\d+[.)]\s+(.*)$/.exec(line);
    if (bullet || numbered) {
      flushParagraph();
      const ordered = Boolean(numbered);
      if (!list || list.ordered !== ordered) {
        flushList();
        list = { ordered, items: [] };
      }
      list.items.push((bullet ?? numbered)[1]);
      continue;
    }

    // A plain line under a list item is its continuation, not a new paragraph.
    if (list) {
      list.items[list.items.length - 1] += `\n${line}`;
      continue;
    }

    paragraph.push(line);
  }

  flush();
  return blocks;
}
