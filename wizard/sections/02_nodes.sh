#!/usr/bin/env bash
# =============================================================================
# wizard/sections/02_nodes.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_nodes() {
  section_header "Cluster Node IPs" "2/10"
  hint "Enter IP addresses for your control plane and worker nodes."
  hint "All nodes must be running Ubuntu 24.04 and reachable via SSH."
  echo ""

  prompt_ip CONTROL_PLANE_IP "Control plane IP" ""
  ok "Control plane: ${CONTROL_PLANE_IP}"
  echo ""

  prompt_ip_list WORKER_IPS_STR "Worker node IPs"
  echo ""

  local count=0
  if [[ "$WORKER_IPS_STR" != "()" ]]; then
    count=$(echo "$WORKER_IPS_STR" | grep -o '"' | wc -l)
    count=$((count / 2))
  fi
  if (( count == 0 )); then
    warn_msg "No workers added — single-node cluster (control plane will be un-tainted)."
  else
    ok "${count} worker node(s) registered."
  fi
  WORKER_COUNT=$count

  show_progress
}

