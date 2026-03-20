#!/usr/bin/env bash
# =============================================================================
# addon_argocd.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_argocd() {
  section "ArgoCD GitOps"

  if [[ "${INSTALL_ARGOCD:-false}" != "true" ]]; then
    info "INSTALL_ARGOCD=false — skipping."
    return
  fi

  kubectl create namespace "$NS_ARGOCD" --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -n "$NS_ARGOCD" \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  # Wait for argocd-server
  info "Waiting for ArgoCD server to be ready (up to 5 min)..."
  kubectl wait deployment/argocd-server \
    -n "$NS_ARGOCD" --for=condition=Available --timeout=300s || \
    warn "ArgoCD server not ready after 5 min — check: kubectl get pods -n ${NS_ARGOCD}"

  # Patch argocd-server service to NodePort
  kubectl patch svc argocd-server -n "$NS_ARGOCD" \
    --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
         {\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${ARGOCD_NODEPORT}}]" \
    2>/dev/null || \
  kubectl patch svc argocd-server -n "$NS_ARGOCD" \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"nodePort\":${ARGOCD_NODEPORT}}]}}" || \
    warn "Could not patch ArgoCD service to NodePort — patch manually."

  # Retrieve initial admin password
  local initial_pw=""
  local attempts=0
  while [[ -z "$initial_pw" && $attempts -lt 12 ]]; do
    initial_pw=$(kubectl -n "$NS_ARGOCD" get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    sleep 5; attempts=$(( attempts + 1 ))
  done

  log "ArgoCD deployed in namespace ${NS_ARGOCD}."
  info "URL:  https://${CONTROL_PLANE_IP}:${ARGOCD_NODEPORT}"
  if [[ -n "$initial_pw" ]]; then
    info "Login: admin / ${initial_pw}"
    echo "$initial_pw" > /root/argocd-initial-password.txt
    chmod 600 /root/argocd-initial-password.txt
    info "Initial password saved to /root/argocd-initial-password.txt"
  fi
  info "Install CLI: curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && chmod +x argocd"
}

