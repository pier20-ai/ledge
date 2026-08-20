#!/usr/bin/env bash
# Runs each test file in its own bun process.
#
# HISTORICAL. This existed because `bun test` segfaulted on roughly a quarter of
# full runs — attributed here, wrongly, to an upstream teardown bug. It was
# ours: every app worker called `Bun.resolveSync` three times at boot, which
# walks node_modules through a PROCESS-GLOBAL filesystem cache, and enough
# workers starting close enough together put two threads inside the same hash
# map. The host resolves those paths once now and hands them down
# (src/render/runtime.ts); the crash rate went from 4 runs in 14 to 0 in 30.
#
# `bun test` is the ordinary way to run the suite. This is kept as a bisecting
# tool: one file per process is still the fastest way to find out whether a
# failure belongs to a file or to the state it inherited.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for file in test/*.test.*; do
  if ! bun test "$file"; then
    status=1
  fi
done
exit $status
