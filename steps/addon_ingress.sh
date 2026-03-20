#!/usr/bin/env bash
# =============================================================================
# addon_ingress.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_ingress() {
  section "ingress-nginx"

  if [[ "${INSTALL_INGRESS:-false}" != "true" ]]; then
    info "INSTALL_INGRESS=false — skipping."
    return
  fi

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_INGRESS" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "$NS_INGRESS" \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http="${INGRESS_NODEPORT_HTTP}" \
    --set controller.service.nodePorts.https="${INGRESS_NODEPORT_HTTPS}" \
    --set controller.admissionWebhooks.enabled=false \
    --wait --timeout=5m

  log "ingress-nginx deployed in namespace ${NS_INGRESS}."
  info "HTTP:  http://${CONTROL_PLANE_IP}:${INGRESS_NODEPORT_HTTP}"
  info "HTTPS: https://${CONTROL_PLANE_IP}:${INGRESS_NODEPORT_HTTPS}"
  info "Create Ingress resources with: ingressClassName: nginx"
}

