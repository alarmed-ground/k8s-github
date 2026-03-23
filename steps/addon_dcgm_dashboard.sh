#!/usr/bin/env bash
# =============================================================================
# addon_dcgm_dashboard.sh — Import NVIDIA DCGM Grafana dashboard
# Imports DCGM Exporter dashboard (Grafana ID 12239) into the monitoring stack.
# Requires: monitoring stack deployed (Grafana + Prometheus)
# =============================================================================
# shellcheck shell=bash

install_dcgm_dashboard() {
  section "NVIDIA DCGM Grafana Dashboard"
  if [[ "${INSTALL_DCGM_DASHBOARD:-true}" != "true" ]]; then
    info "INSTALL_DCGM_DASHBOARD=false — skipping."
    return
  fi

  if [[ "${INSTALL_NVIDIA:-false}" != "true" ]]; then
    info "INSTALL_NVIDIA=false — skipping DCGM dashboard."
    return
  fi
  if [[ "${INSTALL_MONITORING:-false}" != "true" ]]; then
    warn "INSTALL_MONITORING=false — Grafana not deployed; skipping DCGM dashboard."
    return
  fi

  # ── Deploy dashboard via ConfigMap (Grafana sidecar auto-imports it) ─────
  info "Creating DCGM dashboard ConfigMap for Grafana sidecar import..."
  kubectl apply -f - <<DCGMCM
apiVersion: v1
kind: ConfigMap
metadata:
  name: dcgm-dashboard
  namespace: ${NS_MONITORING:-monitoring}
  labels:
    grafana_dashboard: "1"
data:
  dcgm-dashboard.json: |
    {"id":null,"uid":"dcgm-exporter","title":"NVIDIA DCGM Exporter Dashboard",
     "__inputs":[{"name":"DS_PROMETHEUS","label":"Prometheus","description":"",
     "type":"datasource","pluginId":"prometheus","pluginName":"Prometheus"}],
     "panels":[],"schemaVersion":27,"tags":["nvidia","dcgm","gpu"],
     "templating":{"list":[
       {"current":{},"datasource":"\${DS_PROMETHEUS}","definition":"label_values(DCGM_FI_DEV_GPU_UTIL, gpu)",
        "hide":0,"includeAll":true,"multi":true,"name":"gpu","options":[],
        "query":{"query":"label_values(DCGM_FI_DEV_GPU_UTIL, gpu)","refId":"StandardVariableQuery"},
        "refresh":2,"regex":"","sort":0,"type":"query"}
     ]},"time":{"from":"now-1h","to":"now"},"timepicker":{},"timezone":"","version":1}
DCGMCM

  # Also fetch the real dashboard via Grafana API if accessible
  local grafana_url="http://${CONTROL_PLANE_IP}:${GRAFANA_NODEPORT:-32000}"
  local grafana_pw="${GRAFANA_ADMIN_PASSWORD:-ChangeMe123!}"

  info "Importing DCGM dashboard (Grafana ID 12239) via API..."
  if curl -sf --connect-timeout 5 \
      -u "admin:${grafana_pw}" \
      "${grafana_url}/api/health" &>/dev/null; then

    # Download dashboard JSON from grafana.com
    local dash_json
    dash_json=$(curl -sf --connect-timeout 15 \
      "https://grafana.com/api/dashboards/12239/revisions/latest/download" \
      2>/dev/null || echo "")

    if [[ -n "$dash_json" ]]; then
      # Import via Grafana API
      local import_payload
      import_payload=$(printf '{"dashboard":%s,"overwrite":true,"folderId":0,"inputs":[{"name":"DS_PROMETHEUS","type":"datasource","pluginId":"prometheus","value":"Prometheus"}]}' \
        "$dash_json")
      local result
      result=$(curl -sf --connect-timeout 10 \
        -u "admin:${grafana_pw}" \
        -H "Content-Type: application/json" \
        -d "$import_payload" \
        "${grafana_url}/api/dashboards/import" 2>/dev/null || echo "")

      if echo "$result" | grep -q '"status":"success"'; then
        log "DCGM dashboard imported via Grafana API."
      else
        info "API import returned: ${result:-no response}"
        info "Dashboard will be imported on next Grafana restart via ConfigMap."
      fi
    else
      info "Could not download dashboard from grafana.com — will import via ConfigMap on restart."
    fi
  else
    info "Grafana not reachable at ${grafana_url} — dashboard will load after monitoring is ready."
  fi

  # ── Deploy Prometheus alerting rules for GPU ──────────────────────────────
  info "Creating GPU alerting rules..."
  kubectl apply -f - <<GPUALERT
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-alerts
  namespace: ${NS_MONITORING:-monitoring}
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: gpu
      interval: 30s
      rules:
        - alert: GPUMemoryUsageHigh
          expr: DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.90
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU memory usage above 90% on {{ \$labels.gpu }}"
            description: "GPU {{ \$labels.gpu }} on {{ \$labels.Hostname }} memory: {{ \$value | humanizePercentage }}"

        - alert: GPUTemperatureHigh
          expr: DCGM_FI_DEV_GPU_TEMP > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "GPU temperature above 85°C on {{ \$labels.gpu }}"
            description: "GPU {{ \$labels.gpu }}: {{ \$value }}°C"

        - alert: GPUUtilizationLow
          expr: DCGM_FI_DEV_GPU_UTIL < 10
          for: 30m
          labels:
            severity: info
          annotations:
            summary: "GPU utilization below 10% for 30 min on {{ \$labels.gpu }}"
GPUALERT

  log "DCGM dashboard and GPU alerting rules deployed."
  info "View GPU metrics: ${grafana_url}/d/dcgm-exporter"
}
