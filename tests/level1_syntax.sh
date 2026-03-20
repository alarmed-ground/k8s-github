#!/usr/bin/env bash
# Level 1 — Syntax check: every module file must pass bash -n
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

check() {
  if bash -n "$1" 2>/dev/null; then
    echo "  PASS  $(realpath --relative-to="$ROOT" "$1")"
  else
    echo "  FAIL  $(realpath --relative-to="$ROOT" "$1")"
    bash -n "$1" 2>&1 | sed 's/^/        /'
    FAIL=$(( FAIL + 1 ))
  fi
}

check "${ROOT}/k8s_cluster_setup.sh"
check "${ROOT}/k8s_configure.sh"
for f in "${ROOT}"/lib/*.sh "${ROOT}"/steps/*.sh           "${ROOT}"/wizard/lib.sh "${ROOT}"/wizard/sections/*.sh; do
  [[ -f "$f" ]] && check "$f"
done

(( FAIL == 0 )) || { echo ""; echo "FAIL: ${FAIL} file(s) have syntax errors"; exit 1; }
