#!/usr/bin/env bash
# =============================================================================
# addon_loki.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_loki() {
  section "Loki + Promtail Log Aggregation"

  if [[ "${INSTALL_LOKI:-false}" != "true" ]]; then
    info "INSTALL_LOKI=false — skipping."
    return
  fi

  helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
  helm repo update

  kubectl create namespace "$NS_LOKI" --dry-run=client -o yaml | kubectl apply -f -

  # Resolve StorageClass
  local sc=""
  [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_STORAGE_CLASS:-}" ]] && sc="$NFS_STORAGE_CLASS"
  [[ -z "$sc" ]] && sc=$(kubectl get storageclass \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    2>/dev/null | awk '$2=="true"{print $1;exit}')

  # Deploy Loki in single-binary mode (simpler for small clusters)
  helm upgrade --install loki grafana/loki \
    --namespace "$NS_LOKI" \
    --set loki.auth_enabled=false \
    --set loki.commonConfig.replication_factor=1 \
    --set loki.storage.type=filesystem \
    --set singleBinary.replicas=1 \
    ${sc:+--set loki.storage.filesystem.chunk_directory=/var/loki/chunks} \
    --set singleBinary.persistence.storageClass="${sc}" \
    --set singleBinary.persistence.size="${LOKI_STORAGE_SIZE}" \
    --set gateway.enabled=false \
    --wait --timeout=5m || \
  warn "Loki install returned non-zero — pods may still be starting."

  # Deploy Promtail to ship pod logs to Loki
  helm upgrade --install promtail grafana/promtail \
    --namespace "$NS_LOKI" \
    --set config.lokiAddress="http://loki.${NS_LOKI}.svc.cluster.local:3100/loki/api/v1/push" \
    --wait --timeout=3m || \
    warn "Promtail install returned non-zero."

  # Add Loki as a Grafana datasource if monitoring is installed
  if [[ "${INSTALL_MONITORING:-false}" == "true" ]]; then
    info "Adding Loki datasource to Grafana..."
    kubectl apply -f - <<LOKIDS
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: ${NS_MONITORING}
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        url: http://loki.${NS_LOKI}.svc.cluster.local:3100
        access: proxy
        isDefault: false
LOKIDS
    log "Loki datasource ConfigMap created — Grafana will load it on next restart."
  fi

  log "Loki + Promtail deployed in namespace ${NS_LOKI}."
  info "Loki is accessible within the cluster at: http://loki.${NS_LOKI}.svc.cluster.local:3100"
  info "Query logs in Grafana Explore using LogQL."
}

