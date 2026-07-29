import React from "react";

// A deliberately small markdown renderer that emits **React elements**, never
// HTML strings. Agent output is untrusted text — a real markdown library that
// hands back HTML would put a `dangerouslySetInnerHTML` on the one surface in
// Ledge that renders something a model wrote. React escapes text children by
// construction, so this file cannot inject markup even if it is wrong.
//
// What it handles is not a guess at the CommonMark spec, it is what a coding
// agent actually emits in this panel — fences, inline code, bold, headings,
// lists, links and TABLES. Tables in particular: a before/after table is how
// these models summarise a change, and rendered as a paragraph it comes out as
// `| Before | After | | --- | --- | | …` — a wall of pipes that is worse than
// useless, because the information is there and unreadable.
//
// Anything else renders as its own literal characters, which is the correct
// failure mode for a transcript.

const INLINE = /(`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\([^)]*\))/g;
const LINK = /^\[([^\]]+)\]\(([^)]*)\)$/;

function inline(text, keyPrefix) {
  const parts = String(text).split(INLINE).filter((part) => part !== "");
  return parts.map((part, index) => {
    const key = `${keyPrefix}:${index}`;
    if (part.startsWith("`") && part.endsWith("`") && part.length > 1) {
      return React.createElement("code", { key }, part.slice(1, -1));
    }
    if (part.startsWith("**") && part.endsWith("**") && part.length > 3) {
      return React.createElement("strong", { key }, part.slice(2, -2));
    }
    const link = LINK.exec(part);
    if (link) {
      // The LABEL, not the target. Nothing on this surface can follow a link —
      // the page is file:// under a strict CSP with no navigation — so an <a>
      // would be a control that does nothing, and the raw URL is usually an
      // absolute path several times wider than the panel. The label is the part
      // the sentence was written around; the path, when it matters, is on the
      // tool marker above.
      return React.createElement("span", { key, className: "link" }, link[1]);
    }
    return part;
  });
}

/** `| a | b |` → `["a", "b"]`. Leading/trailing pipes are optional in the wild. */
function cells(line) {
  const trimmed = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  return trimmed.split("|").map((cell) => cell.trim());
}

/** A `| --- | :-: |` rule — the line that makes the row above a header. */
function isDivider(line) {
  const text = line.trim();
  return /^\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?$/.test(text) && text.includes("-");
}

const isTableRow = (line) => line.trim().startsWith("|") || line.includes(" | ");

export function renderMarkdown(source) {
  const lines = String(source).split("\n");
  const blocks = [];
  let paragraph = [];
  let fence = null;
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

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];

    if (line.startsWith("```")) {
      if (fence === null) {
        flush();
        fence = [];
      } else {
        blocks.push(
          React.createElement(
            "pre",
            { key: key("c") },
            React.createElement("code", null, fence.join("\n")),
          ),
        );
        fence = null;
      }
      continue;
    }
    if (fence !== null) {
      fence.push(line);
      continue;
    }

    if (line.trim() === "") {
      flush();
      continue;
    }

    // A table is the one construct here that needs to look ahead: a row is only
    // a table row if the line under it is the `| --- |` rule. Without that check
    // any sentence containing a pipe would start a table.
    if (isTableRow(line) && i + 1 < lines.length && isDivider(lines[i + 1])) {
      flush();
      const header = cells(line);
      const rows = [];
      i += 1;
      while (i + 1 < lines.length && isTableRow(lines[i + 1]) && lines[i + 1].trim() !== "") {
        i += 1;
        rows.push(cells(lines[i]));
      }
      blocks.push(
        React.createElement(
          "div",
          { key: key("t"), className: "table-wrap" },
          React.createElement(
            "table",
            null,
            React.createElement(
              "thead",
              null,
              React.createElement(
                "tr",
                null,
                header.map((cell, index) =>
                  React.createElement("th", { key: index }, inline(cell, `${key("t")}h${index}`)),
                ),
              ),
            ),
            React.createElement(
              "tbody",
              null,
              rows.map((row, rowIndex) =>
                React.createElement(
                  "tr",
                  { key: rowIndex },
                  // Ragged rows are normal in generated markdown; pad to the
                  // header so the columns stay aligned rather than shifting.
                  header.map((_, index) =>
                    React.createElement(
                      "td",
                      { key: index },
                      inline(row[index] ?? "", `${key("t")}${rowIndex}:${index}`),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flush();
      // Every heading level renders the same. The panel is 440 pt wide and a
      // turn is a few paragraphs; an h1/h3 size hierarchy inside it would be
      // typography for a document that does not exist.
      blocks.push(
        React.createElement("h4", { key: key("h") }, inline(heading[2], key("h"))),
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

  // An unterminated fence is the normal mid-stream state, not an error: the
  // agent is still typing inside it.
  if (fence !== null) {
    blocks.push(
      React.createElement(
        "pre",
        { key: key("c") },
        React.createElement("code", null, fence.join("\n")),
      ),
    );
  }
  flush();
  return blocks;
}
