#!/usr/bin/env bash
# =============================================================================
# wizard/sections/launch.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

offer_launch() {
  echo ""
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo -e "  ${BOLD}  Configuration complete!${NC}"
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  To run the ${BOLD}full installer${NC}:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER}${NC}"
  echo ""
  echo -e "  To run a ${BOLD}single step${NC}:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER} --step <step-name>${NC}"
  echo ""
  printf "  ${BOLD}%-14s %-18s %s${NC}\n" "Step name" "Aliases" "Phase"
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "ssh"        ""                    "SSH key setup"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "prep"       "node-prep"            "Node preparation"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "nvidia"     ""                     "NVIDIA drivers"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "k8s-bins"   "k8s bins"             "Kubernetes binaries"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "init"       "control plane"        "Control plane init"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "cni"        "CNI"                  "CNI plugin"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "workers"    "join workers"         "Join worker nodes"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "helm"       "Helm"                 "Install Helm"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "nfs"        "NFS"                  "NFS provisioner"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "monitoring" "prometheus grafana"   "Monitoring stack"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "gpu-op"     "gpu operator"         "GPU Operator"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "dashboard"  "Dashboard"            "Kubernetes Dashboard"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "vllm"       "vLLM vLLM Stack"      "vLLM production stack"
  printf "  ${CYAN}%-14s${NC} ${DIM}%-18s${NC} %s\n" "verify"     "verification"         "Post-install check"
  echo ""
  echo -e "  To ${BOLD}re-run the wizard for a single section${NC}:"
  echo -e "    ${CYAN}bash ${BASH_SOURCE[0]} --section <name>${NC}"
  echo -e "    ${DIM}Sections: ssh nodes k8s nvidia monitoring nfs dashboard vllm namespaces${NC}"
  echo ""
  echo ""
  printf "  ${BOLD}%-20s %s${NC}
" "Step name" "Phase"
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${NC}"
  _row() { printf "  ${CYAN}%-20s${NC} %s
" "$1" "$2"; }
  _row "backup"          "etcd snapshot"
  _row "restore"         "etcd restore"
  _row "cert-renew"      "renew kubeadm certificates"
  _row "upgrade"         "in-place K8s version upgrade"
  _row "add-node"        "add a worker node"
  _row "remove-node"     "drain and remove a worker node"
  _row "ceph"            "Rook-Ceph distributed storage"
  _row "minio"           "MinIO object storage"
  _row "ingress"         "ingress-nginx"
  _row "metallb"         "MetalLB LoadBalancer"
  _row "cert-manager"    "TLS certificate automation"
  _row "harden"          "CIS hardening + kube-bench"
  _row "registry"        "private container registry"
  _row "argocd"          "ArgoCD GitOps"
  _row "loki"            "Loki + Promtail logging"
  _row "vllm-swap"       "swap vLLM model (zero-downtime)"
  unset -f _row
  echo ""
  echo -e "  To run ${BOLD}pre-flight checks${NC} only:"
  echo -e "    ${CYAN}bash ${BASH_SOURCE[0]} --preflight${NC}"
  echo ""
  echo -e "  To ${BOLD}uninstall${NC} the cluster:"
  echo -e "    ${CYAN}sudo bash ${INSTALLER} --uninstall${NC}"
  echo ""

  if [[ ! -f "$INSTALLER" ]]; then
    warn_msg "Installer script not found — cannot launch automatically."
    return
  fi

  prompt_yes_no LAUNCH_NOW "Launch the full installer now?" "n"
  if [[ "$LAUNCH_NOW" == "true" ]]; then
    echo ""
    if [[ $EUID -ne 0 ]]; then
      warn_msg "Re-launching with sudo..."
      exec sudo bash "$INSTALLER"
    else
      exec bash "$INSTALLER"
    fi
  else
    echo ""
    ok "Configuration saved. Run the installer when ready:"
    echo -e "    ${CYAN}sudo bash ${INSTALLER}${NC}"
  fi
}

run_section_menu() {
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE" 2>/dev/null || true
    # Rebuild WORKER_IPS_STR from the sourced array
    local arr_str="("
    for ip in "${WORKER_IPS[@]:-}"; do [[ -n "$ip" ]] && arr_str+="\"$ip\" "; done
    arr_str="${arr_str% })"; WORKER_IPS_STR="$arr_str"
    WORKER_COUNT=$(echo "${WORKER_IPS[@]:-}" | wc -w)
  fi

  while true; do
    echo ""
    echo -e "  ${BOLD}Which section do you want to edit?${NC}"
    echo -e "    ${CYAN}1${NC}) SSH & Access"
    echo -e "    ${CYAN}2${NC}) Cluster Nodes"
    echo -e "    ${CYAN}3${NC}) Kubernetes Settings"
    echo -e "    ${CYAN}4${NC}) NVIDIA Drivers"
    echo -e "    ${CYAN}5${NC}) Monitoring"
    echo -e "    ${CYAN}6${NC}) NFS Provisioner"
    echo -e "    ${CYAN}7${NC}) Kubernetes Dashboard"
    echo -e "    ${CYAN}8${NC}) vLLM Stack"
    echo -e "    ${CYAN}9${NC}) Namespaces"
    echo -e "    ${CYAN}a${NC}) Add-on Components"
    echo -e "    ${CYAN}q${NC}) Quit / cancel"
    local choice; read -e -p "  ${RL_S}${BOLD}${RL_E}Choice [1-9/a/q]${RL_S}${NC}${RL_E}: " choice
    CURRENT_SECTION=0
    case "${choice,,}" in
      1) collect_ssh;        break ;;
      2) collect_nodes;      break ;;
      3) collect_k8s;        break ;;
      4) collect_nvidia;     break ;;
      5) collect_monitoring; break ;;
      6) collect_nfs;        break ;;
      7) collect_dashboard;  break ;;
      8) collect_vllm;       break ;;
      9) collect_namespaces; break ;;
      a) collect_addons;     break ;;
      q|quit|exit) echo ""; ok "Cancelled."; exit 0 ;;
      *) err "Invalid choice — enter 1-9, a, or q." ;;
    esac
  done
  write_config
  patch_installer
  offer_launch
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --section)
        shift
        if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE" 2>/dev/null || true; fi
        local arr_str="("
        for ip in "${WORKER_IPS[@]:-}"; do [[ -n "$ip" ]] && arr_str+="\"$ip\" "; done
        arr_str="${arr_str% })"; WORKER_IPS_STR="${arr_str:-()}"
        WORKER_COUNT=$(echo "${WORKER_IPS[@]:-}" | wc -w)
        CURRENT_SECTION=0
        case "${1:-}" in
          ssh)        collect_ssh ;;
          nodes)      collect_nodes ;;
          k8s)        collect_k8s ;;
          nvidia)     collect_nvidia ;;
          monitoring) collect_monitoring ;;
          nfs)        collect_nfs ;;
          dashboard)  collect_dashboard ;;
          vllm)       collect_vllm ;;
          namespaces) collect_namespaces ;;
          addons)     collect_addons ;;
          *)
            err "Unknown section: ${1:-}"
            echo "  Valid sections: ssh nodes k8s nvidia monitoring nfs dashboard vllm namespaces"
            exit 1 ;;
        esac
        write_config; patch_installer; offer_launch; exit 0 ;;

      --preflight)
        if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE" 2>/dev/null || true; fi
        local arr_str="("
        for ip in "${WORKER_IPS[@]:-}"; do [[ -n "$ip" ]] && arr_str+="\"$ip\" "; done
        arr_str="${arr_str% })"; WORKER_IPS_STR="${arr_str:-()}"
        print_header
        run_preflight preflight-only
        exit 0 ;;

      --show)
        if [[ -f "$CONFIG_FILE" ]]; then
          echo ""
          echo -e "${BOLD}${CYAN}Current configuration (${CONFIG_FILE}):${NC}"
          echo ""
          cat "$CONFIG_FILE"
        else
          err "No config file found at ${CONFIG_FILE}"
          exit 1
        fi
        exit 0 ;;

      --help|-h)
        echo ""
        echo -e "${BOLD}Usage:${NC}"
        echo -e "  ${CYAN}bash k8s_configure.sh${NC}                    Full interactive wizard"
        echo -e "  ${CYAN}bash k8s_configure.sh --section <name>${NC}   Re-run a single section"
        echo -e "  ${CYAN}bash k8s_configure.sh --preflight${NC}        Pre-flight checks only"
        echo -e "  ${CYAN}bash k8s_configure.sh --show${NC}             Print current config"
        echo ""
        echo -e "${BOLD}Section names:${NC} ssh nodes k8s nvidia monitoring nfs dashboard vllm namespaces"
        echo ""
        exit 0 ;;

      *) err "Unknown argument: $1"; exit 1 ;;
    esac
    shift
  done
}

