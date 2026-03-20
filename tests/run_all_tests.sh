#!/usr/bin/env bash
# =============================================================================
# run_all_tests.sh — Test runner for the k8s modular installer
# Usage:  bash tests/run_all_tests.sh [--level 1|2|all]
#
# Level 1 — static analysis (no cluster needed)
# Level 2 — unit tests with mocked commands (no cluster needed)
# =============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$TESTS_DIR")"
LEVEL="${1:-all}"
[[ "${1:-}" == "--level" ]] && LEVEL="${2:-all}"

TOTAL=0; PASSED=0; FAILED=0
FAILED_TESTS=()

run_test() {
  local script="$1"
  local name
  name=$(basename "$script" .sh | sed 's/^test_//')
  TOTAL=$(( TOTAL + 1 ))

  local out
  if out=$(timeout 120 bash "$script" 2>&1); then
    echo -e "  \033[0;32m✔\033[0m  ${name}"
    PASSED=$(( PASSED + 1 ))
  else
    echo -e "  \033[0;31m✖\033[0m  ${name}"
    echo "$out" | sed 's/^/      /'
    FAILED=$(( FAILED + 1 ))
    FAILED_TESTS+=("$name")
  fi
}

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  k8s Installer Test Suite"
echo "══════════════════════════════════════════════════════════"
echo ""

if [[ "$LEVEL" == "1" || "$LEVEL" == "all" ]]; then
  echo "── Level 1: Static Analysis ───────────────────────────────"
  for t in "${TESTS_DIR}"/level1_*.sh; do
    [[ -f "$t" ]] && run_test "$t"
  done
  echo ""
fi

if [[ "$LEVEL" == "2" || "$LEVEL" == "all" ]]; then
  echo "── Level 2: Unit Tests ────────────────────────────────────"
  for t in "${TESTS_DIR}"/level2_*.sh; do
    [[ -f "$t" ]] && run_test "$t"
  done
  echo ""
fi

echo "══════════════════════════════════════════════════════════"
echo "  Results: ${PASSED}/${TOTAL} passed"
if (( FAILED > 0 )); then
  echo "  Failed:"
  for t in "${FAILED_TESTS[@]}"; do echo "    - ${t}"; done
fi
echo "══════════════════════════════════════════════════════════"
echo ""

(( FAILED == 0 ))
