#!/usr/bin/env bash
# =============================================================================
# addon_alerting_rules.sh — Default Prometheus alerting rules
# Ships sensible alerts for: node, pods, PVC, etcd, certs, GPU
# =============================================================================
# shellcheck shell=bash

install_alerting_rules() {
  section "Prometheus Alerting Rules"
  if [[ "${INSTALL_ALERTING_RULES:-true}" != "true" ]]; then
    info "INSTALL_ALERTING_RULES=false — skipping."
    return
  fi

  if [[ "${INSTALL_MONITORING:-false}" != "true" ]]; then
    warn "INSTALL_MONITORING=false — skipping alerting rules."
    return
  fi

  kubectl apply -f - <<RULES
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: k8s-install-alerts
  namespace: ${NS_MONITORING:-monitoring}
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    # ── Node health ─────────────────────────────────────────────────────────
    - name: nodes
      rules:
        - alert: NodeNotReady
          expr: kube_node_status_condition{condition="Ready",status="true"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Node {{ \$labels.node }} is NotReady"
            description: "Node {{ \$labels.node }} has been NotReady for >2 min."

        - alert: NodeDiskSpaceLow
          expr: |
            (node_filesystem_avail_bytes{mountpoint="/"} /
             node_filesystem_size_bytes{mountpoint="/"}) < 0.10
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Disk space below 10% on {{ \$labels.instance }}"

        - alert: NodeMemoryPressure
          expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Memory pressure on node {{ \$labels.node }}"

    # ── Pod health ──────────────────────────────────────────────────────────
    - name: pods
      rules:
        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ \$labels.namespace }}/{{ \$labels.pod }} is crash-looping"
            description: "Container {{ \$labels.container }} restarted >5 times in 15 min."

        - alert: PodNotReady
          expr: |
            kube_pod_status_ready{condition="true"} == 0
            AND kube_pod_status_phase{phase=~"Running|Pending"} == 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ \$labels.namespace }}/{{ \$labels.pod }} not ready for 10 min"

    # ── PVC ─────────────────────────────────────────────────────────────────
    - name: storage
      rules:
        - alert: PVCNearCapacity
          expr: |
            (kubelet_volume_stats_used_bytes /
             kubelet_volume_stats_capacity_bytes) > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "PVC {{ \$labels.namespace }}/{{ \$labels.persistentvolumeclaim }} at >85% capacity"

        - alert: PVCFull
          expr: |
            (kubelet_volume_stats_used_bytes /
             kubelet_volume_stats_capacity_bytes) > 0.97
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "PVC {{ \$labels.namespace }}/{{ \$labels.persistentvolumeclaim }} is >97% full"

    # ── etcd ────────────────────────────────────────────────────────────────
    - name: etcd
      rules:
        - alert: EtcdDBSizeHigh
          expr: |
            etcd_mvcc_db_total_size_in_bytes /
            etcd_server_quota_backend_bytes > 0.80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "etcd DB size is >80% of quota on {{ \$labels.instance }}"
            description: "Run: etcdctl defrag --cluster"

        - alert: EtcdNoLeader
          expr: etcd_server_has_leader == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "etcd has no leader on {{ \$labels.instance }}"

    # ── Certificates ────────────────────────────────────────────────────────
    - name: certificates
      rules:
        - alert: KubeClientCertificateExpiry30d
          expr: |
            apiserver_client_certificate_expiration_seconds_count > 0
            AND histogram_quantile(0.01,
              rate(apiserver_client_certificate_expiration_seconds_bucket[5m])) < 2592000
          labels:
            severity: warning
          annotations:
            summary: "Kubernetes client certificate expires within 30 days"

        - alert: KubeClientCertificateExpiry7d
          expr: |
            apiserver_client_certificate_expiration_seconds_count > 0
            AND histogram_quantile(0.01,
              rate(apiserver_client_certificate_expiration_seconds_bucket[5m])) < 604800
          labels:
            severity: critical
          annotations:
            summary: "Kubernetes client certificate expires within 7 days"
RULES

  log "Alerting rules deployed in namespace ${NS_MONITORING:-monitoring}."
  info "View alerts: http://${CONTROL_PLANE_IP}:${ALERTMANAGER_NODEPORT:-32002}"
}
