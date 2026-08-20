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
#
# Two flags on the dump step below are worth knowing when you are reviewing one
# app rather than the set (host/scripts/dump-commits.ts):
#
#   --props '<json>'  mount with the props a monitor would have produced, so a
#                     data-driven app can be seen in a state other than empty
#                     without a throwaway preview module beside it. e.g.
#                       bun scripts/dump-commits.ts …/nowplaying/app.jsx out.json \
#                         --props '{"track":{"title":"Rhubarb","artist":"Aphex Twin",
#                                            "playing":true,"done":0.42}}'
#   --wing            run monitor(ctx) for ~400 ms against a recording ctx and
#                     keep what it publishes: the first ctx.wing (rendered into
#                     `<app>-wing.png` — the only way an app's collapsed-pill
#                     signature is reviewable at all, since a wing is never part
#                     of the mount tree) **and every canvas frame it drew**,
#                     which is what puts pixels in a panel's wells.
#
# This script passes `--wing` for every app, so a full run always includes each
# app's pill alongside its panel. Apps whose monitor cannot get going without a
# live host (nowplaying needs a player) simply produce no wing and say so.
#
# Canvas apps therefore need no special handling any more. A `canvas` node's
# content never travels in a commit (spec §3.4) — it arrives as draw frames from
# a loop the monitor starts — so weather, chess and tetris used to render as
# empty slabs, their whole signature missing from the one picture that is meant
# to be evidence. The dump now carries a `draws` map keyed by node id and the
# shell replays it as `draw` envelopes once the panel has been measured.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$REPO_ROOT/shell"
HOST_DIR="$REPO_ROOT/host"
DEMO_APPS="$REPO_ROOT/protocol/demo-apps"
OUT_DIR="${1:-$REPO_ROOT/.snapshots}"

# Strip order = spec §8 (installed apps left to right), so this order only
# decides the snapshot sequence.
#
# The list is the whole of protocol/demo-apps. Everything else that used to be
# here lives in protocol/demo-apps-archive, which is not an apps root and is
# never scanned — chess and tetris came back out of it in D4, rewritten against
# principles.md rather than restored, and `settings` went the other way when
# Settings became a native macOS window in the shell.
#
# Both are canvas apps whose panel is a well, and both now paint into it here:
# `--wing` runs their monitor, the monitor draws, and the `draws` map carries
# those frames to the shell. To see a *particular* state rather than the opening
# one (a mid-game position, a live score), pass `--props` to dump-commits
# directly and read the panel.
APPS=(nowplaying weather timer radio beacon chess tetris)

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
  # No app here needs `--props` any more: every panel's opening state is its own
  # (Settings was the one that needed a catalog handed to it, and it is gone).
  # For a particular state, call dump-commits directly with --props.
  ( cd "$HOST_DIR" && bun scripts/dump-commits.ts \
      "$DEMO_APPS/$app/app.jsx" "$COMMITS_DIR/$app.json" --order "$order" --wing ) \
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
