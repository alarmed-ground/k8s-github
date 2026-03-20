#!/usr/bin/env bash
# Level 2 — NFS auto-disable and provisioner skip flags
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="nfs_provisioner"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: validate_config disables NFS when no server IP ───────────────────
# Use run_in_shell so the INSTALL_NFS mutation is visible in this process
CONTROL_PLANE_IP="10.0.0.1"; WORKER_IPS=()
INSTALL_NFS="true"; NFS_SERVER_IP=""
run_in_shell validate_config
assert_eq "$INSTALL_NFS" "false" "NFS auto-disabled without server IP"

# ── Test 2: install_nfs_provisioner skips when INSTALL_NFS=false ─────────────
INSTALL_NFS="false"; NFS_SERVER_IP=""
run_step_capture install_nfs_provisioner
assert_subnot_called "helm upgrade" "NFS: no helm when disabled"

# ── Test 3: install_nfs_provisioner skips when NFS_SERVER_IP empty ───────────
INSTALL_NFS="true"; NFS_SERVER_IP=""
run_step_capture install_nfs_provisioner
assert_subnot_called "helm upgrade" "NFS: no helm when server IP empty"

summarise_test
