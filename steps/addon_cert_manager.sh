#!/usr/bin/env bash
# =============================================================================
# addon_cert_manager.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_cert_manager() {
  section "cert-manager"

  if [[ "${INSTALL_CERT_MANAGER:-false}" != "true" ]]; then
    info "INSTALL_CERT_MANAGER=false — skipping."
    return
  fi

  helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_CERT_MANAGER" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "$NS_CERT_MANAGER" \
    --set installCRDs=true \
    --wait --timeout=5m

  # Create the ClusterIssuer based on configured type
  local issuer="${CERT_MANAGER_ISSUER:-selfsigned}"
  case "$issuer" in
    selfsigned)
      kubectl apply -f - <<SELFSIGNED
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
SELFSIGNED
      log "cert-manager deployed with self-signed ClusterIssuer."
      ;;
    letsencrypt-staging|letsencrypt)
      [[ -z "${CERT_MANAGER_EMAIL:-}" ]] && {
        error "CERT_MANAGER_EMAIL required for Let's Encrypt."
        exit 1
      }
      local server="https://acme-v02.api.letsencrypt.org/directory"
      [[ "$issuer" == "letsencrypt-staging" ]] && \
        server="https://acme-staging-v02.api.letsencrypt.org/directory"
      kubectl apply -f - <<ACME
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: ${server}
    email: ${CERT_MANAGER_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            class: nginx
ACME
      log "cert-manager deployed with Let's Encrypt ClusterIssuer (${issuer})."
      ;;
  esac

  info "Annotate Ingress with: cert-manager.io/cluster-issuer: <issuer-name>"
}

