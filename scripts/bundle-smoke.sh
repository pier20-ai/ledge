#!/usr/bin/env bash
# Smoke-test a built Ledge.app: first-run seeding, host startup, no app crashes,
# and — the part that silently regresses — the host dying with the shell.
#
# Usage: scripts/bundle-smoke.sh [path/to/Ledge.app]
#
# Runs against a TEMP install root and a TEMP socket, so it never touches the
# user's ~/.ledge or fights their running Ledge for the real socket.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$REPO_ROOT/dist/Ledge.app}"
SHELL_BIN="$APP/Contents/MacOS/LedgeShell"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ledge-bundle.XXXXXX")"
ROOT="$WORK_DIR/ledge"
SOCK="$WORK_DIR/ledge.sock"
SHELL_LOG="$WORK_DIR/shell.log"
SHELL_PID=""

log()  { printf '\033[1;34m[bundle-smoke]\033[0m %s\n' "$*"; }
fail() {
  printf '\033[1;31m[bundle-smoke] FAIL:\033[0m %s\n' "$*" >&2
  echo "--- shell.log (tail) ---" >&2; tail -n 25 "$SHELL_LOG" 2>/dev/null >&2 || true
  echo "--- host.log (tail) ---"  >&2; tail -n 25 "$ROOT/host.log" 2>/dev/null >&2 || true
  exit 1
}
cleanup() {
  # Only ever our own PIDs — never the user's running Ledge.
  [ -n "$SHELL_PID" ] && kill -9 "$SHELL_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

[ -x "$SHELL_BIN" ] || fail "no app at $APP (run scripts/bundle-app.sh first)"
mkdir -p "$ROOT"

log "launching $APP against $ROOT"
"$SHELL_BIN" --socket "$SOCK" --ledge-root "$ROOT" >"$SHELL_LOG" 2>&1 &
SHELL_PID=$!

# Seeding expands a ~180 MB tarball, so allow real time for the first launch.
for _ in $(seq 1 60); do
  grep -q "catalog ->" "$ROOT/host.log" 2>/dev/null && break
  kill -0 "$SHELL_PID" 2>/dev/null || fail "the shell exited during startup"
  sleep 0.5
done

# --- Assertions -------------------------------------------------------------

[ -d "$ROOT/apps" ]         || fail "first launch did not seed apps"
[ -d "$ROOT/node_modules" ] || fail "first launch did not seed node_modules"
log "✓ seeded ~/.ledge (apps + node_modules)"

grep -q "connected, gen" "$ROOT/host.log" || fail "the bundled host never connected"
log "✓ bundled host connected"

# React resolves out of the SEEDED node_modules here — a different path from the
# repo checkout the e2e covers, and the one users actually get.
if grep -q " -> crashed" "$ROOT/host.log"; then
  grep " -> crashed" "$ROOT/host.log" | sort -u >&2
  fail "an app crashed under the bundle (react resolution? see $ROOT/<app>/crash.log)"
fi
log "✓ no app crashed"

# The host is a DIRECT CHILD of the shell we launched, so ask for it that way.
# A global `pgrep -f MacOS/ledge-host` would happily match the host belonging to
# the user's own installed Ledge.app — and since this script goes on to SIGKILL
# whatever it found, matching the wrong one would kill their running Ledge to
# test ours. Never identify a process to kill by name when its parentage is known.
HOST_PID="$(pgrep -P "$SHELL_PID" || true)"
[ -n "$HOST_PID" ] || fail "no host process found as a child of the test shell"
[ "$(printf '%s\n' "$HOST_PID" | wc -l)" -eq 1 ] \
  || fail "expected exactly one host child, found: $(printf '%s' "$HOST_PID" | tr '\n' ' ')"

# The real test. SIGKILL skips applicationWillTerminate entirely, so nothing but
# the host's own stdin-EOF watchdog can save us from an orphan holding the
# socket (and, through the workers, an app's subprocesses — chess runs Stockfish).
log "SIGKILLing the shell (no cleanup callback runs)…"
kill -9 "$SHELL_PID"; SHELL_PID=""
for _ in $(seq 1 20); do
  kill -0 "$HOST_PID" 2>/dev/null || { log "✓ host exited with the shell"; break; }
  sleep 0.5
done
if kill -0 "$HOST_PID" 2>/dev/null; then
  kill -9 "$HOST_PID" 2>/dev/null || true
  fail "host survived the shell (orphan) — pid $HOST_PID"
fi

log "PASS — bundle seeds, runs, and shuts down cleanly."
