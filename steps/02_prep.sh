#!/usr/bin/env bash
# =============================================================================
# 02_prep.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

prepare_all_nodes() {
  section "Step — Common Node Preparation"
  local prep_script="/tmp/node_prep_$$.sh"

  generate_node_prep_script > "$prep_script"
  # 600: owner read/write only — scp_and_run no longer overrides this.
  # sudo bash on the remote only needs read access (root always has it).
  chmod 600 "$prep_script"

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    info "Preparing node ${node}..."
    run_script_on "$node" "$prep_script" || {
      error "Node preparation failed on ${node}. Check ${LOG_FILE} for details."
      rm -f "$prep_script"
      exit 1
    }
    log "Node ${node} prepared successfully."
  done
  rm -f "$prep_script"
}

