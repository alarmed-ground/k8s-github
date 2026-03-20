#!/usr/bin/env bash
# =============================================================================
# 09_nfs.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_nfs_provisioner() {
  section "Step — NFS External Provisioner"
  # KUBECONFIG exported globally after init_control_plane

  if [[ "${INSTALL_NFS}" != "true" ]]; then
    warn "INSTALL_NFS=false — skipping NFS provisioner."
    return
  fi

  if [[ -z "${NFS_SERVER_IP:-}" ]]; then
    warn "NFS_SERVER_IP not configured — skipping NFS provisioner."
    return
  fi

  # ── Step A: Install nfs-common on every cluster node ─────────────────────────
  # The provisioner pod mounts NFS volumes on whichever node it's scheduled on.
  # Without nfs-common the mount syscall fails and the pod hangs → deadline exceeded.
  info "Installing nfs-common on all cluster nodes..."
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  for node in "${all_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    info "  Installing nfs-common on ${node}..."
    run_on "$node" \
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common 2>&1" || {
        warn "nfs-common install may have failed on ${node} — continuing."
      }
  done

  # ── Step B: Configure NFS server export (if server is a managed node) ────────
  if [[ "$NFS_SERVER_IP" == "$CONTROL_PLANE_IP" ]] || \
     printf '%s\n' "${WORKER_IPS[@]:-}" | grep -q "^${NFS_SERVER_IP}$"; then
    info "Configuring NFS export on ${NFS_SERVER_IP}..."

    local nfs_setup_script="/tmp/nfs_server_setup_$$.sh"
    cat > "$nfs_setup_script" <<NFSSCRIPT
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq nfs-kernel-server

# Create and permission the export directory
mkdir -p "${NFS_PATH}"
chown nobody:nogroup "${NFS_PATH}"
chmod 755 "${NFS_PATH}"

# Add export entry if not already present
if ! grep -qF "${NFS_PATH}" /etc/exports; then
  echo "${NFS_PATH} *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
fi

exportfs -ra
systemctl enable --now nfs-kernel-server

# Verify the export is live before returning
sleep 2
if showmount -e localhost 2>/dev/null | grep -q "${NFS_PATH}"; then
  echo "[nfs-server] Export verified: ${NFS_PATH}"
else
  echo "[nfs-server] WARNING: export not showing in showmount — check /etc/exports" >&2
fi
NFSSCRIPT
    chmod 600 "$nfs_setup_script"
    run_script_on "$NFS_SERVER_IP" "$nfs_setup_script" || {
      error "NFS server setup failed on ${NFS_SERVER_IP}."
      rm -f "$nfs_setup_script"
      exit 1
    }
    rm -f "$nfs_setup_script"
    log "NFS export configured on ${NFS_SERVER_IP}."
  else
    info "NFS server ${NFS_SERVER_IP} is external — ensure ${NFS_PATH} is already exported."
  fi

  # ── Step C: Verify NFS server is reachable from the installer machine ─────────
  info "Verifying NFS server ${NFS_SERVER_IP} is reachable..."
  if command -v showmount &>/dev/null; then
    if showmount -e "$NFS_SERVER_IP" 2>/dev/null | grep -q "${NFS_PATH}"; then
      log "NFS export ${NFS_PATH} confirmed reachable on ${NFS_SERVER_IP}."
    else
      warn "Cannot verify NFS export via showmount — check firewall rules on ${NFS_SERVER_IP}."
      warn "Required ports: 2049/tcp (NFS), 111/tcp+udp (portmapper)."
      warn "Continuing — provisioner pod may fail to start if NFS is unreachable."
    fi
  fi

  # ── Step D: Deploy Helm chart ─────────────────────────────────────────────────
  helm repo add nfs-subdir-external-provisioner \
    https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_NFS" --dry-run=client -o yaml | kubectl apply -f -

  # Deploy without --wait first so we can inspect pod state on failure
  helm upgrade --install nfs-subdir-external-provisioner \
    nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --namespace "$NS_NFS" \
    --set nfs.server="${NFS_SERVER_IP}" \
    --set nfs.path="${NFS_PATH}" \
    --set storageClass.name="${NFS_STORAGE_CLASS}" \
    --set storageClass.defaultClass="${NFS_DEFAULT_SC}" \
    --set storageClass.reclaimPolicy=Retain \
    --set storageClass.archiveOnDelete=false

  # ── Step E: Wait for provisioner pod to be Running ───────────────────────────
  info "Waiting for NFS provisioner pod to become Ready (up to 5m)..."
  local elapsed=0 pod_ready=false
  while (( elapsed < 300 )); do
    local pod_status
    pod_status=$(kubectl get pods -n "$NS_NFS" \
      -l "app=nfs-subdir-external-provisioner" \
      --no-headers 2>/dev/null | awk '{print $3}' | head -1)

    if [[ "$pod_status" == "Running" ]]; then
      pod_ready=true
      break
    fi

    if [[ "$pod_status" == "CrashLoopBackOff" || "$pod_status" == "Error" ]]; then
      warn "NFS provisioner pod is in ${pod_status} state — printing logs..."
      kubectl logs -n "$NS_NFS" \
        -l "app=nfs-subdir-external-provisioner" --tail=40 2>/dev/null || true
      break
    fi

    info "  Pod status: ${pod_status:-Pending} (${elapsed}s elapsed) — waiting..."
    sleep 10
    elapsed=$(( elapsed + 10 ))
  done

  if $pod_ready; then
    log "NFS provisioner deployed. StorageClass: ${NFS_STORAGE_CLASS} (default: ${NFS_DEFAULT_SC})."
  else
    # Show diagnostics but do NOT exit — monitoring can still deploy
    warn "NFS provisioner pod did not reach Running state after 5m."
    warn "Run these to diagnose:"
    warn "  kubectl get pods -n ${NS_NFS} -o wide"
    warn "  kubectl describe pod -n ${NS_NFS} -l app=nfs-subdir-external-provisioner"
    warn "  kubectl logs -n ${NS_NFS} -l app=nfs-subdir-external-provisioner"
    warn "Common causes: nfs-common missing on nodes, NFS port 2049 blocked, wrong NFS path."
    kubectl get pods -n "$NS_NFS" -o wide 2>/dev/null || true
  fi
}

