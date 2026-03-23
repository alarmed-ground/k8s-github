#!/usr/bin/env bash
# Level 2 — preflight_nodes: skip flags and SSH failure fast-path
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="preflight_nodes"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: runs when CONTROL_PLANE_IP is set ────────────────────────────────
CONTROL_PLANE_IP="10.0.0.1"; WORKER_IPS=()
# Override run_on to simulate a healthy node
run_on() {
  local node="$1"; shift; local cmd="$*"
  case "$cmd" in
    *lsb-release*|*os-release*) echo "24.04" ;;
    *df*BG*)                    echo "Filesystem Size Used Avail Use% Mounted
/dev/sda1 200G 50G 150G 25% /" ;;  # df -BG output
    *free*-m*)                  echo "              total  used  free
Swap:             0     0     0" ;;
    *nproc*|*processor*)        echo "4" ;;
    *MemTotal*)                 echo "16" ;;
    *ss*-tlnH*)                 echo "" ;;
    *kubelet*)                  echo "no" ;;
    *)                          echo "" ;;
  esac
  return 0
}
# SSH check — override ssh to succeed
ssh() { return 0; }

run_step_capture run_preflight_nodes
assert_subcalled "Pre-flight" "preflight: section header emitted"

# ── Test 2: function is declared ─────────────────────────────────────────────
if declare -f run_preflight_nodes &>/dev/null; then
  _pass "run_preflight_nodes is declared"
else
  _fail "run_preflight_nodes is declared"
fi

summarise_test
