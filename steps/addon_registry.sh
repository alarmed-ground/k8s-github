#!/usr/bin/env bash
# =============================================================================
# addon_registry.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_registry() {
  section "Private Container Registry"

  if [[ "${INSTALL_REGISTRY:-false}" != "true" ]]; then
    info "INSTALL_REGISTRY=false — skipping."
    return
  fi

  helm repo add twuni https://helm.twun.io 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_REGISTRY" --dry-run=client -o yaml | kubectl apply -f -

  # Resolve StorageClass
  local sc=""
  [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_STORAGE_CLASS:-}" ]] && sc="$NFS_STORAGE_CLASS"
  [[ -z "$sc" ]] && sc=$(kubectl get storageclass \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    2>/dev/null | awk '$2=="true"{print $1;exit}')

  local auth_flags=()
  if [[ "${REGISTRY_AUTH:-false}" == "true" ]]; then
    # Create htpasswd secret
    local htpasswd
    htpasswd=$(python3 -c "
import bcrypt, base64
pw = '${REGISTRY_PASSWORD}'.encode()
hashed = bcrypt.hashpw(pw, bcrypt.gensalt(rounds=10)).decode()
print('${REGISTRY_USER}:' + hashed)
" 2>/dev/null || \
    docker run --rm --entrypoint htpasswd \
      httpd:2 -Bbn "${REGISTRY_USER}" "${REGISTRY_PASSWORD}" 2>/dev/null || \
    openssl passwd -apr1 "${REGISTRY_PASSWORD}" | \
      awk -v u="${REGISTRY_USER}" '{print u":"$0}')

    kubectl create secret generic registry-htpasswd \
      --from-literal=htpasswd="$htpasswd" \
      -n "$NS_REGISTRY" \
      --dry-run=client -o yaml | kubectl apply -f -
    auth_flags+=(
      --set secrets.htpasswd="$htpasswd"
    )
  fi

  helm upgrade --install docker-registry twuni/docker-registry \
    --namespace "$NS_REGISTRY" \
    --set service.type=NodePort \
    --set service.nodePort="${REGISTRY_NODEPORT}" \
    --set persistence.enabled=true \
    --set persistence.size="${REGISTRY_STORAGE_SIZE}" \
    ${sc:+--set persistence.storageClass="$sc"} \
    "${auth_flags[@]}" \
    --wait --timeout=5m

  log "Private registry deployed in namespace ${NS_REGISTRY}."
  info "Push:  docker push ${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}/image:tag"
  info "Pull:  docker pull ${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}/image:tag"
  if [[ "${REGISTRY_AUTH:-false}" == "true" ]]; then
    info "Login: docker login ${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT} -u ${REGISTRY_USER}"
  fi
  warn "Registry uses HTTP (no TLS). Add to /etc/docker/daemon.json on each node:"
  warn '  {"insecure-registries": ["'"${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}"'"]}'
}

