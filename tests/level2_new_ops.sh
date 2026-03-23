#!/usr/bin/env bash
# Level 2 — new ops steps: all declared and honour INSTALL_ / skip flags
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="new_ops_steps"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# Check every new function is declared
for fn in \
  run_preflight_nodes \
  check_etcd_health \
  patch_os_rolling \
  install_cert_monitor \
  apply_network_policies \
  generate_rbac_kubeconfigs \
  check_vllm_health \
  benchmark_vllm \
  snapshot_pvc \
  restore_pvc_from_snapshot \
  configure_mig \
  configure_pod_security \
  install_dcgm_dashboard \
  install_alerting_rules; do
  if declare -f "$fn" &>/dev/null; then
    _pass "${fn} declared"
  else
    _fail "${fn} NOT declared"
  fi
done

# INSTALL_ guard tests
INSTALL_MIG="false"
run_step_capture configure_mig
assert_subnot_called "kubectl label" "configure_mig: skips when INSTALL_MIG=false"

INSTALL_PSS="false"
run_step_capture configure_pod_security
assert_subnot_called "kubectl label" "configure_pod_security: skips when INSTALL_PSS=false"

INSTALL_ALERTING_RULES="false"
run_step_capture install_alerting_rules
assert_subnot_called "kubectl apply" "install_alerting_rules: skips when flag false"

INSTALL_DCGM_DASHBOARD="false"
run_step_capture install_dcgm_dashboard
assert_subnot_called "kubectl apply" "install_dcgm_dashboard: skips when flag false"

# vllm-health skips when INSTALL_VLLM=false
INSTALL_VLLM="false"
run_step_capture check_vllm_health
assert_subnot_called "curl" "check_vllm_health: skips when INSTALL_VLLM=false"

summarise_test
