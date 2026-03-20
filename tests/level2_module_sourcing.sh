#!/usr/bin/env bash
# Level 2 — Unit test: every module sources cleanly in isolation
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="module source isolation"
source "${ROOT}/tests/test_helpers.sh"

FAIL=0
for f in "${ROOT}"/lib/*.sh "${ROOT}"/steps/*.sh; do
  [[ -f "$f" ]] || continue
  result=$(bash -c "
    set -uo pipefail
    LOG_FILE=/dev/null
    SCRIPT_DIR="${ROOT}"
    LIB_DIR="${ROOT}/lib"
    STEPS_DIR="${ROOT}/steps"
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
    log() { true; }; warn() { true; }; error() { true; }
    info() { true; }; section() { true; }
    kubectl() { true; }; helm() { true; }
    ssh() { true; }; scp() { true; }; curl() { true; }
    source '${f}'
    echo OK
  " 2>&1)
  if [[ "$result" == *"OK"* ]]; then
    _pass "$(basename "$f") sources cleanly"
  else
    _fail "$(basename "$f") failed to source"
    echo "        ${result}"
    FAIL=$(( FAIL + 1 ))
  fi
done

summarise_test
