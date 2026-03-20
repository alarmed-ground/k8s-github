#!/usr/bin/env bash
# =============================================================================
# wizard/sections/09_namespaces.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_namespaces() {
  section_header "Kubernetes Namespaces" "9/10"
  hint "Customize namespace names, or press Enter to keep the defaults."
  echo ""

  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    while true; do
      prompt_input NS_GPU_OPERATOR "GPU Operator namespace" "gpu-operator"
      validate_namespace "$NS_GPU_OPERATOR" && ok "GPU Operator namespace: ${NS_GPU_OPERATOR}" && break
    done
  else
    NS_GPU_OPERATOR="gpu-operator"
  fi

  show_progress
}

