#!/usr/bin/env bash
# =============================================================================
# 10_monitoring.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_monitoring() {
  section "Step — Prometheus & Grafana (kube-prometheus-stack)"
  # KUBECONFIG exported globally after init_control_plane

  if [[ "${INSTALL_MONITORING}" != "true" ]]; then
    warn "INSTALL_MONITORING=false — skipping monitoring stack."
    return
  fi

  # ── Resolve which StorageClass to use ─────────────────────────────────────
  local storage_class=""

  if [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_STORAGE_CLASS:-}" ]]; then
    # Verify the NFS StorageClass actually exists before using it
    if kubectl get storageclass "${NFS_STORAGE_CLASS}" &>/dev/null; then
      storage_class="$NFS_STORAGE_CLASS"
      info "Using NFS StorageClass '${storage_class}' for monitoring PVCs."
    else
      warn "NFS StorageClass '${NFS_STORAGE_CLASS}' not found — falling back to cluster default."
    fi
  fi

  if [[ -z "$storage_class" ]]; then
    # Find the cluster's default StorageClass (annotated with is-default-class=true)
    storage_class=$(kubectl get storageclass \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
      2>/dev/null | awk '$2 == "true" {print $1; exit}')
    if [[ -n "$storage_class" ]]; then
      info "Using cluster default StorageClass '${storage_class}' for monitoring PVCs."
    else
      warn "No default StorageClass found. Monitoring PVCs will pend until one is available."
      warn "Install NFS provisioner or another storage provider, then re-run: --step monitoring"
    fi
  fi

  # ── Pre-create the Prometheus PVC so the provisioner binds it before Helm ──
  # kube-prometheus-stack creates this PVC itself but only after the pod starts,
  # which causes the pod to stay Pending while waiting for the PVC to bind.
  # Creating it here first gives the provisioner a head start.
  kubectl create namespace "$NS_MONITORING" --dry-run=client -o yaml | kubectl apply -f -

  if [[ -n "$storage_class" && -n "${PROM_STORAGE_SIZE:-}" ]]; then
    info "Pre-creating Prometheus PVC (${PROM_STORAGE_SIZE}, StorageClass: ${storage_class})..."
    kubectl apply -f - <<PROMPVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
  namespace: ${NS_MONITORING}
  labels:
    app: kube-prometheus-stack-prometheus
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: ${PROM_STORAGE_SIZE}
PROMPVC

    # Wait up to 60s for the PVC to bind before proceeding
    info "Waiting for Prometheus PVC to bind..."
    if ! kubectl wait pvc \
        --namespace "$NS_MONITORING" \
        --selector='app=kube-prometheus-stack-prometheus' \
        --for=jsonpath='{.status.phase}'=Bound \
        --timeout=60s 2>/dev/null; then
      warn "Prometheus PVC did not bind within 60s — Helm will proceed anyway."
      kubectl get pvc -n "$NS_MONITORING"
    fi
  fi

  # ── Deploy kube-prometheus-stack ───────────────────────────────────────────
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update

  local sc_flags=()
  if [[ -n "$storage_class" ]]; then
    sc_flags+=(
      --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=${storage_class}"
      --set "grafana.persistence.storageClassName=${storage_class}"
    )
  fi

  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace "$NS_MONITORING" \
    --version "$PROM_STACK_VERSION" \
    --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort="${GRAFANA_NODEPORT}" \
    --set prometheus.service.type=NodePort \
    --set prometheus.service.nodePort="${PROMETHEUS_NODEPORT}" \
    --set alertmanager.service.type=NodePort \
    --set alertmanager.service.nodePort="${ALERTMANAGER_NODEPORT}" \
    --set prometheus.prometheusSpec.retention="${PROM_RETENTION}" \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="${PROM_STORAGE_SIZE}" \
    --set grafana.persistence.enabled=true \
    --set grafana.persistence.size=5Gi \
    "${sc_flags[@]}" \
    --wait --timeout=10m

  log "kube-prometheus-stack deployed in namespace ${NS_MONITORING}."
  info "Grafana:      http://${CONTROL_PLANE_IP}:${GRAFANA_NODEPORT}  (admin / ****)"
  info "Prometheus:   http://${CONTROL_PLANE_IP}:${PROMETHEUS_NODEPORT}"
  info "Alertmanager: http://${CONTROL_PLANE_IP}:${ALERTMANAGER_NODEPORT}"
}

