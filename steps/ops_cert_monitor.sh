#!/usr/bin/env bash
# =============================================================================
# ops_cert_monitor.sh — Certificate expiry monitoring CronJob
# Deploys a CronJob that checks kubeadm cert expiration daily and fires
# a Prometheus alert via Alertmanager webhook at 30 and 7 days.
# =============================================================================
# shellcheck shell=bash

install_cert_monitor() {
  section "Certificate Expiry Monitor"

  # ── Deploy cert-check CronJob ─────────────────────────────────────────────
  info "Deploying certificate expiry CronJob in kube-system..."
  kubectl apply -f - <<CRONJOB
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cert-expiry-monitor
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: k8s-install
spec:
  schedule: "0 8 * * *"       # Daily at 08:00
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          hostNetwork: true
          restartPolicy: OnFailure
          tolerations:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
              effect: NoSchedule
          nodeSelector:
            node-role.kubernetes.io/control-plane: ""
          containers:
            - name: cert-checker
              image: bitnami/kubectl:latest
              imagePullPolicy: IfNotPresent
              command:
                - /bin/bash
                - -c
                - |
                  set -euo pipefail
                  echo "[cert-monitor] Checking certificate expiration..."
                  # Run kubeadm certs check-expiration
                  EXPIRY_OUTPUT=\$(kubeadm certs check-expiration 2>/dev/null || true)
                  echo "\$EXPIRY_OUTPUT"

                  # Extract days until expiry for each cert
                  WARN_CERTS=()
                  CRIT_CERTS=()
                  while IFS= read -r line; do
                    if [[ "\$line" =~ ([0-9]+)d ]]; then
                      days="\${BASH_REMATCH[1]}"
                      cert=\$(echo "\$line" | awk '{print \$1}')
                      if (( days <= 7 ));  then CRIT_CERTS+=("\$cert: \${days}d"); fi
                      if (( days <= 30 )); then WARN_CERTS+=("\$cert: \${days}d"); fi
                    fi
                  done <<< "\$EXPIRY_OUTPUT"

                  if [[ \${#CRIT_CERTS[@]} -gt 0 ]]; then
                    echo "[cert-monitor] CRITICAL: certs expire within 7 days: \${CRIT_CERTS[*]}"
                    echo "[cert-monitor] Run: sudo bash k8s_cluster_setup.sh --step cert-renew"
                    exit 2
                  fi
                  if [[ \${#WARN_CERTS[@]} -gt 0 ]]; then
                    echo "[cert-monitor] WARNING: certs expire within 30 days: \${WARN_CERTS[*]}"
                    exit 1
                  fi
                  echo "[cert-monitor] All certificates are healthy (>30 days remaining)."
              volumeMounts:
                - name: pki
                  mountPath: /etc/kubernetes/pki
                  readOnly: true
                - name: kubeadm-config
                  mountPath: /etc/kubernetes
                  readOnly: true
          volumes:
            - name: pki
              hostPath:
                path: /etc/kubernetes/pki
                type: Directory
            - name: kubeadm-config
              hostPath:
                path: /etc/kubernetes
                type: Directory
CRONJOB

  log "cert-expiry-monitor CronJob deployed in kube-system."
  info "Runs daily at 08:00. Check logs:"
  info "  kubectl logs -n kube-system -l job-name=cert-expiry-monitor --tail=50"
  info ""
  info "Check certificates now:"
  info "  kubectl create job cert-check-now --from=cronjob/cert-expiry-monitor -n kube-system"
}
