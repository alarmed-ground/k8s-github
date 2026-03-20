#!/usr/bin/env bash
# =============================================================================
# 05_init.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

init_control_plane() {
  section "Step — Initializing Control Plane on ${CONTROL_PLANE_IP}"

  # Write the init script to a temp file directly (avoid heredoc-in-$() which
  # strips trailing newlines and can misfire under set -e).
  local init_file="/tmp/cp_init_$$.sh"

  # Quoted heredoc — outer variables injected via sed so the script is
  # completely literal inside the file, with no shell-expansion surprises.
  sed \
    -e "s|__CP_IP__|${CONTROL_PLANE_IP}|g" \
    -e "s|__POD_CIDR__|${POD_CIDR}|g" \
    -e "s|__SSH_USER__|${SSH_USER}|g" \
    > "$init_file" <<'INITEOF'
#!/usr/bin/env bash
set -euo pipefail

echo "[control-plane] Running kubeadm init..."
kubeadm init \
  --apiserver-advertise-address=__CP_IP__ \
  --pod-network-cidr=__POD_CIDR__ \
  --upload-certs 2>&1

# ── kubectl for root ──────────────────────────────────────────────────────────
echo "[control-plane] Configuring kubectl for root..."
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

# ── kubectl for SSH_USER (if different from root) ─────────────────────────────
SSH_USER_HOME=$(getent passwd "__SSH_USER__" | cut -d: -f6 2>/dev/null || echo "/home/__SSH_USER__")
if [[ -d "${SSH_USER_HOME}" && "${SSH_USER_HOME}" != "/root" ]]; then
  echo "[control-plane] Configuring kubectl for __SSH_USER__ in ${SSH_USER_HOME}..."
  mkdir -p "${SSH_USER_HOME}/.kube"
  cp -f /etc/kubernetes/admin.conf "${SSH_USER_HOME}/.kube/config"
  chown __SSH_USER__:__SSH_USER__ "${SSH_USER_HOME}/.kube/config"
  chmod 600 "${SSH_USER_HOME}/.kube/config"
fi

# ── Join command for workers ───────────────────────────────────────────────────
echo "[control-plane] Generating join command..."
kubeadm token create --print-join-command > /tmp/k8s_join_command.txt
chmod 644 /tmp/k8s_join_command.txt
echo "[control-plane] Init complete."
INITEOF

  chmod 600 "$init_file"
  run_script_on "$CONTROL_PLANE_IP" "$init_file" || {
    error "kubeadm init failed on ${CONTROL_PLANE_IP}. Check the log above for details."
    rm -f "$init_file"
    exit 1
  }
  rm -f "$init_file"

  # ── Fetch kubeconfig to wherever kubectl runs on this installer machine ───────
  # Script always runs as root, so kubeconfig lives at /root/.kube/config.
  local local_kube_dir="/root/.kube"
  mkdir -p "$local_kube_dir"

  if is_local_node "$CONTROL_PLANE_IP"; then
    # kubeconfig is already at /root/.kube/config (written by init script as root)
    if [[ "${local_kube_dir}/config" != "/root/.kube/config" ]]; then
      cp -f /root/.kube/config "${local_kube_dir}/config"
      chmod 600 "${local_kube_dir}/config"
    fi
    log "kubeconfig ready at ${local_kube_dir}/config"
  else
    fetch_file_from "$CONTROL_PLANE_IP" \
      "/root/.kube/config" \
      "${local_kube_dir}/config"
    chmod 600 "${local_kube_dir}/config"
    log "kubeconfig fetched to ${local_kube_dir}/config"
  fi

  export KUBECONFIG="${local_kube_dir}/config"

  # ── Fetch join command ────────────────────────────────────────────────────────
  # For a local control plane the file is already on this machine — only copy
  # if source and destination differ (cp refuses to copy a file onto itself).
  local join_src="/tmp/k8s_join_command.txt"
  local join_dst="/tmp/k8s_join_command.txt"
  if is_local_node "$CONTROL_PLANE_IP"; then
    log "Join command already at ${join_dst} (local control plane)."
  else
    fetch_file_from "$CONTROL_PLANE_IP" "$join_src" "$join_dst"
    log "Join command fetched to ${join_dst}"
  fi
}

