#!/bin/bash
#
# Run the full Cloud Provider Cleaner test suite.
# All tests run inside disposable fake HOME dirs under /tmp — they never touch
# the real home directory or the real Trash.
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

total_fail=0

run() {
  local name="$1" script="$2"
  echo
  echo "####################################################################"
  echo "# $name"
  echo "####################################################################"
  if bash "$script"; then
    echo ">> $name: PASS"
  else
    echo ">> $name: FAIL"
    total_fail=$((total_fail + 1))
  fi
}

run "Safety Gate unit tests"        "$HERE/test_safety.sh"
run "Scanner/Executor sandbox test" "$HERE/test_sandbox.sh"

echo
echo "####################################################################"
echo "# ShellCheck"
echo "####################################################################"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$ROOT/cleaner.sh" "$HERE"/*.sh; then
    echo ">> shellcheck: clean"
  else
    echo ">> shellcheck: issues"
    total_fail=$((total_fail + 1))
  fi
else
  echo ">> shellcheck not installed (skipped)"
fi

echo
echo "===================================================================="
if [ "$total_fail" -eq 0 ]; then
  echo "ALL GREEN"
else
  echo "FAILURES: $total_fail suite(s) failed"
fi
echo "===================================================================="
[ "$total_fail" -eq 0 ]
