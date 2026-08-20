#!/usr/bin/env bash
# Build the notch editor surface (spec §8) into the shell's resources.
#
#   scripts/build-editor.sh [--dev]
#
# Output: shell/Sources/LedgeShell/Resources/editor/{index.html,editor.js,editor.css}
# — three files, no directory tree, nothing fetched at runtime. SwiftPM copies
# that folder verbatim (`.copy`, see shell/Package.swift) and the shell loads it
# with `loadFileURL`, so the paths in index.html have to survive the copy: keep
# them relative and keep the names stable.
#
# `--dev` skips minification and keeps names readable, for when the page itself
# is what you are debugging.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR_DIR="$REPO_ROOT/editor"
OUT_DIR="$REPO_ROOT/shell/Sources/LedgeShell/Resources/editor"

MINIFY="--minify"
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) MINIFY=""; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m[editor]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[editor] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

command -v bun >/dev/null || fail "bun is not on PATH"

# React is the only dependency and it is a build-time one — nothing is fetched
# when the page runs. Installed on demand so a fresh clone builds in one step.
if [ ! -d "$EDITOR_DIR/node_modules/react" ]; then
  log "installing editor dependencies…"
  ( cd "$EDITOR_DIR" && bun install ) >/dev/null || fail "bun install failed"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# One entrypoint, one output file. `--target browser` and no code splitting:
# a second chunk would be a second <script> to keep in sync with the CSP and
# with the read-access directory, for no benefit at this size.
log "bundling…"
( cd "$EDITOR_DIR" && bun build src/main.jsx \
    --outfile "$OUT_DIR/editor.js" \
    --target browser \
    --format iife \
    --define process.env.NODE_ENV='"production"' \
    $MINIFY ) >/dev/null || fail "bun build failed"

cp "$EDITOR_DIR/src/index.html" "$OUT_DIR/index.html"
cp "$EDITOR_DIR/src/editor.css" "$OUT_DIR/editor.css"

# The bundle must be self-contained: a stray absolute URL is a runtime network
# request the CSP will refuse and nothing will explain. Cheaper to catch here
# than in the notch.
#
# The allowlist is not a loophole — those are XML *namespace identifiers*
# (`createElementNS`) and React's own error-documentation link, neither of which
# is ever dereferenced. Anything else is a real fetch waiting to happen.
REMOTE="$(grep -oE 'https?://[^"'"'"' )]+' "$OUT_DIR/editor.js" 2>/dev/null \
  | sort -u \
  | grep -vE '^https?://(www\.)?w3\.org/|^https://react\.dev/errors/' || true)"
if [ -n "$REMOTE" ]; then
  printf '%s\n' "$REMOTE" >&2
  fail "the bundle references a remote URL"
fi
if grep -qE '(src|href)="https?:' "$OUT_DIR/index.html"; then
  fail "index.html references a remote asset"
fi

log "PASS — $(du -sh "$OUT_DIR" | cut -f1) in $OUT_DIR"
ls -1 "$OUT_DIR"
