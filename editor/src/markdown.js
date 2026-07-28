import React from "react";

// A deliberately small markdown renderer that emits **React elements**, never
// HTML strings. Agent output is untrusted text — a real markdown library that
// hands back HTML would put a `dangerouslySetInnerHTML` on the one surface in
// Ledge that renders something a model wrote. React escapes text children by
// construction, so this file cannot inject markup even if it is wrong.
//
// It handles the four things a coding agent actually emits: fenced code,
// inline code, bold, and paragraphs. Anything else renders as its own literal
// characters, which is the correct failure mode for a transcript.

const INLINE = /(`[^`]+`|\*\*[^*]+\*\*)/g;

function inline(text, keyPrefix) {
  const parts = text.split(INLINE).filter((part) => part !== "");
  return parts.map((part, index) => {
    const key = `${keyPrefix}:${index}`;
    if (part.startsWith("`") && part.endsWith("`") && part.length > 1) {
      return React.createElement("code", { key }, part.slice(1, -1));
    }
    if (part.startsWith("**") && part.endsWith("**") && part.length > 3) {
      return React.createElement("strong", { key }, part.slice(2, -2));
    }
    return part;
  });
}

export function renderMarkdown(source) {
  const lines = String(source).split("\n");
  const blocks = [];
  let paragraph = [];
  let fence = null;

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    const text = paragraph.join("\n");
    blocks.push(
      React.createElement(
        "p",
        { key: `p${blocks.length}` },
        inline(text, `p${blocks.length}`),
      ),
    );
    paragraph = [];
  };

  for (const line of lines) {
    if (line.startsWith("```")) {
      if (fence === null) {
        flushParagraph();
        fence = [];
      } else {
        blocks.push(
          React.createElement(
            "pre",
            { key: `c${blocks.length}` },
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
      flushParagraph();
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
        { key: `c${blocks.length}` },
        React.createElement("code", null, fence.join("\n")),
      ),
    );
  }
  flushParagraph();
  return blocks;
}
