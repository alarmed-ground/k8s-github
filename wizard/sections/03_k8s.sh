#!/usr/bin/env bash
# =============================================================================
# wizard/sections/03_k8s.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_k8s() {
  section_header "Kubernetes Settings" "3/10"
  echo ""

  while true; do
    prompt_input K8S_VERSION "Kubernetes version (minor)" "1.31"
    validate_k8s_version "$K8S_VERSION" && ok "K8s version: ${K8S_VERSION}" && break
  done
  echo ""

  prompt_choice CNI_PLUGIN "Container Network Interface (CNI) plugin" \
    "flannel (recommended — VXLAN, works on VMs and bare metal)" \
    "calico (advanced — NetworkPolicy support, VXLAN mode)"
  CNI_PLUGIN="${CNI_PLUGIN%% *}"
  ok "CNI: ${CNI_PLUGIN}"
  echo ""

  local default_cidr="10.244.0.0/16"
  [[ "$CNI_PLUGIN" == "calico" ]] && default_cidr="192.168.0.0/16"
  hint "Default CIDR auto-selected for ${CNI_PLUGIN}: ${default_cidr}"

  while true; do
    prompt_input POD_CIDR "Pod network CIDR" "$default_cidr"
    validate_cidr "$POD_CIDR" && ok "Pod CIDR: ${POD_CIDR}" && break
    err "'${POD_CIDR}' is not a valid CIDR."
  done
  echo ""

  while true; do
    prompt_input HELM_VERSION "Helm version" "3.16.2"
    validate_helm_version "$HELM_VERSION" && ok "Helm: ${HELM_VERSION}" && break
  done

  show_progress
}

