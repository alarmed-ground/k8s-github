#!/usr/bin/env bash
# =============================================================================
# 04_k8s_bins.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_k8s_binaries() {
  section "Step — Kubernetes Binaries (kubeadm / kubelet / kubectl)"
  local bin_script="/tmp/k8s_binaries_$$.sh"
  generate_k8s_binaries_script "$K8S_VERSION" > "$bin_script"
  chmod 700 "$bin_script"   # owner execute; SCP sends readable file to remote

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    info "Installing k8s binaries on ${node}..."
    run_script_on "$node" "$bin_script" || {
      error "k8s binary installation failed on ${node}."
      rm -f "$bin_script"
      exit 1
    }
    log "k8s binaries installed on ${node}."
  done
  rm -f "$bin_script"
}

