#!/usr/bin/env bash
# =============================================================================
# addon_ceph.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_ceph() {
  section "Rook-Ceph Distributed Storage"

  if [[ "${INSTALL_CEPH:-false}" != "true" ]]; then
    info "INSTALL_CEPH=false — skipping."
    return
  fi

  local worker_count=${#WORKER_IPS[@]}
  local replica="${CEPH_REPLICA_COUNT:-3}"

  # Ceph needs >=3 OSDs for a replicated pool. With fewer nodes reduce replica
  # count to match available node count so the cluster can reach HEALTH_OK.
  if (( worker_count == 0 )); then
    warn "Rook-Ceph strongly recommends at least 3 worker nodes."
    warn "Single-node install — forcing replica=1 (no redundancy)."
    replica=1
  elif (( worker_count < replica )); then
    warn "Only ${worker_count} worker(s) — reducing replica from ${replica} to ${worker_count}."
    replica=$worker_count
  fi

  # ── Pre-requisites on every node ─────────────────────────────────────────
  info "Installing lvm2 + ceph-common on all nodes (Rook requirement)..."
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  for node in "${all_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    run_on "$node" \
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lvm2 ceph-common 2>&1" || \
      warn "Pre-req install returned non-zero on ${node} — continuing."
  done

  # ── Rook operator CRDs + operator ────────────────────────────────────────
  local ROOK_VERSION="v1.14.0"   # pinned — update deliberately
  info "Deploying Rook-Ceph operator ${ROOK_VERSION}..."
  kubectl apply -f \
    "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/crds.yaml"
  kubectl apply -f \
    "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/common.yaml"
  kubectl apply -f \
    "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/operator.yaml"

  local rook_wait="${ROOK_WAIT_TIMEOUT:-180s}"
  info "Waiting for Rook operator to become Available (timeout: ${rook_wait})..."
  kubectl wait deployment/rook-ceph-operator \
    -n rook-ceph --for=condition=Available "--timeout=${rook_wait}" || \
    warn "Operator not ready after ${rook_wait} — continuing."

  # ── CephCluster CR ───────────────────────────────────────────────────────
  local use_all_nodes="${CEPH_USE_ALL_NODES:-true}"
  local use_all_devices="${CEPH_USE_ALL_DEVICES:-true}"
  local device_filter="${CEPH_DEVICE_FILTER:-}"
  local allow_multi="false"
  [[ "$use_all_nodes" == "true" && ${#WORKER_IPS[@]} -eq 0 ]] && allow_multi="true"

  info "Creating CephCluster CR (replica=${replica})..."

  # Build optional deviceFilter line
  local df_line=""
  [[ -n "$device_filter" ]] && df_line="    deviceFilter: \"${device_filter}\""

  kubectl apply -f - <<CEPHCLUSTER
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: ${NS_CEPH}
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v18
    allowUnsupported: false
  dataDirHostPath: /var/lib/rook
  mon:
    count: 3
    allowMultiplePerNode: ${allow_multi}
  mgr:
    count: 1
    allowMultiplePerNode: false
    modules:
      - name: pg_autoscaler
        enabled: true
      - name: dashboard
        enabled: true
  dashboard:
    enabled: true
    ssl: false
  monitoring:
    enabled: false
  storage:
    useAllNodes: ${use_all_nodes}
    useAllDevices: ${use_all_devices}
${df_line}
    config:
      osdsPerDevice: "1"
  resources:
    osd:
      requests:
        cpu: "500m"
        memory: "2Gi"
      limits:
        cpu: "2"
        memory: "4Gi"
    mon:
      requests:
        cpu: "100m"
        memory: "512Mi"
      limits:
        cpu: "1"
        memory: "1Gi"
    mgr:
      requests:
        cpu: "100m"
        memory: "512Mi"
      limits:
        cpu: "1"
        memory: "1Gi"
CEPHCLUSTER

  # ── Wait for cluster HEALTH_OK / HEALTH_WARN ─────────────────────────────
  # CEPH_WAIT_TIMEOUT: override to 0 in test environments to skip the poll loop.
  local ceph_wait_max="${CEPH_WAIT_TIMEOUT:-1200}"
  info "Waiting for CephCluster HEALTH_OK (up to $((ceph_wait_max/60)) min)..."
  local elapsed=0 healthy=false
  while (( elapsed < ceph_wait_max )); do
    local phase health
    phase=$(kubectl get cephcluster rook-ceph -n "${NS_CEPH}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    health=$(kubectl get cephcluster rook-ceph -n "${NS_CEPH}" \
      -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo "")
    info "  [${elapsed}s] phase=${phase:-Unknown}  health=${health:-Unknown}"
    if [[ "$health" == "HEALTH_OK" || "$health" == "HEALTH_WARN" ]]; then
      healthy=true; break
    fi
    sleep 30; elapsed=$(( elapsed + 30 ))
  done
  $healthy || warn "CephCluster did not reach HEALTH_OK in 20 min — check: kubectl get cephcluster -n ${NS_CEPH}"

  # ── CephBlockPool + RBD StorageClass (RWO) ───────────────────────────────
  info "Creating CephBlockPool and rook-ceph-block StorageClass (replica=${replica})..."
  kubectl apply -f - <<CEPHPOOL
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: ${NS_CEPH}
spec:
  failureDomain: host
  replicated:
    size: ${replica}
    requireSafeReplicaSize: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
  annotations:
    storageclass.kubernetes.io/is-default-class: "${CEPH_DEFAULT_SC:-false}"
provisioner: ${NS_CEPH}.rbd.csi.ceph.com
parameters:
  clusterID: ${NS_CEPH}
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${NS_CEPH}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${NS_CEPH}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${NS_CEPH}
reclaimPolicy: Retain
allowVolumeExpansion: true
CEPHPOOL

  # ── CephFilesystem + CephFS StorageClass (RWX) ───────────────────────────
  info "Creating CephFilesystem + rook-cephfs StorageClass (RWX)..."
  kubectl apply -f - <<CEPHFS
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: cephfs
  namespace: ${NS_CEPH}
spec:
  metadataPool:
    replicated:
      size: ${replica}
  dataPools:
    - name: data0
      failureDomain: host
      replicated:
        size: ${replica}
  preserveFilesystemOnDelete: false
  metadataServer:
    activeCount: 1
    activeStandby: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-cephfs
provisioner: ${NS_CEPH}.cephfs.csi.ceph.com
parameters:
  clusterID: ${NS_CEPH}
  fsName: cephfs
  pool: cephfs-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${NS_CEPH}
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: ${NS_CEPH}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${NS_CEPH}
reclaimPolicy: Retain
allowVolumeExpansion: true
CEPHFS

  # ── Expose Ceph Dashboard ────────────────────────────────────────────────
  info "Patching Ceph Dashboard service to NodePort ${CEPH_DASHBOARD_NODEPORT}..."
  local dash_wait=0
  until kubectl get svc rook-ceph-mgr-dashboard -n "${NS_CEPH}" &>/dev/null 2>&1; do
    sleep 5; dash_wait=$(( dash_wait + 5 ))
    (( dash_wait > 120 )) && { warn "Dashboard service not found after 2 min."; break; }
  done
  kubectl patch svc rook-ceph-mgr-dashboard -n "${NS_CEPH}" \
    --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
         {\"op\":\"add\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${CEPH_DASHBOARD_NODEPORT}}]" \
    2>/dev/null || \
  kubectl patch svc rook-ceph-mgr-dashboard -n "${NS_CEPH}" \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":7000,\"nodePort\":${CEPH_DASHBOARD_NODEPORT}}]}}" \
    2>/dev/null || \
    warn "Could not patch Ceph Dashboard — patch manually after cluster is Ready."

  # Retrieve dashboard password
  local dash_pw=""
  dash_pw=$(kubectl -n "${NS_CEPH}" get secret rook-ceph-dashboard-password \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

  log "Rook-Ceph deployed in namespace ${NS_CEPH}."
  info "StorageClasses:"
  info "  rook-ceph-block   RWO — block   (default=${CEPH_DEFAULT_SC:-false})"
  info "  rook-cephfs       RWX — shared filesystem"
  info "Ceph Dashboard:     http://${CONTROL_PLANE_IP}:${CEPH_DASHBOARD_NODEPORT}"
  info "Dashboard user:     admin"
  if [[ -n "$dash_pw" ]]; then
    info "Dashboard pass:     ${dash_pw}"
    echo "$dash_pw" > /root/ceph-dashboard-password.txt
    chmod 600 /root/ceph-dashboard-password.txt
    info "Password saved:     /root/ceph-dashboard-password.txt"
  else
    info "Get password:       kubectl -n ${NS_CEPH} get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}' | base64 -d"
  fi
  info "Check health:       kubectl get cephcluster -n ${NS_CEPH}"
  info "Check OSDs:         kubectl get cephblockpool -n ${NS_CEPH}"
}

