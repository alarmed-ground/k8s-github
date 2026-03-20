#!/usr/bin/env bash
# Level 2 — Unit test: every add-on skips when its INSTALL_ flag is false
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="addon skip flags"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

test_addon_skip() {
  local _fn="$1" _flag="$2" _label="${1}: skips when ${2}=false"
  export "${_flag}=false"
  reset_calls
  run_step_noabort "${_fn}"
  assert_not_called "helm upgrade" "${_label} (no helm)"
  assert_not_called "kubectl apply" "${_label} (no kubectl apply)"
}

test_addon_skip "install_ceph"         "INSTALL_CEPH"
test_addon_skip "install_minio"        "INSTALL_MINIO"
test_addon_skip "install_ingress"      "INSTALL_INGRESS"
test_addon_skip "install_metallb"      "INSTALL_METALLB"
test_addon_skip "install_cert_manager" "INSTALL_CERT_MANAGER"
test_addon_skip "install_registry"     "INSTALL_REGISTRY"
test_addon_skip "install_argocd"       "INSTALL_ARGOCD"
test_addon_skip "install_loki"         "INSTALL_LOKI"
test_addon_skip "install_ray"          "INSTALL_RAY"
test_addon_skip "harden_cluster"       "INSTALL_HARDEN"

summarise_test
