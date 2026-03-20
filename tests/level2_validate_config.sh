#!/usr/bin/env bash
# Level 2 — validate_config logic
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="validate_config"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"

# ── Test 1: INSTALL_NFS auto-disabled when NFS_SERVER_IP empty ───────────────
CONTROL_PLANE_IP="10.0.0.1"; WORKER_IPS=()
INSTALL_NFS="true"; NFS_SERVER_IP=""
run_in_shell validate_config
assert_eq "$INSTALL_NFS" "false" "INSTALL_NFS auto-disabled when NFS_SERVER_IP empty"

# ── Test 2: Valid config passes with exit 0 ───────────────────────────────────
INSTALL_NFS="false"; CONTROL_PLANE_IP="10.0.0.1"
run_in_shell validate_config
assert_eq "$?" "0" "valid config exits 0"

# ── Test 3: Missing CONTROL_PLANE_IP causes non-zero exit ────────────────────
# Must use subshell — validate_config calls exit() on error
CONTROL_PLANE_IP=""
run_step_noabort validate_config
assert_neq "$?" "0" "empty CONTROL_PLANE_IP causes non-zero exit"
CONTROL_PLANE_IP="10.0.0.1"

# ── Test 4: Single-node cluster triggers a warning ───────────────────────────
WORKER_IPS=()
_warned=""
warn() { _warned+="$*"; }
run_in_shell validate_config
assert_contains "$_warned" "single-node" "warns about single-node cluster"
warn() { _TEST_CALLS+=("warn $*"); }

summarise_test
