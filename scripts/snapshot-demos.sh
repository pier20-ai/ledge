#!/usr/bin/env bash
# Render every demo app's panel to a PNG, end to end:
#
#   app.jsx --(bun, real reconciler)--> commit JSON --(swift, real engine+renderer)--> PNG
#
# Nothing about the picture is scripted: the batch is what a live worker would
# send (spec §3.1) and the pixels come from the same ProtocolEngine +
# ProtocolRenderer path a live commit takes. Plus the shell's own chrome
# surfaces (idle pill, chat, [+], the "waiting for host" card), which have no
# host tree behind them.
#
# Safety: temp dirs only; never touches ~/.ledge, never binds a socket, never
# kills a process it did not start. The apps root's dependencies (a real package
# at protocol/demo-apps — the ~/.ledge/node_modules analogue, spec §6) are
# installed only when missing.
#
# Usage: scripts/snapshot-demos.sh [out-dir]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$REPO_ROOT/shell"
HOST_DIR="$REPO_ROOT/host"
DEMO_APPS="$REPO_ROOT/protocol/demo-apps"
OUT_DIR="${1:-$REPO_ROOT/.snapshots}"

# Strip order = spec §8 (installed apps left to right); Settings is pinned to the
# far right by the shell, so its order only decides the snapshot sequence.
APPS=(stocks music deals alarm trader cimedic chess tetris aviary settings)

COMMITS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ledge-commits.XXXXXX")"

log() { printf '\033[1;34m[snapshots]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[snapshots] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  rm -rf "$COMMITS_DIR"
}
trap cleanup EXIT INT TERM

# The demo apps import `react` bare from the apps root's own node_modules
# (spec §6 shared node_modules, pinned by protocol/demo-apps/bun.lock). That
# React is linked to the host's copy — one module instance or hooks break — so
# the host has to be installed first.
[ -d "$HOST_DIR/node_modules" ] || fail "host deps missing — run: (cd host && bun install)"
if [ ! -d "$DEMO_APPS/node_modules" ]; then
  log "installing demo-apps dependencies (bun install --frozen-lockfile)…"
  ( cd "$DEMO_APPS" && bun install --frozen-lockfile ) >/dev/null \
    || fail "bun install failed in $DEMO_APPS"
fi

log "dumping mount commits…"
order=0
for app in "${APPS[@]}"; do
  [ -f "$DEMO_APPS/$app/app.jsx" ] || fail "missing $DEMO_APPS/$app/app.jsx"
  ( cd "$HOST_DIR" && bun scripts/dump-commits.ts \
      "$DEMO_APPS/$app/app.jsx" "$COMMITS_DIR/$app.json" --order "$order" ) \
    || fail "dump-commits failed for $app"
  order=$((order + 1))
done

log "building the shell…"
( cd "$SHELL_DIR" && swift build ) >/dev/null || fail "swift build failed"

log "replaying commits into PNGs -> $OUT_DIR"
mkdir -p "$OUT_DIR"
"$SHELL_DIR/.build/debug/LedgeShell" --snapshots "$OUT_DIR" --commits "$COMMITS_DIR" \
  || fail "snapshot render failed"

ls -1 "$OUT_DIR"
log "done."
