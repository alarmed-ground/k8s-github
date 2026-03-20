#!/usr/bin/env bash
# =============================================================================
# 01_ssh.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

setup_ssh_keys() {
  section "Step — Passwordless SSH"

  if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    info "Generating SSH key pair at ${SSH_KEY_PATH}"
    ssh-keygen -t rsa -b 4096 -N "" -C "k8s-cluster-installer" -f "$SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "${SSH_KEY_PATH}.pub"
  else
    info "SSH key already exists at ${SSH_KEY_PATH}"
  fi

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    if is_local_node "$node"; then
      info "Skipping SSH key copy for local node ${node}."
      continue
    fi
    info "Copying public key to ${node}..."
    ssh-copy-id -i "${SSH_KEY_PATH}.pub" \
      -o StrictHostKeyChecking=no \
      "${SSH_USER}@${node}" 2>&1 | tee -a "$LOG_FILE" || {
        error "Failed to copy SSH key to ${node}. Ensure the node is reachable and password auth is enabled."
        exit 1
      }
    ssh_exec "$node" "echo 'SSH OK from $(hostname)'" && log "Passwordless SSH verified for ${node}"
  done
}

