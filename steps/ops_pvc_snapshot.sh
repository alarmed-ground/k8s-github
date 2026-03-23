#!/usr/bin/env bash
# =============================================================================
# ops_pvc_snapshot.sh — PVC snapshot and restore via CSI VolumeSnapshot
# =============================================================================
# shellcheck shell=bash

snapshot_pvc() {
  section "PVC Snapshot"
  local pvc_name="${SNAPSHOT_PVC_NAME:-}"
  local pvc_ns="${SNAPSHOT_PVC_NS:-default}"
  local snap_class="${SNAPSHOT_CLASS:-}"

  if [[ -z "$pvc_name" ]]; then
    error "SNAPSHOT_PVC_NAME not set. Usage: --step pvc-snapshot (set in k8s_cluster.conf)"
    return 1
  fi

  # Auto-detect snapshot class if not set
  if [[ -z "$snap_class" ]]; then
    snap_class=$(kubectl get volumesnapshotclass \
      --no-headers -o custom-columns='NAME:.metadata.name' \
      2>/dev/null | head -1)
  fi

  if [[ -z "$snap_class" ]]; then
    error "No VolumeSnapshotClass found. Install the CSI snapshot controller:"
    error "  kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
    return 1
  fi

  local snap_name="${pvc_name}-snap-$(date +%Y%m%d-%H%M%S)"
  info "Creating snapshot '${snap_name}' of PVC '${pvc_ns}/${pvc_name}'..."
  info "Using VolumeSnapshotClass: ${snap_class}"

  kubectl apply -f - <<SNAP
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${snap_name}
  namespace: ${pvc_ns}
  labels:
    app.kubernetes.io/managed-by: k8s-install
    source-pvc: ${pvc_name}
spec:
  volumeSnapshotClassName: ${snap_class}
  source:
    persistentVolumeClaimName: ${pvc_name}
SNAP

  # Wait for snapshot to be ready
  info "Waiting for snapshot to be ready (up to 5 min)..."
  local waited=0
  while (( waited < 300 )); do
    local ready
    ready=$(kubectl get volumesnapshot "$snap_name" -n "$pvc_ns" \
      -o jsonpath='{.status.readyToUse}' 2>/dev/null)
    [[ "$ready" == "true" ]] && break
    sleep 10; waited=$(( waited + 10 ))
    info "  [${waited}s] waiting..."
  done

  if [[ "$(kubectl get volumesnapshot "$snap_name" -n "$pvc_ns" \
    -o jsonpath='{.status.readyToUse}' 2>/dev/null)" == "true" ]]; then
    log "Snapshot '${snap_name}' ready."
    kubectl get volumesnapshot "$snap_name" -n "$pvc_ns" 2>/dev/null
  else
    warn "Snapshot may still be in progress — check:"
    warn "  kubectl get volumesnapshot ${snap_name} -n ${pvc_ns}"
  fi
}

restore_pvc_from_snapshot() {
  section "PVC Restore from Snapshot"
  local snap_name="${RESTORE_SNAPSHOT_NAME:-}"
  local new_pvc_name="${RESTORE_PVC_NAME:-}"
  local pvc_ns="${SNAPSHOT_PVC_NS:-default}"
  local storage_size="${RESTORE_PVC_SIZE:-50Gi}"
  local storage_class="${RESTORE_STORAGE_CLASS:-}"

  if [[ -z "$snap_name" || -z "$new_pvc_name" ]]; then
    error "Set RESTORE_SNAPSHOT_NAME and RESTORE_PVC_NAME in k8s_cluster.conf"
    return 1
  fi

  info "Restoring PVC '${new_pvc_name}' from snapshot '${snap_name}'..."

  kubectl apply -f - <<RESTORE
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${new_pvc_name}
  namespace: ${pvc_ns}
spec:
  dataSource:
    name: ${snap_name}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${storage_size}
  ${storage_class:+storageClassName: ${storage_class}}
RESTORE

  log "PVC '${new_pvc_name}' created from snapshot '${snap_name}'."
  kubectl get pvc "$new_pvc_name" -n "$pvc_ns" 2>/dev/null
}
