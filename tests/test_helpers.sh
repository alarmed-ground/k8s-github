#!/usr/bin/env bash
# =============================================================================
# test_helpers.sh — Mock framework for Level 2 unit tests
# Source this file at the top of every Level 2 test.
# =============================================================================

# ── Call recorder ────────────────────────────────────────────────────────────
declare -a _TEST_CALLS=()
declare -i _TEST_PASS=0 _TEST_FAIL=0
_TEST_NAME="${_TEST_NAME:-unnamed}"

# Stub external commands — record calls without executing anything
kubectl()        { _TEST_CALLS+=("kubectl $*"); }
helm()           { _TEST_CALLS+=("helm $*");    }
ssh()            { _TEST_CALLS+=("ssh $*"); return 0; }
scp()            { _TEST_CALLS+=("scp $*"); return 0; }
curl()           { _TEST_CALLS+=("curl $*"); return 0; }
run_on()         { _TEST_CALLS+=("run_on $*"); return 0; }
run_script_on()  { _TEST_CALLS+=("run_script_on $*"); return 0; }
ensure_sudo_pass(){ return 0; }
reboot_and_wait(){ return 0; }
_build_local_ip_cache() { _LOCAL_IPS="127.0.0.1 localhost"; }
fetch_file_from(){ return 0; }

reset_calls() { _TEST_CALLS=(); }

assert_called() {
  local pattern="$1" label="${2:-assert_called: $1}"
  for call in "${_TEST_CALLS[@]:-}"; do
    [[ "$call" == *"$pattern"* ]] && { _pass "$label"; return 0; }
  done
  _fail "$label"
  echo "        Expected call matching: '${pattern}'"
  echo "        Actual calls:"
  for c in "${_TEST_CALLS[@]:-}"; do echo "          ${c}"; done
  return 1
}

assert_not_called() {
  local pattern="$1" label="${2:-assert_not_called: $1}"
  for call in "${_TEST_CALLS[@]:-}"; do
    if [[ "$call" == *"$pattern"* ]]; then
      _fail "$label"
      echo "        Unexpected call: '${call}'"
      return 1
    fi
  done
  _pass "$label"
  return 0
}

assert_eq() {
  local actual="$1" expected="$2" label="${3:-assert_eq}"
  if [[ "$actual" == "$expected" ]]; then
    _pass "$label"
  else
    _fail "$label"
    echo "        Expected: '${expected}'"
    echo "        Actual:   '${actual}'"
    return 1
  fi
}

assert_neq() {
  local actual="$1" expected="$2" label="${3:-assert_neq}"
  if [[ "$actual" != "$expected" ]]; then
    _pass "$label"
  else
    _fail "$label"
    echo "        Should NOT equal: '${expected}'"
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-assert_contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    _pass "$label"
  else
    _fail "$label"
    echo "        String '${needle}' not found in output"
    return 1
  fi
}

_pass() { echo "  PASS  ${1}"; _TEST_PASS=$(( _TEST_PASS + 1 )); }
_fail() { echo "  FAIL  ${1}"; _TEST_FAIL=$(( _TEST_FAIL + 1 )); }

# ── Shared bootstrap for tests that need the entry point loaded ───────────────
bootstrap_installer() {
  local root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  export SCRIPT_DIR="$root"
  export LIB_DIR="${root}/lib"
  export STEPS_DIR="${root}/steps"
  export LOG_FILE=/dev/null
  export LATEST_LOG=/dev/null
  export LOCK_FILE=/tmp/k8s_test_lock_$$
  # Point CONFIG_FILE at a non-existent path so no real config is loaded.
  # Must be set before sourcing the entry point (config is loaded at source time).
  export CONFIG_FILE=/tmp/k8s_test_no_config_$$
  export K8S_SOURCE_ONLY=true
  # Unset any variables that may have leaked from a real conf in the environment
  unset CONTROL_PLANE_IP WORKER_IPS NFS_SERVER_IP VLLM_HF_TOKEN 2>/dev/null || true
  # Suppress all output — tests check behaviour, not log output
  log()     { true; }; warn()    { true; }
  error()   { true; }; info()    { true; }; section() { true; }
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
  # Source entry point — K8S_SOURCE_ONLY=true skips _source_modules and the
  # CLI dispatch block will not run because we are being sourced, not executed.
  # shellcheck source=/dev/null
  source "${root}/k8s_cluster_setup.sh" 2>/dev/null || true
  # Source modules in explicit dependency order (same as _source_modules in entry point)
  # lib must come before steps; within lib, helpers before checks before node_scripts
  local _mods=(
    "${root}/lib/logging.sh"
    "${root}/lib/config.sh"
    "${root}/lib/helpers.sh"
    "${root}/lib/checks.sh"
    "${root}/lib/node_scripts.sh"
    "${root}/steps/01_ssh.sh"
    "${root}/steps/02_prep.sh"
    "${root}/steps/03_nvidia.sh"
    "${root}/steps/04_k8s_bins.sh"
    "${root}/steps/05_init.sh"
    "${root}/steps/06_cni.sh"
    "${root}/steps/07_workers.sh"
    "${root}/steps/08_helm.sh"
    "${root}/steps/09_nfs.sh"
    "${root}/steps/10_monitoring.sh"
    "${root}/steps/11_gpu_operator.sh"
    "${root}/steps/12_gpu_timeslice.sh"
    "${root}/steps/13_dashboard.sh"
    "${root}/steps/14_vllm.sh"
    "${root}/steps/15_verify.sh"
    "${root}/steps/addon_ceph.sh"
    "${root}/steps/addon_minio.sh"
    "${root}/steps/addon_ingress.sh"
    "${root}/steps/addon_metallb.sh"
    "${root}/steps/addon_cert_manager.sh"
    "${root}/steps/addon_harden.sh"
    "${root}/steps/addon_registry.sh"
    "${root}/steps/addon_argocd.sh"
    "${root}/steps/addon_loki.sh"
    "${root}/steps/ops_backup.sh"
    "${root}/steps/ops_certs.sh"
    "${root}/steps/ops_upgrade.sh"
    "${root}/steps/ops_nodes.sh"
    "${root}/steps/ops_vllm_swap.sh"
    "${root}/steps/uninstall.sh"
  )
  for _f in "${_mods[@]}"; do
    # shellcheck source=/dev/null
    [[ -f "$_f" ]] && source "$_f" 2>/dev/null || true
  done

  # Re-apply stubs AFTER sourcing modules so module-defined wrappers
  # (run_on, run_script_on, etc.) do not shadow our test stubs
  kubectl()         { _TEST_CALLS+=("kubectl $*"); }
  helm()            { _TEST_CALLS+=("helm $*"); }
  ssh()             { _TEST_CALLS+=("ssh $*"); return 0; }
  scp()             { _TEST_CALLS+=("scp $*"); return 0; }
  curl()            { _TEST_CALLS+=("curl $*"); return 0; }
  run_on()          { _TEST_CALLS+=("run_on $*"); return 0; }
  run_script_on()   { _TEST_CALLS+=("run_script_on $*"); return 0; }
  ensure_sudo_pass(){ return 0; }
  reboot_and_wait() { return 0; }
  fetch_file_from() { return 0; }
  _build_local_ip_cache() { _LOCAL_IPS="127.0.0.1 localhost"; return 0; }
  _LOCAL_IPS="127.0.0.1 localhost"
  # Reset ERR trap — the installer sets one that would fire on return $_rc
  # when a subshell exits non-zero, killing the test process.
  trap - ERR 2>/dev/null || true
}

# Run a step function in the CURRENT shell (mutations to variables ARE visible
# in the calling test). Uses set +e so non-zero returns do not abort the test.
# WARNING: if the function calls exit, the whole test process will exit.
# Only use this when you need to observe variable mutations.
run_in_shell() {
  local _fn="$1"; shift
  set +e
  "$_fn" "$@" 2>/dev/null
  local _rc=$?
  set -e
  return $_rc
}

# Run a step function in a subshell so that internal `exit` calls do not
# kill the test process. Returns the subshell exit code.
# Usage: run_step_noabort <function_name> [args...]
run_step_noabort() {
  local _fn="$1"; shift
  # Export all test state into the subshell via a temp env file
  local _env_file; _env_file=$(mktemp /tmp/k8s_test_env_XXXXXX.sh)
  # Capture key variables that tests manipulate
  declare -p INSTALL_CEPH INSTALL_MINIO INSTALL_INGRESS INSTALL_METALLB     INSTALL_CERT_MANAGER INSTALL_HARDEN INSTALL_REGISTRY INSTALL_ARGOCD     INSTALL_LOKI INSTALL_VLLM INSTALL_NVIDIA INSTALL_NFS INSTALL_MONITORING     CONTROL_PLANE_IP NFS_SERVER_IP METALLB_IP_RANGE CERT_MANAGER_ISSUER     CERT_MANAGER_EMAIL NS_CERT_MANAGER NS_METALLB NS_CEPH CEPH_REPLICA_COUNT     CEPH_USE_ALL_NODES CEPH_USE_ALL_DEVICES CEPH_DEVICE_FILTER     CEPH_DASHBOARD_NODEPORT CEPH_DEFAULT_SC CEPH_WAIT_TIMEOUT ROOK_WAIT_TIMEOUT     CNI_PLUGIN CNI_WAIT_TIMEOUT GPU_TIMESLICING_ENABLED GPU_TIMESLICE_COUNT NS_GPU_OPERATOR     KUBECONFIG 2>/dev/null >> "$_env_file" || true
  declare -p WORKER_IPS 2>/dev/null >> "$_env_file" || true
  # Run in subshell — exit inside the function kills subshell, not this process
  local _out _rc
  set +e
  _out=$(
    source "$_env_file" 2>/dev/null || true
    # Re-apply test stubs in the subshell
    LOG_FILE=/dev/null
    log(){ true; }; warn(){ true; }; error(){ true; }
    info(){ true; }; section(){ true; }
    kubectl() { true; }; helm() { true; }
    run_on() { true; }; run_script_on() { true; }
    ensure_sudo_pass() { true; }; fetch_file_from() { true; }
    # Source the installer modules so the function is available
    source "${ROOT}/k8s_cluster_setup.sh" 2>/dev/null || true
    for _mf in       "${ROOT}/lib/logging.sh" "${ROOT}/lib/config.sh" "${ROOT}/lib/helpers.sh" "${ROOT}/lib/checks.sh"       "${ROOT}/lib/node_scripts.sh" "${ROOT}/steps/"*.sh; do
      [[ -f "$_mf" ]] && source "$_mf" 2>/dev/null || true
    done
    trap - ERR 2>/dev/null || true
    run_on() { true; }; run_script_on() { true; }
    ensure_sudo_pass() { true; }; fetch_file_from() { true; }
    reboot_and_wait() { true; }
    _build_local_ip_cache() { _LOCAL_IPS="127.0.0.1 localhost"; return 0; }
    _LOCAL_IPS="127.0.0.1 localhost"
    is_local_node() { return 1; }
    kubectl() { echo "kubectl $*"; }
    helm() { echo "helm $*"; }
    "$_fn" "$@" 2>&1
  )
  _rc=$?
  echo "$_out"
  rm -f "$_env_file"
  return $_rc
}

# Variant that also captures kubectl/helm calls into _SUBCALLS for assertion
run_step_capture() {
  local _fn="$1"; shift
  _SUBCALLS=""
  local _env_file; _env_file=$(mktemp /tmp/k8s_test_env_XXXXXX.sh)
  declare -p INSTALL_CEPH INSTALL_MINIO INSTALL_INGRESS INSTALL_METALLB     INSTALL_CERT_MANAGER INSTALL_HARDEN INSTALL_REGISTRY INSTALL_ARGOCD     INSTALL_LOKI INSTALL_VLLM INSTALL_NVIDIA INSTALL_NFS INSTALL_MONITORING     CONTROL_PLANE_IP NFS_SERVER_IP METALLB_IP_RANGE CERT_MANAGER_ISSUER     CERT_MANAGER_EMAIL NS_CERT_MANAGER NS_METALLB NS_CEPH CEPH_REPLICA_COUNT     CEPH_USE_ALL_NODES CEPH_USE_ALL_DEVICES CEPH_DEVICE_FILTER     CEPH_DASHBOARD_NODEPORT CEPH_DEFAULT_SC CEPH_WAIT_TIMEOUT ROOK_WAIT_TIMEOUT     CNI_PLUGIN CNI_WAIT_TIMEOUT GPU_TIMESLICING_ENABLED GPU_TIMESLICE_COUNT NS_GPU_OPERATOR     KUBECONFIG 2>/dev/null >> "$_env_file" || true
  declare -p WORKER_IPS 2>/dev/null >> "$_env_file" || true
  set +e
  _SUBCALLS=$(
    source "$_env_file" 2>/dev/null || true
    LOG_FILE=/dev/null
    log(){ true; }; warn(){ true; }; error(){ true; }
    info(){ true; }; section(){ true; }
    run_on() { true; }; run_script_on() { true; }
    ensure_sudo_pass() { true; }; fetch_file_from() { true; }
    kubectl() { echo "kubectl $*"; }
    helm() { echo "helm $*"; }
    source "${ROOT}/k8s_cluster_setup.sh" 2>/dev/null || true
    for _mf in       "${ROOT}/lib/logging.sh" "${ROOT}/lib/config.sh" "${ROOT}/lib/helpers.sh" "${ROOT}/lib/checks.sh"       "${ROOT}/lib/node_scripts.sh" "${ROOT}/steps/"*.sh; do
      [[ -f "$_mf" ]] && source "$_mf" 2>/dev/null || true
    done
    trap - ERR 2>/dev/null || true
    run_on() { true; }; run_script_on() { true; }
    ensure_sudo_pass() { true; }; fetch_file_from() { true; }
    reboot_and_wait() { true; }
    _build_local_ip_cache() { _LOCAL_IPS="127.0.0.1 localhost"; return 0; }
    _LOCAL_IPS="127.0.0.1 localhost"
    is_local_node() { return 1; }
    kubectl() {
      echo "kubectl $*"
      # When apply reads from stdin, capture that too so YAML content is searchable
      if [[ "$1" == "apply" && "$*" == *"-f -"* ]]; then
        cat
      fi
    }
    helm() { echo "helm $*"; }
    "$_fn" "$@" 2>/dev/null
  )
  local _rc=$?
  rm -f "$_env_file"
  return $_rc
}

assert_subcalled() {
  local pattern="$1" label="${2:-assert_subcalled: $1}"
  if echo "$_SUBCALLS" | grep -q "$pattern"; then
    _pass "$label"
  else
    _fail "$label"
    echo "        Expected call matching: '${pattern}'"
    echo "        Actual calls: $(echo "$_SUBCALLS" | head -5)"
    return 1
  fi
}

assert_subcontains() {
  local pattern="$1" label="${2:-assert_subcontains: $1}"
  assert_subcalled "$pattern" "$label"
}

assert_subnot_called() {
  local pattern="$1" label="${2:-assert_subnot_called: $1}"
  if echo "$_SUBCALLS" | grep -q "$pattern"; then
    _fail "$label"
    echo "        Unexpected call matching: '${pattern}'"
    return 1
  else
    _pass "$label"
  fi
}

# Call at the end of each test file to enforce pass/fail exit code
summarise_test() {
  local total=$(( _TEST_PASS + _TEST_FAIL ))
  echo ""
  echo "  ${_TEST_NAME}: ${_TEST_PASS}/${total} assertions passed"
  [[ $_TEST_FAIL -eq 0 ]]
}
