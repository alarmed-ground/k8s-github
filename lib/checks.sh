#!/usr/bin/env bash
# =============================================================================
# checks.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
    exit 1
  fi
}

check_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    error "Another instance is running (lock: $LOCK_FILE). If stale, remove it and retry."
    exit 1
  fi
  touch "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT
}

validate_config() {
  section "Validating Configuration"
  local errors=0

  [[ -z "$CONTROL_PLANE_IP" ]]   && { error "CONTROL_PLANE_IP is not set."; ((errors++)); }
  [[ ${#WORKER_IPS[@]} -eq 0 ]]  && warn "No WORKER_IPS defined — single-node cluster."

  # Auto-correct: if NFS enabled but no server IP given, disable it cleanly
  if [[ "${INSTALL_NFS:-true}" == "true" && -z "${NFS_SERVER_IP:-}" ]]; then
    warn "INSTALL_NFS=true but NFS_SERVER_IP is empty — disabling NFS provisioner."
    warn "Set NFS_SERVER_IP in k8s_cluster.conf to enable NFS storage."
    INSTALL_NFS="false"
  fi

  if (( errors > 0 )); then
    error "$errors configuration error(s). Edit the CONFIGURATION section and retry."
    exit 1
  fi
  log "Configuration validated."

  # Report which nodes will run locally vs. via SSH — helps catch misdetection
  _build_local_ip_cache
  info "Local IPs detected on this machine: ${_LOCAL_IPS}"
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  for node in "${all_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    if is_local_node "$node"; then
      info "  Node ${node} → LOCAL  (commands run directly, no SSH)"
    else
      info "  Node ${node} → REMOTE (commands run via SSH)"
    fi
  done

  # Probe nodes for sudo access and cache password once if needed.
  # This prevents "terminal required" errors during later remote steps.
  ensure_sudo_pass
}

