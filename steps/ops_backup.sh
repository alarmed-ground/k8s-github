#!/usr/bin/env bash
# =============================================================================
# ops_backup.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

backup_cluster() {
  section "etcd Backup"

  mkdir -p "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local snapshot_file="${BACKUP_DIR}/etcd-snapshot-${ts}.db"
  local meta_file="${BACKUP_DIR}/etcd-snapshot-${ts}.meta"

  info "Taking etcd snapshot on ${CONTROL_PLANE_IP}..."

  # Write a remote snapshot script — etcdctl must run where etcd is listening
  local snap_script="/tmp/etcd_snap_$$.sh"
  sed "s|__SNAP__|${snapshot_file}|g" <<'SNAPEOF' > "$snap_script"
#!/usr/bin/env bash
set -euo pipefail
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save __SNAP__
echo "[backup] Snapshot saved to __SNAP__"
SNAPEOF
  chmod 600 "$snap_script"
  run_script_on "$CONTROL_PLANE_IP" "$snap_script" || {
    error "etcd snapshot failed."
    rm -f "$snap_script"
    exit 1
  }
  rm -f "$snap_script"

  # Fetch snapshot to local machine if control plane is remote
  if ! is_local_node "$CONTROL_PLANE_IP"; then
    info "Fetching snapshot from ${CONTROL_PLANE_IP}..."
    fetch_file_from "$CONTROL_PLANE_IP" "$snapshot_file" "$snapshot_file"
    run_on "$CONTROL_PLANE_IP" "rm -f '${snapshot_file}'" || true
  fi

  # Write metadata
  cat > "$meta_file" <<METAEOF
timestamp=${ts}
k8s_version=${K8S_VERSION}
control_plane=${CONTROL_PLANE_IP}
workers=${WORKER_IPS[*]:-}
snapshot=${snapshot_file}
METAEOF

  # Upload to S3 if configured
  if [[ -n "${BACKUP_S3_BUCKET:-}" ]]; then
    if command -v aws &>/dev/null; then
      info "Uploading snapshot to ${BACKUP_S3_BUCKET}..."
      aws s3 cp "$snapshot_file" "${BACKUP_S3_BUCKET}/etcd-snapshot-${ts}.db" \
        && log "Uploaded to S3 OK." \
        || warn "S3 upload failed — snapshot retained locally."
    else
      warn "BACKUP_S3_BUCKET set but 'aws' CLI not found — skipping upload."
      warn "Install: apt-get install -y awscli"
    fi
  fi

  # Prune old backups beyond BACKUP_KEEP
  local keep="${BACKUP_KEEP:-5}"
  local count
  count=$(ls -1 "${BACKUP_DIR}"/etcd-snapshot-*.db 2>/dev/null | wc -l)
  if (( count > keep )); then
    info "Pruning old backups (keeping ${keep} most recent)..."
    ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.db | tail -n +$(( keep + 1 )) | \
      xargs rm -f
    ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.meta 2>/dev/null | tail -n +$(( keep + 1 )) | \
      xargs rm -f 2>/dev/null || true
    log "Old backups pruned."
  fi

  log "Backup complete: ${snapshot_file}"
  info "To restore: sudo bash $(basename "$0") --step restore --backup ${snapshot_file}"
}

restore_cluster() {
  section "etcd Restore"

  local snapshot="${RESTORE_SNAPSHOT:-}"
  if [[ -z "$snapshot" ]]; then
    # List available backups
    local backups
    backups=$(ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.db 2>/dev/null || true)
    if [[ -z "$backups" ]]; then
      error "No backups found in ${BACKUP_DIR}. Run --step backup first."
      exit 1
    fi
    info "Available snapshots:"
    local i=1
    while IFS= read -r f; do
      local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1)
      info "  ${i}) ${f} (${sz})"
      i=$(( i + 1 ))
    done <<< "$backups"
    echo -ne "\n  Select snapshot number: "
    local choice; read -r choice </dev/tty
    snapshot=$(echo "$backups" | sed -n "${choice}p")
    [[ -z "$snapshot" ]] && { error "Invalid selection."; exit 1; }
  fi

  [[ ! -f "$snapshot" ]] && { error "Snapshot file not found: ${snapshot}"; exit 1; }

  warn "This will STOP the API server and restore etcd from: ${snapshot}"
  echo -ne "  Type 'yes' to continue: "
  local confirm; read -r confirm </dev/tty
  [[ "$confirm" != "yes" ]] && { info "Restore cancelled."; exit 0; }

  info "Copying snapshot to control plane..."
  if ! is_local_node "$CONTROL_PLANE_IP"; then
    scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
      "$snapshot" "${SSH_USER}@${CONTROL_PLANE_IP}:/tmp/restore-snapshot.db"
  else
    cp "$snapshot" /tmp/restore-snapshot.db
  fi

  local restore_script="/tmp/etcd_restore_$$.sh"
  cat > "$restore_script" <<'RESTOREEOF'
#!/usr/bin/env bash
set -euo pipefail
SNAP=/tmp/restore-snapshot.db

echo "[restore] Stopping kubelet and moving etcd data..."
systemctl stop kubelet 2>/dev/null || true

# Move static pod manifests to prevent kube-apiserver from starting
mv /etc/kubernetes/manifests /etc/kubernetes/manifests.bak 2>/dev/null || true
sleep 5

echo "[restore] Restoring etcd from snapshot..."
ETCDCTL_API=3 etcdctl snapshot restore "$SNAP" \
  --data-dir=/var/lib/etcd-restore \
  --name="$(hostname)" \
  --initial-cluster="$(hostname)=https://127.0.0.1:2380" \
  --initial-cluster-token=etcd-cluster-restored \
  --initial-advertise-peer-urls=https://127.0.0.1:2380

# Swap in the restored data
mv /var/lib/etcd /var/lib/etcd.bak."$(date +%s)"
mv /var/lib/etcd-restore /var/lib/etcd

echo "[restore] Restoring manifests and starting kubelet..."
mv /etc/kubernetes/manifests.bak /etc/kubernetes/manifests
systemctl start kubelet

echo "[restore] Waiting for API server..."
for i in $(seq 1 30); do
  kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes &>/dev/null && echo "[restore] API server up." && exit 0
  sleep 5
done
echo "[restore] WARNING: API server did not respond in 150s — check manually."
RESTOREEOF
  chmod 600 "$restore_script"
  run_script_on "$CONTROL_PLANE_IP" "$restore_script" || {
    error "Restore script failed — check the control plane manually."
    rm -f "$restore_script"
    exit 1
  }
  rm -f "$restore_script"
  log "etcd restore complete. Verify cluster state with: kubectl get nodes"
}

