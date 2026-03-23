#!/usr/bin/env bash
# =============================================================================
# wizard/sections/summary.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

print_summary() {
  local worker_count=0
  if [[ "$WORKER_IPS_STR" != "()" && -n "${WORKER_IPS_STR:-}" ]]; then
    worker_count=$(echo "$WORKER_IPS_STR" | grep -o '"' | wc -l)
    worker_count=$((worker_count / 2))
  fi
  local worker_list="none (single-node)"
  (( worker_count > 0 )) && worker_list=$(echo "$WORKER_IPS_STR" | tr -d '()"' | xargs)

  local nvidia_status="${RED}✖ Skip${NC}"; [[ "$INSTALL_NVIDIA" == "true" ]] && nvidia_status="${GREEN}✔ driver-${NVIDIA_DRIVER_VERSION}${NC}"
  local mon_status="${RED}✖ Skip${NC}";    [[ "$INSTALL_MONITORING" == "true" ]] && mon_status="${GREEN}✔ v${PROM_STACK_VERSION}${NC}"
  local nfs_status="${RED}✖ Skip${NC}";    [[ "$INSTALL_NFS" == "true" ]] && nfs_status="${GREEN}✔ ${NFS_SERVER_IP}:${NFS_PATH}${NC}"
  local dash_status="${RED}✖ Skip${NC}";   [[ "$INSTALL_DASHBOARD" == "true" ]] && dash_status="${GREEN}✔ v${DASHBOARD_VERSION}${NC}"
  local vllm_status="${RED}✖ Skip${NC}";   [[ "$INSTALL_VLLM" == "true" ]] && vllm_status="${GREEN}✔ ${VLLM_NAMESPACE}${NC}"

  echo -e "  ${BOLD}${BLUE}── Nodes ─────────────────────────────────────────────────${NC}"
  echo -e "  Control plane  : ${CYAN}${CONTROL_PLANE_IP}${NC}"
  echo -e "  Workers        : ${CYAN}${worker_list}${NC}"
  echo -e "  SSH user       : ${CYAN}${SSH_USER}${NC}"
  echo -e "  SSH key        : ${CYAN}${SSH_KEY_PATH}${NC}"
  echo ""
  echo -e "  ${BOLD}${BLUE}── Kubernetes ────────────────────────────────────────────${NC}"
  echo -e "  Version        : ${CYAN}${K8S_VERSION}${NC}"
  echo -e "  CNI            : ${CYAN}${CNI_PLUGIN}${NC}"
  echo -e "  Pod CIDR       : ${CYAN}${POD_CIDR}${NC}"
  echo -e "  Helm           : ${CYAN}${HELM_VERSION}${NC}"
  echo ""
  echo -e "  ${BOLD}${BLUE}── Components ────────────────────────────────────────────${NC}"
  echo -e "  NVIDIA drivers : $(echo -e "${nvidia_status}")"
  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    echo -e "    kernel       : ${DIM}$([[ "$NVIDIA_OPEN_KERNEL" == "true" ]] && echo open || echo proprietary) | FM: ${NVIDIA_FABRIC_MANAGER} | reboot: ${NVIDIA_REBOOT_TIMEOUT}s${NC}"
  fi
  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    echo -e "  Monitoring     : $(echo -e "${mon_status}")  (ns: ${NS_MONITORING})"
    echo -e "    Grafana      : ${CYAN}http://${CONTROL_PLANE_IP}:${GRAFANA_NODEPORT}${NC}"
    echo -e "    Prometheus   : ${CYAN}http://${CONTROL_PLANE_IP}:${PROMETHEUS_NODEPORT}${NC}"
    echo -e "    Alertmanager : ${CYAN}http://${CONTROL_PLANE_IP}:${ALERTMANAGER_NODEPORT}${NC}"
    echo -e "    Retention    : ${CYAN}${PROM_RETENTION}${NC}  |  Storage: ${CYAN}${PROM_STORAGE_SIZE}${NC}"
  else
    echo -e "  Monitoring     : $(echo -e "${mon_status}")"
  fi
  if [[ "$INSTALL_NFS" == "true" ]]; then
    echo -e "  NFS            : $(echo -e "${nfs_status}")"
    echo -e "    StorageClass : ${CYAN}${NFS_STORAGE_CLASS}${NC}  (default: ${NFS_DEFAULT_SC})"
  else
    echo -e "  NFS            : $(echo -e "${nfs_status}")"
  fi
  [[ "$INSTALL_NVIDIA" == "true" ]] &&     echo -e "  GPU Operator   : ${GREEN}✔${NC}  (ns: ${NS_GPU_OPERATOR})"
  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    if [[ "${GPU_TIMESLICING_ENABLED:-false}" == "true" ]]; then
      echo -e "  GPU Timeslicing: ${GREEN}✔ ${GPU_TIMESLICE_COUNT}x virtual GPUs per physical GPU${NC}"
    else
      echo -e "  GPU Timeslicing: ${DIM}disabled${NC}"
    fi
  fi
  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    echo -e "  Dashboard      : $(echo -e "${dash_status}")"
    echo -e "    URL          : ${CYAN}https://${CONTROL_PLANE_IP}:${DASHBOARD_NODEPORT}${NC}"
  else
    echo -e "  Dashboard      : $(echo -e "${dash_status}")"
  fi
  if [[ "$INSTALL_VLLM" == "true" ]]; then
  echo -e "  vLLM Stack     : $(echo -e \"${vllm_status}\")"
  if [[ "$INSTALL_VLLM" == "true" ]]; then
    echo -e "    Router       : ${CYAN}http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1${NC}"
    if declare -p VLLM_MODELS &>/dev/null 2>&1 && [[ ${#VLLM_MODELS[@]} -gt 0 ]]; then
      echo -e "    Models (${#VLLM_MODELS[@]})  :"
      local _smi=1
      for _sm in "${VLLM_MODELS[@]}"; do
        IFS='|' read -r _smid _sgpu _ _ _ _ _smemr _ _ _ _ _spvc _squant _ _snodesel <<< "$_sm"
        echo -e "      ${_smi}) ${CYAN}${_smid}${NC}"
        echo -e "         GPUs: ${_sgpu}  Mem: ${_smemr}  PVC: ${_spvc}${_squant:+  quant: ${_squant}}${_snodesel:+  node: ${_snodesel}}"
        _smi=$(( _smi + 1 ))
      done
    else
      echo -e "    Model        : ${CYAN}${VLLM_MODEL}${NC}"
      echo -e "    dtype        : ${CYAN}${VLLM_DTYPE}${NC}  |  ctx: ${CYAN}${VLLM_MAX_MODEL_LEN}${NC} tokens"
      echo -e "    GPUs/replica : ${CYAN}${VLLM_GPU_COUNT}${NC}"
      if [[ "${VLLM_REUSE_PVC:-false}" == "true" ]]; then
        echo -e "    Model cache  : ${CYAN}${VLLM_PVC_NAME}${NC} (reuse existing)"
      else
        echo -e "    Model cache  : ${CYAN}${VLLM_PVC_NAME}${NC} (${VLLM_STORAGE_SIZE})"
      fi
    fi
      echo -e "    Storage      : ${CYAN}reuse PVC ${VLLM_PVC_NAME}${NC}"
    else
      echo -e "    Storage      : ${CYAN}new PVC ${VLLM_PVC_NAME} (${VLLM_STORAGE_SIZE})${NC}"
    fi
    [[ -n "${VLLM_EXTRA_ARGS:-}" ]] && echo -e "    Extra args   : ${DIM}${VLLM_EXTRA_ARGS}${NC}"
  else
    echo -e "  vLLM Stack     : $(echo -e "${vllm_status}")"
  if [[ "${INSTALL_VLLM:-false}" == "true" && "${VLLM_USE_RAY:-false}" == "true" ]]; then
    echo -e "  vLLM Backend   : ${CYAN}Ray cluster${NC} (ray://${NS_RAY:-ray} cluster)"
  fi
  fi
  echo ""
  echo -e "  ${BOLD}${BLUE}── Add-on Components ─────────────────────────────────────${NC}"
  _addon() {
    local name="$1" flag="$2" detail="${3:-}"
    if [[ "$flag" == "true" ]]; then
      echo -e "  ${GREEN}✔${NC}  ${name}${detail:+  ${DIM}${detail}${NC}}"
    else
      echo -e "  ${DIM}✖  ${name}${NC}"
    fi
  }
  _addon "Rook-Ceph"       "${INSTALL_CEPH:-false}"         "(${CEPH_REPLICA_COUNT:-3} replicas, dashboard :${CEPH_DASHBOARD_NODEPORT:-32101})"
  _addon "MinIO"           "${INSTALL_MINIO:-false}"        "(:${MINIO_NODEPORT_API:-32200} / :${MINIO_NODEPORT_CONSOLE:-32201})"
  _addon "ingress-nginx"   "${INSTALL_INGRESS:-false}"      "(:${INGRESS_NODEPORT_HTTP:-30080} / :${INGRESS_NODEPORT_HTTPS:-30443})"
  _addon "MetalLB"         "${INSTALL_METALLB:-false}"      "${METALLB_IP_RANGE:-}"
  _addon "cert-manager"    "${INSTALL_CERT_MANAGER:-false}" "(${CERT_MANAGER_ISSUER:-selfsigned})"
  _addon "CIS Hardening"   "${INSTALL_HARDEN:-false}"       ""
  _addon "Registry"        "${INSTALL_REGISTRY:-false}"     "(:${REGISTRY_NODEPORT:-32500}, auth=${REGISTRY_AUTH:-false})"
  _addon "ArgoCD"          "${INSTALL_ARGOCD:-false}"       "(:${ARGOCD_NODEPORT:-32600})"
  _addon "Loki+Promtail"   "${INSTALL_LOKI:-false}"         "(${LOKI_STORAGE_SIZE:-20Gi})"
  _addon "KubeRay"         "${INSTALL_RAY:-false}"          "(Ray ${RAY_VERSION:-2.9.3}, ${RAY_WORKER_REPLICAS:-1} worker(s), GPU=${RAY_WORKER_GPU:-0}, :${RAY_DASHBOARD_NODEPORT:-32800})"
  echo -e "  ${DIM}Backups: ${BACKUP_DIR:-./backups} (keep ${BACKUP_KEEP:-5})${NC}"
  unset -f _addon
  echo ""
  echo -e "  ${DIM}Config will be saved to: ${CONFIG_FILE}${NC}"
  echo ""
}

confirm_summary() {
  section_header "Configuration Summary — Review Before Continuing" "10/10"

  while true; do
    print_summary

    echo -e "  ${BOLD}What would you like to do?${NC}"
    echo -e "    ${CYAN}y${NC}) Save and continue"
    echo -e "    ${CYAN}n${NC}) Abort"
    echo -e "    ${CYAN}1${NC}) Edit SSH & Access"
    echo -e "    ${CYAN}2${NC}) Edit Cluster Nodes"
    echo -e "    ${CYAN}3${NC}) Edit Kubernetes Settings"
    echo -e "    ${CYAN}4${NC}) Edit NVIDIA Drivers"
    echo -e "    ${CYAN}5${NC}) Edit Monitoring"
    echo -e "    ${CYAN}6${NC}) Edit NFS Provisioner"
    echo -e "    ${CYAN}7${NC}) Edit Kubernetes Dashboard"
    echo -e "    ${CYAN}8${NC}) Edit vLLM Stack"
    echo -e "    ${CYAN}9${NC}) Edit Namespaces"
    echo -e "    ${CYAN}a${NC}) Edit Add-on Components"
    echo -e "    ${CYAN}p${NC}) Run pre-flight checks"
    echo ""
    local choice; read -e -p "  ${RL_S}${BOLD}${RL_E}Choice${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}[y/n/1-9/p]${RL_S}${NC}${RL_E}: " choice
    case "${choice,,}" in
      y|yes|"") show_progress; return ;;
      n|no)     echo ""; warn_msg "Configuration cancelled."; exit 0 ;;
      1) CURRENT_SECTION=0; collect_ssh ;;
      2) CURRENT_SECTION=1; collect_nodes ;;
      3) CURRENT_SECTION=2; collect_k8s ;;
      4) CURRENT_SECTION=3; collect_nvidia ;;
      5) CURRENT_SECTION=4; collect_monitoring ;;
      6) CURRENT_SECTION=5; collect_nfs ;;
      7) CURRENT_SECTION=6; collect_dashboard ;;
      8) CURRENT_SECTION=7; collect_vllm ;;
      9) CURRENT_SECTION=8; collect_namespaces ;;
      a|10) CURRENT_SECTION=9; collect_addons ;;
      p) run_preflight full ;;
      *) err "Invalid choice." ;;
    esac
    section_header "Configuration Summary — Review Before Continuing" "10/10"
  done
}

