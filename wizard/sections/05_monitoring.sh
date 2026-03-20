#!/usr/bin/env bash
# =============================================================================
# wizard/sections/05_monitoring.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_monitoring() {
  section_header "Monitoring Stack — Prometheus & Grafana" "5/10"
  hint "Deploys kube-prometheus-stack via Helm."
  echo ""

  prompt_yes_no INSTALL_MONITORING "Install Prometheus + Grafana?" "y"
  echo ""

  if [[ "$INSTALL_MONITORING" == "true" ]]; then
    prompt_input PROM_STACK_VERSION "kube-prometheus-stack chart version" "65.1.0"
    ok "Chart version: ${PROM_STACK_VERSION}"
    echo ""

    while true; do
      prompt_input NS_MONITORING "Monitoring namespace" "monitoring"
      validate_namespace "$NS_MONITORING" && ok "Namespace: ${NS_MONITORING}" && break
    done
    echo ""

    hint "NodePort services will be exposed on the control plane IP."
    hint "NodePorts must be in the range 30000–32767 and must be unique."
    echo ""
    while true; do
      prompt_input GRAFANA_NODEPORT "Grafana NodePort" "32000"
      validate_nodeport "$GRAFANA_NODEPORT" && ok "Grafana: :${GRAFANA_NODEPORT}" && break
    done
    while true; do
      prompt_input PROMETHEUS_NODEPORT "Prometheus NodePort" "32001"
      validate_nodeport "$PROMETHEUS_NODEPORT" && ok "Prometheus: :${PROMETHEUS_NODEPORT}" && break
    done
    while true; do
      prompt_input ALERTMANAGER_NODEPORT "Alertmanager NodePort" "32002"
      validate_nodeport "$ALERTMANAGER_NODEPORT" && ok "Alertmanager: :${ALERTMANAGER_NODEPORT}" && break
    done
    echo ""

    local pw1="" pw2=""
    while true; do
      echo -ne "  ${BOLD}Grafana admin password${NC}: "
      read -r -s pw1; echo ""
      validate_password_strength "$pw1" || continue
      echo -ne "  ${BOLD}Confirm password${NC}: "
      read -r -s pw2; echo ""
      if [[ "$pw1" == "$pw2" ]]; then
        GRAFANA_ADMIN_PASSWORD="$pw1"
        ok "Grafana password set."
        break
      else
        err "Passwords do not match. Try again."
      fi
    done
    echo ""

    prompt_input PROM_RETENTION "Prometheus data retention" "30d"
    ok "Retention: ${PROM_RETENTION}"
    prompt_input PROM_STORAGE_SIZE "Prometheus PVC size" "20Gi"
    ok "Storage: ${PROM_STORAGE_SIZE}"

  else
    PROM_STACK_VERSION="65.1.0"
    NS_MONITORING="monitoring"
    GRAFANA_ADMIN_PASSWORD="ChangeMe123!"
    GRAFANA_NODEPORT="32000"
    PROMETHEUS_NODEPORT="32001"
    ALERTMANAGER_NODEPORT="32002"
    PROM_RETENTION="30d"
    PROM_STORAGE_SIZE="20Gi"
    warn_msg "Monitoring stack will be skipped."
  fi

  show_progress
}

