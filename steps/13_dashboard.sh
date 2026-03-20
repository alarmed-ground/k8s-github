#!/usr/bin/env bash
# =============================================================================
# 13_dashboard.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_dashboard() {
  section "Step — Kubernetes Dashboard v${DASHBOARD_VERSION}"
  # KUBECONFIG exported globally after init_control_plane

  if [[ "${INSTALL_DASHBOARD}" != "true" ]]; then
    warn "INSTALL_DASHBOARD=false — skipping Kubernetes Dashboard."
    return
  fi

  info "Deploying Kubernetes Dashboard v${DASHBOARD_VERSION}..."

  # Apply the official manifest for the pinned version
  kubectl apply -f \
    "https://raw.githubusercontent.com/kubernetes/dashboard/v${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"

  kubectl create namespace "$NS_DASHBOARD" --dry-run=client -o yaml | kubectl apply -f -

  # ── Service Account + ClusterRoleBinding for token login ─────────────────────
  kubectl apply -f - <<DASHSA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard-admin
  namespace: ${NS_DASHBOARD}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: dashboard-admin
  namespace: ${NS_DASHBOARD}
DASHSA

  # ── Patch the kubernetes-dashboard Service to NodePort ────────────────────────
  kubectl patch svc kubernetes-dashboard \
    -n "$NS_DASHBOARD" \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"targetPort\":8443,\"nodePort\":${DASHBOARD_NODEPORT}}]}}"

  # ── Create a long-lived token Secret (k8s 1.24+) ─────────────────────────────
  kubectl apply -f - <<DASHTOK
apiVersion: v1
kind: Secret
metadata:
  name: dashboard-admin-token
  namespace: ${NS_DASHBOARD}
  annotations:
    kubernetes.io/service-account.name: dashboard-admin
type: kubernetes.io/service-account-token
DASHTOK

  # Wait for token to be populated (up to 30s)
  local token="" elapsed=0
  while [[ -z "$token" && $elapsed -lt 30 ]]; do
    token=$(kubectl get secret dashboard-admin-token \
      -n "$NS_DASHBOARD" \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
    sleep 2; elapsed=$(( elapsed + 2 ))
  done

  log "Kubernetes Dashboard deployed in namespace ${NS_DASHBOARD}."
  info "URL:   https://${CONTROL_PLANE_IP}:${DASHBOARD_NODEPORT}"
  if [[ -n "$token" ]]; then
    info "Token: ${token}"
    # Also save to a file so it's not lost from terminal scroll
    echo "$token" > /root/dashboard-token.txt
    chmod 600 /root/dashboard-token.txt
    info "Token also saved to /root/dashboard-token.txt"
  else
    info "Retrieve token later with:"
    info "  kubectl get secret dashboard-admin-token -n ${NS_DASHBOARD} -o jsonpath='{.data.token}' | base64 -d"
  fi
}

