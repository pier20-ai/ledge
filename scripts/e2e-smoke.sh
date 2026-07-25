#!/usr/bin/env bash
# End-to-end smoke test: build the Swift shell, run it over a TEMP socket, run the
# Bun host against the demo apps, and assert from the logs that the three-process
# pipeline actually connected and rendered — hello exchanged, catalog delivered,
# and a commit applied by the shell.
#
# The shell binds ~/.ledge/ledge.sock by default now, so this run MUST pass
# `--socket <tmp>`; otherwise it would fight the user's own Ledge for the real
# socket (and unlink it on exit).
#
# Safety (see the task constraints):
#   - Uses a TEMP socket + TEMP logs only; never touches ~/.ledge or the user's
#     installed Ledge.app.
#   - Tracks the PIDs it spawns and kills ONLY those — never the user's own
#     running Ledge instance.
#   - Installs `protocol/demo-apps`' own dependencies (the apps root is a real
#     package: package.json + committed bun.lock, the repo analogue of
#     ~/.ledge/node_modules, spec §6) only when they are missing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_DIR="$REPO_ROOT/shell"
HOST_DIR="$REPO_ROOT/host"
DEMO_APPS="$REPO_ROOT/protocol/demo-apps"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ledge-e2e.XXXXXX")"
SOCK="$WORK_DIR/ledge.sock"
SHELL_LOG="$WORK_DIR/shell.log"
HOST_LOG="$WORK_DIR/host.log"

SHELL_PID=""
HOST_PID=""

log() { printf '\033[1;34m[e2e]\033[0m %s\n' "$*"; }
fail() {
  printf '\033[1;31m[e2e] FAIL:\033[0m %s\n' "$*" >&2
  echo "--- shell.log (tail) ---" >&2; tail -n 40 "$SHELL_LOG" 2>/dev/null >&2 || true
  echo "--- host.log (tail) ---" >&2; tail -n 40 "$HOST_LOG" 2>/dev/null >&2 || true
  exit 1
}

cleanup() {
  # Kill ONLY the processes we spawned (never the user's own Ledge).
  [ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null || true
  [ -n "$SHELL_PID" ] && kill "$SHELL_PID" 2>/dev/null || true
  [ -n "$HOST_PID" ] && wait "$HOST_PID" 2>/dev/null || true
  [ -n "$SHELL_PID" ] && wait "$SHELL_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# --- Preconditions ----------------------------------------------------------

log "workspace: $WORK_DIR"
[ -f "$DEMO_APPS/stocks/app.jsx" ] || fail "demo app missing at $DEMO_APPS/stocks/app.jsx"

# Ensure the apps root's own dependencies are installed (spec §6: the shared
# node_modules at the apps root, plus the lockfile that pins it). The apps root
# links React to the host's copy — one module instance or hooks break — so the
# host has to be installed first.
[ -d "$HOST_DIR/node_modules" ] || fail "host deps missing — run: (cd host && bun install)"
if [ ! -d "$DEMO_APPS/node_modules" ]; then
  log "installing demo-apps dependencies (bun install --frozen-lockfile)…"
  ( cd "$DEMO_APPS" && bun install --frozen-lockfile ) >"$WORK_DIR/install.log" 2>&1 \
    || fail "bun install failed in $DEMO_APPS (see $WORK_DIR/install.log)"
fi

# --- Build the shell --------------------------------------------------------

log "building the shell (swift build)…"
( cd "$SHELL_DIR" && swift build ) >"$WORK_DIR/build.log" 2>&1 \
  || fail "swift build failed (see $WORK_DIR/build.log)"
SHELL_BIN="$SHELL_DIR/.build/debug/LedgeShell"
[ -x "$SHELL_BIN" ] || fail "shell binary not found at $SHELL_BIN"

# --- Launch the shell (listener) over the temp socket -----------------------

log "starting shell --socket $SOCK"
"$SHELL_BIN" --socket "$SOCK" >"$SHELL_LOG" 2>&1 &
SHELL_PID=$!

# Wait for the shell to bind the socket (it listens; the host connects).
for _ in $(seq 1 50); do
  [ -S "$SOCK" ] && break
  kill -0 "$SHELL_PID" 2>/dev/null || fail "shell exited before binding the socket"
  sleep 0.2
done
[ -S "$SOCK" ] || fail "shell did not create the socket at $SOCK"
log "socket is up"

# --- Launch the host against the demo apps ----------------------------------

log "starting host against $DEMO_APPS"
( cd "$HOST_DIR" && exec bun src/host.ts "$SOCK" --apps-root "$DEMO_APPS" ) >"$HOST_LOG" 2>&1 &
HOST_PID=$!

# Give the pipeline time to: exchange hellos, deliver the catalog, spawn the
# worker, mount, and apply the first commit.
for _ in $(seq 1 40); do
  if grep -q "applied commit" "$SHELL_LOG" 2>/dev/null \
     && grep -q "connected, gen" "$HOST_LOG" 2>/dev/null \
     && grep -q "catalog ->" "$HOST_LOG" 2>/dev/null \
     && grep -q "stocks=sf:" "$SHELL_LOG" 2>/dev/null; then
    break
  fi
  kill -0 "$HOST_PID" 2>/dev/null || fail "host exited early"
  kill -0 "$SHELL_PID" 2>/dev/null || fail "shell exited early"
  sleep 0.25
done

# --- Assertions -------------------------------------------------------------

grep -q "connected, gen" "$HOST_LOG"  || fail "host never completed the hello exchange"
log "✓ hello exchanged"
grep -q "catalog ->" "$HOST_LOG"       || fail "host never delivered the catalog"
log "✓ catalog delivered"
# Meta extraction (spec §6 → §3.6): the worker declares name/icon, the host
# merges it, and the shell's strip finally shows real icons instead of the
# registry's placeholder — the user-visible bug this API group fixes.
grep -q "meta <- stocks" "$HOST_LOG"   || fail "worker never posted its meta"
log "✓ worker meta extracted"
grep -q "stocks=sf:chart.line.uptrend.xyaxis" "$SHELL_LOG" \
  || fail "shell's catalog never carried the app's real icon (strip would show a placeholder)"
log "✓ shell strip has the app's real sf: icon"
grep -q "commit -> stocks" "$HOST_LOG" || fail "host never routed a commit for stocks"
log "✓ host routed the mount commit"
grep -q "applied commit" "$SHELL_LOG"  || fail "shell never applied a commit"
log "✓ shell applied the commit end-to-end"

log "PASS — three-process pipeline connected and rendered."
echo "--- host.log (tail) ---"
tail -n 12 "$HOST_LOG"
echo "--- shell.log (tail) ---"
tail -n 12 "$SHELL_LOG"
