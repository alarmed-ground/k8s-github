#!/usr/bin/env bash
# Level 2 — install_cni dispatches correctly per CNI_PLUGIN
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="install_cni"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: Flannel applies flannel manifest ──────────────────────────────────
CNI_WAIT_TIMEOUT=0  # skip pod readiness poll in tests
CNI_PLUGIN="flannel"
run_step_capture install_cni
assert_subcalled "kubectl apply" "Flannel: kubectl apply called"
assert_subcalled "flannel"       "Flannel: flannel URL referenced"

# ── Test 2: Calico applies calico manifest and patches VXLAN ─────────────────
CNI_PLUGIN="calico"
run_step_capture install_cni
assert_subcalled "calico"    "Calico: calico URL referenced"
assert_subcalled "vxlanMode" "Calico: VXLAN patch applied"

# ── Test 3: Unknown CNI exits non-zero ───────────────────────────────────────
CNI_PLUGIN="weave"
run_step_noabort install_cni
assert_neq "$?" "0" "Unknown CNI exits non-zero"

summarise_test
