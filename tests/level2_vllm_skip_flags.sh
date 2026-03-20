#!/usr/bin/env bash
# Level 2 — Unit test: install_vllm and vllm_swap respect INSTALL_VLLM flag
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="vllm flag guards"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: install_vllm skips when INSTALL_VLLM=false ──────────────────────
INSTALL_VLLM="false"
reset_calls
run_step_noabort install_vllm
assert_not_called "helm upgrade" "install_vllm: no helm call when disabled"

# ── Test 2: install_vllm skips when INSTALL_NVIDIA=false ────────────────────
INSTALL_VLLM="true"; INSTALL_NVIDIA="false"
reset_calls
run_step_noabort install_vllm
assert_not_called "helm upgrade" "install_vllm: no helm call when NVIDIA disabled"

# ── Test 3: vllm_swap skips when INSTALL_VLLM=false ────────────────────────
INSTALL_VLLM="false"
reset_calls
run_step_noabort vllm_swap
assert_not_called "helm upgrade" "vllm_swap: no helm call when disabled"

summarise_test
