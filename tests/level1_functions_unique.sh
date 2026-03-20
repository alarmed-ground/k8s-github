#!/usr/bin/env bash
# Level 1 — Every expected step function is declared exactly once after sourcing
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

EXPECTED=(
  setup_ssh_keys prepare_all_nodes install_nvidia_drivers install_k8s_binaries
  init_control_plane install_cni join_workers install_helm install_nfs_provisioner
  install_monitoring install_gpu_operator configure_gpu_timeslicing
  install_dashboard install_vllm verify_cluster
  backup_cluster restore_cluster renew_certs upgrade_cluster
  add_node remove_node install_ceph install_minio install_ingress
  install_metallb install_cert_manager harden_cluster install_registry
  install_argocd install_loki vllm_swap uninstall_cluster
  log warn error info section
  ensure_sudo_pass ssh_exec ssh_sudo scp_and_run run_on run_script_on
  fetch_file_from is_local_node reboot_and_wait
  check_root check_lock validate_config
  generate_node_prep_script generate_nvidia_install_script
  generate_nvidia_postboot_script generate_k8s_binaries_script
)

# Source all modules in a controlled subshell with external commands stubbed
# Write an isolated bootstrap script to a temp file to avoid heredoc quoting issues
_iso_script=$(mktemp /tmp/k8s_test_iso_XXXXXX.sh)
cat > "$_iso_script" << ISOEOF
#!/usr/bin/env bash
set -uo pipefail
kubectl() { true; }; helm() { true; }; ssh() { true; }
scp() { true; }; curl() { true; }; apt-get() { true; }
LOG_FILE=/dev/null; LATEST_LOG=/dev/null; LOCK_FILE=/dev/null
CONFIG_FILE=/tmp/k8s_no_conf_$$; K8S_SOURCE_ONLY=true
SCRIPT_DIR='${ROOT}'
LIB_DIR="\${SCRIPT_DIR}/lib"; STEPS_DIR="\${SCRIPT_DIR}/steps"
RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
log() { true; }; warn() { true; }; error() { true; }
info() { true; }; section() { true; }
source "\${SCRIPT_DIR}/k8s_cluster_setup.sh" 2>/dev/null || true
for f in "\${LIB_DIR}"/*.sh "\${STEPS_DIR}"/*.sh; do
  [[ -f "\$f" ]] && source "\$f" 2>/dev/null || true
done
declare -F | awk '{print \$3}'
ISOEOF
DECLARED=$(bash "$_iso_script" 2>/dev/null)
rm -f "$_iso_script"

FAIL=0
for fn in "${EXPECTED[@]}"; do
  count=$(echo "$DECLARED" | grep -c "^${fn}$" || true)
  if (( count == 1 )); then
    echo "  PASS  ${fn}"
  elif (( count == 0 )); then
    echo "  FAIL  ${fn} — NOT DECLARED"
    FAIL=$(( FAIL + 1 ))
  else
    echo "  FAIL  ${fn} — DECLARED ${count}x (duplicate!)"
    FAIL=$(( FAIL + 1 ))
  fi
done

(( FAIL == 0 )) || { echo "FAIL: ${FAIL} function(s) missing or duplicated"; exit 1; }
