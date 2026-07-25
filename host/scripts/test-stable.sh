#!/usr/bin/env bash
# Runs each test file in its own bun process.
#
# `bun test` (one process for all 18 files) intermittently segfaults in Bun
# 1.3.9 itself — its own panic banner, ~50% of full runs, never mid-suite and
# never when files run alone. The trigger is accumulated Worker/socket state
# across suites, i.e. an upstream runtime bug at teardown scale, not a test
# failure: every completed run is 135/135. Per-file processes sidestep it at
# the cost of a few seconds. `bun run test:fast` keeps the one-shot mode.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for file in test/*.test.*; do
  if ! bun test "$file"; then
    status=1
  fi
done
exit $status
