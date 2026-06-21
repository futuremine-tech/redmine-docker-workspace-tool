#!/usr/bin/env bash
set -euo pipefail

# Simple wrapper to run the repository BATS test suite with test helpers in PATH.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
REPO_ROOT="$DIR"

# Ensure test helpers are available
export PATH="$REPO_ROOT/test/helpers:$PATH"
# Allow mocks for local test runs
export RPDT_ALLOW_MOCK=1
export RDC_ALLOW_MOCK=1

if [ $# -eq 0 ]; then
  exec bats test/bats
else
  exec bats "$@"
fi
