#!/usr/bin/env bash
# Level 2 — Unit test: configure_gpu_timeslicing logic
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="gpu_timeslicing"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: skips when INSTALL_NVIDIA=false ───────────────────────────────────
INSTALL_NVIDIA="false"; GPU_TIMESLICING_ENABLED="true"
run_step_capture configure_gpu_timeslicing
assert_subnot_called "kubectl apply" "timeslice: skips when NVIDIA disabled"

# ── Test 2: skips when GPU_TIMESLICING_ENABLED=false ─────────────────────────
INSTALL_NVIDIA="true"; GPU_TIMESLICING_ENABLED="false"
run_step_capture configure_gpu_timeslicing
assert_subnot_called "kubectl apply" "timeslice: skips when flag false"

# ── Test 3: ConfigMap contains correct replica count ─────────────────────────
INSTALL_NVIDIA="true"; GPU_TIMESLICING_ENABLED="true"; GPU_TIMESLICE_COUNT=8
NS_GPU_OPERATOR="gpu-operator"
# Make the kubectl stub return a ClusterPolicy name for discovery
_SUBCALLS=""
set +e
_SUBCALLS=$(
  source "$ROOT/lib/logging.sh"   2>/dev/null || true
  source "$ROOT/lib/config.sh"    2>/dev/null || true
  source "$ROOT/lib/helpers.sh"   2>/dev/null || true
  source "$ROOT/lib/checks.sh"    2>/dev/null || true
  source "$ROOT/lib/node_scripts.sh" 2>/dev/null || true
  source "$ROOT/steps/12_gpu_timeslice.sh" 2>/dev/null || true
  trap - ERR 2>/dev/null || true
  run_on(){ true; }; run_script_on(){ true; }
  ensure_sudo_pass(){ true; }; fetch_file_from(){ true; }
  _build_local_ip_cache(){ _LOCAL_IPS="127.0.0.1 localhost"; return 0; }
  _LOCAL_IPS="127.0.0.1 localhost"; is_local_node(){ return 1; }
  LOG_FILE=/dev/null
  log(){ true; }; warn(){ true; }; error(){ true; }
  info(){ true; }; section(){ true; }
  kubectl() {
    echo "kubectl $*"
    # Return a node list for label queries
    if [[ "$*" == *"gpu.present=true"* && "$*" == *"--no-headers"* ]]; then
      echo "gpu-node-01"
    fi
    # Return a ClusterPolicy name for discovery
    if [[ "$*" == *"clusterpolicy"* && "$*" == *"--no-headers"* ]]; then
      echo "cluster-policy"
    fi
    # Return a DaemonSet name for device plugin
    if [[ "$*" == *"daemonset"* && "$*" == *"--no-headers"* ]]; then
      echo "nvidia-device-plugin-daemonset"
    fi
    # Return virtual GPU count for verification
    if [[ "$*" == *"custom-columns"*"GPU"* ]]; then
      echo "gpu-node-01  8"
    fi
    [[ "$1" == "apply" && "$*" == *"-f -"* ]] && cat
    return 0
  }
  helm(){ echo "helm $*"; return 0; }
  INSTALL_NVIDIA="true"; GPU_TIMESLICING_ENABLED="true"; GPU_TIMESLICE_COUNT=8
  NS_GPU_OPERATOR="gpu-operator"
  # Set timeout to 0 so the CUDA validation wait loop exits immediately.
  # In a real cluster the wait polls until the operator is truly ready;
  # in tests we just verify the ConfigMap content and ClusterPolicy patch.
  GPU_OP_READY_TIMEOUT=0
  configure_gpu_timeslicing 2>/dev/null
)
set -e

# ConfigMap has the correct replica count
if echo "$_SUBCALLS" | grep -q "replicas: 8"; then
  _pass "timeslice: ConfigMap has correct replica count"
else
  _fail "timeslice: ConfigMap has correct replica count"
  echo "        Expected 'replicas: 8' in ConfigMap"
fi

# ClusterPolicy is patched without a -n namespace flag (cluster-scoped resource)
if echo "$_SUBCALLS" | grep -q "patch clusterpolicy"; then
  _pass "timeslice: ClusterPolicy patched"
  # Verify no namespace flag on the patch (ClusterPolicy is cluster-scoped)
  patch_line=""
  patch_line=$(echo "$_SUBCALLS" | grep "patch clusterpolicy" | head -1)
  if echo "$patch_line" | grep -q "\-n "; then
    _fail "timeslice: ClusterPolicy patch must NOT use -n namespace flag"
  else
    _pass "timeslice: ClusterPolicy patch has no -n namespace flag"
  fi
fi

# Node label applied using kubectl label (not lspci over SSH)
if echo "$_SUBCALLS" | grep -q "label node"; then
  _pass "timeslice: GPU node labelled"
else
  _fail "timeslice: GPU node labelled"
fi

# DaemonSet rollout triggered
if echo "$_SUBCALLS" | grep -q "rollout restart"; then
  _pass "timeslice: DaemonSet rollout restarted"
else
  _fail "timeslice: DaemonSet rollout restarted"
fi

summarise_test
