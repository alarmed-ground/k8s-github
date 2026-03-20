#!/usr/bin/env bash
# =============================================================================
# ops_upgrade.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

upgrade_cluster() {
  section "Kubernetes Cluster Upgrade"

  local target="${K8S_UPGRADE_TO:-}"
  if [[ -z "$target" ]]; then
    info "Current version: ${K8S_VERSION}"
    echo -ne "  Target minor version (e.g. 1.32): "
    read -r target </dev/tty
  fi
  [[ -z "$target" ]] && { error "No target version provided."; exit 1; }

  warn "This will upgrade the cluster from ${K8S_VERSION} to ${target}."
  warn "All nodes will be drained and rebooted."
  echo -ne "  Type 'yes' to confirm: "
  local confirm; read -r confirm </dev/tty
  [[ "$confirm" != "yes" ]] && { info "Upgrade cancelled."; exit 0; }

  # ── Upgrade control plane ─────────────────────────────────────────────────
  info "Upgrading control plane to ${target}..."
  local cp_upgrade="/tmp/k8s_cp_upgrade_$$.sh"
  sed "s|K8S_VER_PLACEHOLDER|${target}|g" <<'CPUPGRADE' > "$cp_upgrade"
#!/usr/bin/env bash
set -euo pipefail
TARGET=K8S_VER_PLACEHOLDER

echo "[upgrade] Updating apt repository to v${TARGET}..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${TARGET}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${TARGET}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq

echo "[upgrade] Installing kubeadm ${TARGET}..."
apt-mark unhold kubeadm
apt-get install -y -qq kubeadm="$(apt-cache policy kubeadm | grep ${TARGET} | awk '{print $1}' | head -1)"
apt-mark hold kubeadm

echo "[upgrade] Running kubeadm upgrade plan..."
kubeadm upgrade plan "v${TARGET}" 2>&1

echo "[upgrade] Applying upgrade..."
kubeadm upgrade apply "v${TARGET}" --yes 2>&1

echo "[upgrade] Upgrading kubelet and kubectl..."
apt-mark unhold kubelet kubectl
apt-get install -y -qq \
  kubelet="$(apt-cache policy kubelet | grep ${TARGET} | awk '{print $1}' | head -1)" \
  kubectl="$(apt-cache policy kubectl | grep ${TARGET} | awk '{print $1}' | head -1)"
apt-mark hold kubelet kubectl

systemctl daemon-reload
systemctl restart kubelet
echo "[upgrade] Control plane upgraded to ${TARGET}."
CPUPGRADE
  chmod 600 "$cp_upgrade"
  run_script_on "$CONTROL_PLANE_IP" "$cp_upgrade" || {
    error "Control plane upgrade failed."
    rm -f "$cp_upgrade"
    exit 1
  }
  rm -f "$cp_upgrade"
  log "Control plane upgraded to ${target}."

  # ── Upgrade workers ───────────────────────────────────────────────────────
  for worker in "${WORKER_IPS[@]:-}"; do
    [[ -z "$worker" ]] && continue
    info "Draining worker ${worker}..."
    local node_name
    node_name=$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}{end}' \
      2>/dev/null | awk -v ip="$worker" '$2=="InternalIP" && $3==ip {print $1; exit}')
    if [[ -n "$node_name" ]]; then
      kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --timeout=120s || \
        warn "Drain returned non-zero — proceeding."
    fi

    local w_upgrade="/tmp/k8s_w_upgrade_$$.sh"
    sed "s|K8S_VER_PLACEHOLDER|${target}|g" <<'WUPGRADE' > "$w_upgrade"
#!/usr/bin/env bash
set -euo pipefail
TARGET=K8S_VER_PLACEHOLDER

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${TARGET}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${TARGET}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq

apt-mark unhold kubeadm kubelet kubectl
apt-get install -y -qq \
  kubeadm="$(apt-cache policy kubeadm | grep ${TARGET} | awk '{print $1}' | head -1)" \
  kubelet="$(apt-cache policy kubelet | grep ${TARGET} | awk '{print $1}' | head -1)" \
  kubectl="$(apt-cache policy kubectl | grep ${TARGET} | awk '{print $1}' | head -1)"
apt-mark hold kubeadm kubelet kubectl

kubeadm upgrade node 2>&1
systemctl daemon-reload
systemctl restart kubelet
echo "[upgrade] Worker upgraded to ${TARGET}."
WUPGRADE
    chmod 600 "$w_upgrade"
    run_script_on "$worker" "$w_upgrade" || {
      warn "Worker ${worker} upgrade returned non-zero — uncordoning and continuing."
    }
    rm -f "$w_upgrade"

    [[ -n "$node_name" ]] && kubectl uncordon "$node_name" && \
      log "Worker ${worker} (${node_name}) upgraded and uncordoned."
  done

  log "Cluster upgrade to ${target} complete."
  info "Update K8S_VERSION=${target} in k8s_cluster.conf to reflect the new version."
  kubectl get nodes
}

