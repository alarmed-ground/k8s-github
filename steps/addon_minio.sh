#!/usr/bin/env bash
# =============================================================================
# addon_minio.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_minio() {
  section "MinIO Object Storage"

  if [[ "${INSTALL_MINIO:-false}" != "true" ]]; then
    info "INSTALL_MINIO=false — skipping."
    return
  fi

  helm repo add minio https://charts.min.io/ 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_MINIO" --dry-run=client -o yaml | kubectl apply -f -

  # Resolve StorageClass
  local sc=""
  [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_STORAGE_CLASS:-}" ]] && sc="$NFS_STORAGE_CLASS"
  [[ -z "$sc" ]] && sc=$(kubectl get storageclass \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    2>/dev/null | awk '$2=="true"{print $1;exit}')

  local sc_flag=""
  [[ -n "$sc" ]] && sc_flag="--set persistence.storageClass=${sc}"

  helm upgrade --install minio minio/minio \
    --namespace "$NS_MINIO" \
    --set rootUser="${MINIO_ROOT_USER}" \
    --set rootPassword="${MINIO_ROOT_PASSWORD}" \
    --set persistence.size="${MINIO_STORAGE_SIZE}" \
    --set service.type=NodePort \
    --set service.nodePort="${MINIO_NODEPORT_API}" \
    --set consoleService.type=NodePort \
    --set consoleService.nodePort="${MINIO_NODEPORT_CONSOLE}" \
    --set replicas=1 \
    --set mode=standalone \
    ${sc_flag} \
    --wait --timeout=5m

  log "MinIO deployed in namespace ${NS_MINIO}."
  info "API:     http://${CONTROL_PLANE_IP}:${MINIO_NODEPORT_API}"
  info "Console: http://${CONTROL_PLANE_IP}:${MINIO_NODEPORT_CONSOLE}"
  info "User: ${MINIO_ROOT_USER} / Password: (set in config)"
}

