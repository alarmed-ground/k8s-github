#!/usr/bin/env bash
# =============================================================================
# uninstall.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

_ask_tty() {
  local question="$1" default="${2:-n}"
  local prompt yn
  if [[ "$default" == "y" ]]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi
  echo -ne "\n  ${BOLD}${CYAN}${question} ${prompt}:${NC} " >/dev/tty
  read -r yn </dev/tty
  yn="${yn:-$default}"
  [[ "$yn" =~ ^[Yy] ]]
}

_ustage() {
  echo -e "\n${BOLD}${YELLOW}  ▶  $*${NC}" | tee -a "$LOG_FILE"
}

_try() {
  "$@" 2>&1 | tee -a "$LOG_FILE" || true
}

uninstall_cluster() {
  section "Kubernetes Cluster — UNINSTALL"
  # KUBECONFIG exported globally after init_control_plane

  echo -e "${RED}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║                  ⚠  DESTRUCTIVE OPERATION  ⚠                ║"
  echo "  ║                                                              ║"
  echo "  ║  This will permanently remove:                               ║"
  echo "  ║    • All Helm releases (monitoring, NFS, GPU op, dashboard,  ║"
  echo "  ║      vLLM, and any others)                                   ║"
  echo "  ║    • All Kubernetes namespaces and their workloads           ║"
  echo "  ║    • kubeadm / kubelet / kubectl / containerd on ALL nodes   ║"
  echo "  ║    • CNI configuration and iptables rules                    ║"
  echo "  ║    • Kubeconfig files                                        ║"
  echo "  ║                                                              ║"
  echo "  ║  Data on PersistentVolumes may also be deleted.              ║"
  echo "  ║  This action CANNOT be undone.                               ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  _ask_tty "Are you sure you want to completely uninstall the cluster?" "n" || {
    info "Uninstall cancelled."
    exit 0
  }

  # Second confirmation — type the word
  echo -ne "\n  ${BOLD}${RED}Type  DESTROY  to confirm: ${NC}" >/dev/tty
  local confirm_word
  read -r confirm_word </dev/tty
  if [[ "$confirm_word" != "DESTROY" ]]; then
    info "Confirmation word did not match — uninstall cancelled."
    exit 0
  fi

  warn "Starting uninstall... (log: ${LOG_FILE})"

  # ── Stage 1: Remove Helm releases ──────────────────────────────────────────
  _ustage "Stage 1 — Removing Helm releases"
  if command -v helm &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then

    # Collect all releases across all namespaces
    local releases
    releases=$(helm list --all-namespaces --short 2>/dev/null || true)

    if [[ -n "$releases" ]]; then
      info "Found Helm releases:"
      helm list --all-namespaces 2>/dev/null | tee -a "$LOG_FILE" || true

      if _ask_tty "Uninstall all Helm releases?" "y"; then
        while IFS= read -r release_line; do
          [[ -z "$release_line" ]] && continue
          local rel_name rel_ns
          rel_name=$(echo "$release_line" | awk '{print $1}')
          rel_ns=$(helm list --all-namespaces 2>/dev/null \
            | awk -v r="$rel_name" '$1==r {print $2; exit}')
          info "  Uninstalling ${rel_name} from namespace ${rel_ns:-unknown}..."
          _try helm uninstall "$rel_name" \
            ${rel_ns:+--namespace "$rel_ns"} \
            --wait --timeout=3m
        done <<< "$releases"
        log "All Helm releases removed."
      fi
    else
      info "No Helm releases found."
    fi
  else
    warn "kubectl or cluster unreachable — skipping Helm release removal."
  fi

  # ── Stage 2: Delete Kubernetes namespaces ──────────────────────────────────
  _ustage "Stage 2 — Deleting Kubernetes namespaces"
  if kubectl cluster-info &>/dev/null 2>&1; then
    local managed_ns=(
      "${NS_MONITORING:-monitoring}"
      "${NS_NFS:-nfs-provisioner}"
      "${NS_GPU_OPERATOR:-gpu-operator}"
      "${NS_DASHBOARD:-kubernetes-dashboard}"
      "${VLLM_NAMESPACE:-vllm}"
    )

    if _ask_tty "Delete managed namespaces (monitoring, NFS, GPU, dashboard, vLLM)?" "y"; then
      for ns in "${managed_ns[@]}"; do
        if kubectl get namespace "$ns" &>/dev/null 2>&1; then
          info "  Deleting namespace ${ns}..."
          _try kubectl delete namespace "$ns" --timeout=60s
        fi
      done
      log "Managed namespaces deleted."
    fi
  else
    warn "kubectl unreachable — skipping namespace deletion."
  fi

  # ── Stage 3: kubeadm reset on all nodes ────────────────────────────────────
  _ustage "Stage 3 — Running kubeadm reset on all nodes"
  if _ask_tty "Run 'kubeadm reset' on all nodes (removes k8s control plane + worker state)?" "y"; then

    local reset_script="/tmp/kubeadm_reset_$$.sh"
    cat > "$reset_script" <<'RESETSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
echo "[reset] Running kubeadm reset..."
kubeadm reset --force 2>&1 || true

echo "[reset] Flushing iptables..."
iptables -F && iptables -X && iptables -t nat -F && iptables -t nat -X \
  && iptables -t mangle -F && iptables -t mangle -X || true
ip6tables -F && ip6tables -X && ip6tables -t nat -F && ip6tables -t nat -X \
  && ip6tables -t mangle -F && ip6tables -t mangle -X 2>/dev/null || true
ipvsadm --clear 2>/dev/null || true

echo "[reset] Removing CNI configuration..."
rm -rf /etc/cni /opt/cni /var/lib/cni /run/flannel 2>/dev/null || true

echo "[reset] Removing Kubernetes state directories..."
rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd \
       /var/lib/dockershim /var/run/kubernetes 2>/dev/null || true

echo "[reset] Stopping and disabling kubelet..."
systemctl stop kubelet  2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

echo "[reset] Node reset complete."
RESETSCRIPT
    chmod 600 "$reset_script"

    local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
    for node in "${all_nodes[@]:-}"; do
      [[ -z "$node" ]] && continue
      info "  Resetting node ${node}..."
      run_script_on "$node" "$reset_script" || \
        warn "Reset script returned non-zero on ${node} — continuing."
    done
    rm -f "$reset_script"
    log "kubeadm reset complete on all nodes."
  fi

  # ── Stage 4: Remove Kubernetes packages ────────────────────────────────────
  _ustage "Stage 4 — Removing Kubernetes packages (kubeadm, kubelet, kubectl)"
  if _ask_tty "Remove kubeadm, kubelet, kubectl, and containerd from all nodes?" "y"; then

    local pkg_script="/tmp/k8s_pkg_remove_$$.sh"
    cat > "$pkg_script" <<'PKGSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "[pkg-remove] Removing Kubernetes packages..."
apt-get remove -y --purge kubeadm kubelet kubectl 2>&1 || true
apt-get autoremove -y 2>&1 || true

echo "[pkg-remove] Removing Kubernetes apt source..."
rm -f /etc/apt/sources.list.d/kubernetes.list \
      /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null || true
apt-get update -qq 2>/dev/null || true

echo "[pkg-remove] Removing leftover config files..."
rm -rf /root/.kube /home/*/.kube 2>/dev/null || true
rm -f  /usr/local/bin/helm 2>/dev/null || true

echo "[pkg-remove] Done."
PKGSCRIPT
    chmod 600 "$pkg_script"

    local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
    for node in "${all_nodes[@]:-}"; do
      [[ -z "$node" ]] && continue
      info "  Removing packages on ${node}..."
      run_script_on "$node" "$pkg_script" || \
        warn "Package removal returned non-zero on ${node} — continuing."
    done
    rm -f "$pkg_script"
    log "Kubernetes packages removed from all nodes."
  fi

  # ── Stage 5: Remove containerd ─────────────────────────────────────────────
  _ustage "Stage 5 — Removing containerd"
  if _ask_tty "Remove containerd from all nodes?" "y"; then

    local ctr_script="/tmp/containerd_remove_$$.sh"
    cat > "$ctr_script" <<'CTRSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "[containerd-remove] Stopping containerd..."
systemctl stop containerd 2>/dev/null || true
systemctl disable containerd 2>/dev/null || true

echo "[containerd-remove] Removing package..."
apt-get remove -y --purge containerd.io containerd 2>&1 || true
apt-get autoremove -y 2>&1 || true

echo "[containerd-remove] Removing Docker apt source..."
rm -f /etc/apt/sources.list.d/docker.list \
      /etc/apt/keyrings/docker.gpg 2>/dev/null || true

echo "[containerd-remove] Removing state directories..."
rm -rf /var/lib/containerd /etc/containerd /run/containerd 2>/dev/null || true

echo "[containerd-remove] Done."
CTRSCRIPT
    chmod 600 "$ctr_script"

    local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
    for node in "${all_nodes[@]:-}"; do
      [[ -z "$node" ]] && continue
      info "  Removing containerd on ${node}..."
      run_script_on "$node" "$ctr_script" || \
        warn "containerd removal returned non-zero on ${node} — continuing."
    done
    rm -f "$ctr_script"
    log "containerd removed from all nodes."
  fi

  # ── Stage 6: Remove NVIDIA components ──────────────────────────────────────
  if [[ "${INSTALL_NVIDIA:-false}" == "true" ]]; then
    _ustage "Stage 6 — Removing NVIDIA drivers and container toolkit"
    if _ask_tty "Remove NVIDIA drivers and container toolkit from GPU nodes?" "y"; then

      local nv_script="/tmp/nvidia_remove_$$.sh"
      cat > "$nv_script" <<'NVSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# Only run on nodes that have an NVIDIA GPU
if ! lspci 2>/dev/null | grep -qi nvidia; then
  echo "[nvidia-remove] No GPU detected — skipping."
  exit 0
fi

echo "[nvidia-remove] Stopping nvidia-persistenced..."
systemctl stop nvidia-persistenced 2>/dev/null || true
systemctl disable nvidia-persistenced 2>/dev/null || true

echo "[nvidia-remove] Removing NVIDIA packages..."
apt-get remove -y --purge \
  'nvidia-*' \
  'libnvidia-*' \
  nvidia-container-toolkit \
  nvidia-container-runtime \
  nvidia-docker2 \
  2>&1 || true
apt-get autoremove -y 2>&1 || true

echo "[nvidia-remove] Removing NVIDIA apt sources..."
rm -f /etc/apt/sources.list.d/nvidia*.list \
      /etc/apt/sources.list.d/cuda*.list \
      /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
      /etc/apt/keyrings/nvidia*.gpg 2>/dev/null || true

echo "[nvidia-remove] Restoring nouveau (re-enabling)..."
rm -f /etc/modprobe.d/blacklist-nvidia-nouveau.conf 2>/dev/null || true
update-initramfs -u 2>/dev/null || true

echo "[nvidia-remove] Done. A reboot is recommended."
NVSCRIPT
      chmod 600 "$nv_script"

      local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
      for node in "${all_nodes[@]:-}"; do
        [[ -z "$node" ]] && continue
        info "  Removing NVIDIA components on ${node}..."
        run_script_on "$node" "$nv_script" || \
          warn "NVIDIA removal returned non-zero on ${node} — continuing."
      done
      rm -f "$nv_script"
      log "NVIDIA components removed from GPU nodes."
    fi
  fi

  # ── Stage 7: Remove NFS server (optional) ──────────────────────────────────
  if [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_SERVER_IP:-}" ]]; then
    _ustage "Stage 7 — Removing NFS server configuration"
    if _ask_tty "Remove NFS server export and nfs-kernel-server from ${NFS_SERVER_IP}?" "n"; then

      local nfs_rm_script="/tmp/nfs_remove_$$.sh"
      cat > "$nfs_rm_script" <<NFSRM
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "[nfs-remove] Unexporting ${NFS_PATH}..."
sed -i "\|${NFS_PATH}|d" /etc/exports 2>/dev/null || true
exportfs -ra 2>/dev/null || true
systemctl stop nfs-kernel-server 2>/dev/null || true
systemctl disable nfs-kernel-server 2>/dev/null || true
apt-get remove -y --purge nfs-kernel-server 2>&1 || true
apt-get autoremove -y 2>&1 || true
echo "[nfs-remove] Done."
NFSRM
      chmod 600 "$nfs_rm_script"
      run_script_on "$NFS_SERVER_IP" "$nfs_rm_script" || \
        warn "NFS removal returned non-zero on ${NFS_SERVER_IP} — continuing."
      rm -f "$nfs_rm_script"

      if _ask_tty "Also delete the NFS data directory ${NFS_PATH} on ${NFS_SERVER_IP}?" "n"; then
        run_on "$NFS_SERVER_IP" "rm -rf '${NFS_PATH}'" || \
          warn "Could not delete ${NFS_PATH} on ${NFS_SERVER_IP}."
        log "NFS data directory ${NFS_PATH} deleted."
      fi
      log "NFS server configuration removed from ${NFS_SERVER_IP}."
    fi
  fi

  # ── Stage 8: Local cleanup ──────────────────────────────────────────────────
  _ustage "Stage 8 — Local cleanup (installer machine)"
  if _ask_tty "Remove local kubeconfig, lock file, and installer temp files?" "y"; then
    _try rm -f /root/.kube/config
    _try rm -f "$LOCK_FILE"
    _try rm -f /tmp/k8s_join_command.txt
    _try rm -f /root/dashboard-token.txt
    log "Local cleanup complete."
  fi

  section "Uninstall Complete"
  log "Cluster has been torn down."
  warn "A reboot of all nodes is recommended to clear any remaining kernel state."
  info "To reinstall, run: sudo bash $(basename "$0")"
}

