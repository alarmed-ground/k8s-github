#!/usr/bin/env bash
# Level 1 — Step modules must not reference absolute paths to the install dir
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

for f in "${ROOT}"/steps/*.sh "${ROOT}"/lib/*.sh          "${ROOT}"/wizard/lib.sh "${ROOT}"/wizard/sections/*.sh; do
  [[ -f "$f" ]] || continue
  # Matches any absolute path that looks like a home/project dir
  # Excludes legitimate system paths: /etc /usr /var /tmp /root /run /dev /proc /sys /opt/cni
  if grep -En \
    '"/home/[^"]+/(steps|lib|k8s)|(SCRIPT_DIR|STEPS_DIR|LIB_DIR)="/' \
    "$f" 2>/dev/null | grep -v '^\s*#'; then
    echo "  FAIL  $(basename "$f") — hardcoded install-dir path"
    FAIL=$(( FAIL + 1 ))
  else
    echo "  PASS  $(basename "$f")"
  fi
done

(( FAIL == 0 )) || { echo "FAIL: ${FAIL} file(s) have hardcoded paths"; exit 1; }
