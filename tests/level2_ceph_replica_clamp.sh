#!/usr/bin/env bash
# Level 2 — Unit test: install_ceph clamps replica count to worker count
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="install_ceph replica clamp"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

run_ceph() {
  INSTALL_CEPH="true"; NS_CEPH="rook-ceph"
  CEPH_USE_ALL_NODES="true"; CEPH_USE_ALL_DEVICES="true"
  CEPH_DEVICE_FILTER=""; CEPH_DASHBOARD_NODEPORT="32101"; CEPH_DEFAULT_SC="false"
  CONTROL_PLANE_IP="10.0.0.1"
  # Set to 0 so the health poll loop exits immediately in test context
  CEPH_WAIT_TIMEOUT=0
  ROOK_WAIT_TIMEOUT="0s"
  run_step_capture install_ceph
}

# ── Test 1: 1 worker + replica=3 → clamp to 1 ────────────────────────────────
WORKER_IPS=("10.0.0.2"); CEPH_REPLICA_COUNT=3
run_ceph
assert_subcalled "size: 1" "1 worker: replica clamped to 1"

# ── Test 2: 2 workers + replica=3 → clamp to 2 ───────────────────────────────
WORKER_IPS=("10.0.0.2" "10.0.0.3"); CEPH_REPLICA_COUNT=3
run_ceph
assert_subcalled "size: 2" "2 workers: replica clamped to 2"

# ── Test 3: 3 workers + replica=3 → no clamp ─────────────────────────────────
WORKER_IPS=("10.0.0.2" "10.0.0.3" "10.0.0.4"); CEPH_REPLICA_COUNT=3
run_ceph
assert_subcalled "size: 3" "3 workers: replica stays at 3"

# ── Test 4: 0 workers → force replica=1 (single-node) ────────────────────────
WORKER_IPS=(); CEPH_REPLICA_COUNT=3
run_ceph
assert_subcalled "size: 1" "0 workers: replica clamped to 1 (single-node)"

# ── Test 5: INSTALL_CEPH=false → no kubectl apply ────────────────────────────
INSTALL_CEPH="false"; CEPH_WAIT_TIMEOUT=0; ROOK_WAIT_TIMEOUT="0s"
run_step_capture install_ceph
assert_subnot_called "kubectl apply" "INSTALL_CEPH=false: no kubectl called"

summarise_test
