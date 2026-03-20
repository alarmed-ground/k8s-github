#!/usr/bin/env bash
# =============================================================================
# ops_certs.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

renew_certs() {
  section "Certificate Renewal"

  info "Checking current certificate expiry on ${CONTROL_PLANE_IP}..."

  local check_script="/tmp/cert_check_$$.sh"
  cat > "$check_script" <<'CERTCHECK'
#!/usr/bin/env bash
set -euo pipefail
echo "[cert-renew] Current certificate expiry:"
kubeadm certs check-expiration 2>&1
CERTCHECK
  chmod 600 "$check_script"
  run_script_on "$CONTROL_PLANE_IP" "$check_script" || true
  rm -f "$check_script"

  echo -ne "\n  Proceed with renewal? [y/N]: "
  local confirm; read -r confirm </dev/tty
  [[ "${confirm,,}" != "y" ]] && { info "Renewal cancelled."; return; }

  local renew_script="/tmp/cert_renew_$$.sh"
  sed "s|__RESTART__|${CERT_RENEW_RESTART:-true}|g" <<'CERTRENEW' > "$renew_script"
#!/usr/bin/env bash
set -euo pipefail

echo "[cert-renew] Renewing all kubeadm-managed certificates..."
kubeadm certs renew all

echo "[cert-renew] Refreshing kubeconfig files..."
for cfg in /etc/kubernetes/admin.conf \
           /etc/kubernetes/controller-manager.conf \
           /etc/kubernetes/scheduler.conf; do
  [[ -f "$cfg" ]] && cp "$cfg" "${cfg}.bak.$(date +%s)"
done
kubeadm init phase kubeconfig all 2>/dev/null || true

cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

if [[ "__RESTART__" == "true" ]]; then
  echo "[cert-renew] Restarting static pods to pick up new certificates..."
  # Moving and restoring manifests forces kubelet to recreate the pods
  MANIFEST_DIR=/etc/kubernetes/manifests
  TMP_DIR=/tmp/k8s-manifests-renew
  mv "$MANIFEST_DIR" "$TMP_DIR"
  sleep 10
  mv "$TMP_DIR" "$MANIFEST_DIR"
  echo "[cert-renew] Waiting for API server..."
  for i in $(seq 1 30); do
    kubectl --kubeconfig=/root/.kube/config get nodes &>/dev/null \
      && echo "[cert-renew] API server up." && break
    sleep 5
  done
fi

echo "[cert-renew] New expiry dates:"
kubeadm certs check-expiration 2>&1
CERTRENEW
  chmod 600 "$renew_script"
  run_script_on "$CONTROL_PLANE_IP" "$renew_script" || {
    error "Certificate renewal failed."
    rm -f "$renew_script"
    exit 1
  }
  rm -f "$renew_script"

  # Refresh local kubeconfig if remote
  if ! is_local_node "$CONTROL_PLANE_IP"; then
    fetch_file_from "$CONTROL_PLANE_IP" \
      "/root/.kube/config" "/root/.kube/config"
    chmod 600 /root/.kube/config
    log "Local kubeconfig refreshed."
  fi

  log "Certificate renewal complete."
}

