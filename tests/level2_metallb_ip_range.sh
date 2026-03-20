#!/usr/bin/env bash
# Level 2 — install_metallb requires METALLB_IP_RANGE
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="metallb"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: skips when flag false ─────────────────────────────────────────────
INSTALL_METALLB="false"
run_step_capture install_metallb
assert_subnot_called "helm upgrade" "MetalLB: no helm when disabled"

# ── Test 2: exits non-zero when IP range empty ────────────────────────────────
INSTALL_METALLB="true"; METALLB_IP_RANGE=""; NS_METALLB="metallb-system"
run_step_noabort install_metallb
assert_neq "$?" "0" "MetalLB: exits non-zero when IP range empty"

# ── Test 3: IPAddressPool CR contains the configured range ───────────────────
METALLB_IP_RANGE="192.168.1.200-192.168.1.210"
run_step_capture install_metallb
assert_subcalled "192.168.1.200-192.168.1.210" "MetalLB: IP range in IPAddressPool"

summarise_test
