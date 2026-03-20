#!/usr/bin/env bash
# =============================================================================
# wizard/sections/07_dashboard.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_dashboard() {
  section_header "Kubernetes Dashboard" "7/10"
  hint "Deploys the official Kubernetes Dashboard with a NodePort HTTPS service."
  hint "Access via https://<control-plane>:<nodeport> using a generated admin token."
  echo ""

  prompt_yes_no INSTALL_DASHBOARD "Install Kubernetes Dashboard?" "n"
  echo ""

  if [[ "$INSTALL_DASHBOARD" == "true" ]]; then
    DASHBOARD_VERSION="2.7.0"
    while true; do
      prompt_input DASHBOARD_NODEPORT "Dashboard NodePort (HTTPS)" "32443"
      validate_nodeport "$DASHBOARD_NODEPORT" && ok "Dashboard NodePort: ${DASHBOARD_NODEPORT}" && break
    done
    echo ""
    while true; do
      prompt_input NS_DASHBOARD "Dashboard namespace" "kubernetes-dashboard"
      validate_namespace "$NS_DASHBOARD" && ok "Namespace: ${NS_DASHBOARD}" && break
    done
  else
    DASHBOARD_VERSION="2.7.0"
    DASHBOARD_NODEPORT="32443"
    NS_DASHBOARD="kubernetes-dashboard"
    warn_msg "Dashboard will be skipped."
  fi

  show_progress
}

