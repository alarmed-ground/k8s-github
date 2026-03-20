#!/usr/bin/env bash
# =============================================================================
# addon_metallb.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_metallb() {
  section "MetalLB Bare-Metal LoadBalancer"

  if [[ "${INSTALL_METALLB:-false}" != "true" ]]; then
    info "INSTALL_METALLB=false — skipping."
    return
  fi

  if [[ -z "${METALLB_IP_RANGE:-}" ]]; then
    error "METALLB_IP_RANGE is required (e.g. 192.168.1.200-192.168.1.210)."
    exit 1
  fi

  helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_METALLB" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install metallb metallb/metallb \
    --namespace "$NS_METALLB" \
    --wait --timeout=5m

  # Wait for MetalLB webhook to be ready
  info "Waiting for MetalLB controller..."
  kubectl wait deployment/metallb-controller \
    -n "$NS_METALLB" --for=condition=Available --timeout=120s || true

  # Configure IP address pool
  kubectl apply -f - <<MLBPOOL
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: ${NS_METALLB}
spec:
  addresses:
    - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: ${NS_METALLB}
spec:
  ipAddressPools:
    - default-pool
MLBPOOL

  log "MetalLB deployed. IP range: ${METALLB_IP_RANGE}"
  info "Services with type=LoadBalancer will now receive IPs from the pool."
}

