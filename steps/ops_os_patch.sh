#!/usr/bin/env bash
# =============================================================================
# ops_os_patch.sh — Rolling OS patch (apt upgrade) across all nodes
# Drains each node, runs apt-get upgrade, reboots, waits for Ready,
# then uncordons before moving to the next node.
# =============================================================================
# shellcheck shell=bash

patch_os_rolling() {
  section "Rolling OS Patch"

  local all_nodes=()
  # Workers first, control plane last (safer order)
  for w in "${WORKER_IPS[@]:-}"; do [[ -n "$w" ]] && all_nodes+=("$w"); done
  all_nodes+=("$CONTROL_PLANE_IP")

  info "Will patch ${#all_nodes[@]} node(s) in rolling order:"
  for n in "${all_nodes[@]}"; do info "  • ${n}"; done
  info ""
  warn "Each node will be drained, upgraded, and rebooted. Workloads will reschedule."

  local patched=0 failed=0

  for node_ip in "${all_nodes[@]}"; do
    info ""
    info "── Patching node: ${node_ip} ──────────────────────────────────────"

    # Resolve Kubernetes node name from IP
    local node_name
    node_name=$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}{end}' \
      2>/dev/null | awk -v ip="$node_ip" '$2=="InternalIP" && $3==ip {print $1; exit}')

    if [[ -z "$node_name" ]]; then
      warn "Could not find Kubernetes node name for ${node_ip} — skipping drain, will still patch."
    else
      info "  Draining ${node_name}..."
      kubectl drain "$node_name" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --timeout=120s || {
          warn "  Drain had errors — proceeding anyway (DaemonSets will remain)."
        }
    fi

    # Run apt upgrade on the node
    info "  Running apt-get update && apt-get upgrade on ${node_ip}..."
    if ! run_on "$node_ip" \
        "DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
         DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
           -o Dpkg::Options::='--force-confdef' \
           -o Dpkg::Options::='--force-confold' 2>&1"; then
      error "  apt-get upgrade failed on ${node_ip}"
      failed=$(( failed + 1 ))
      # Uncordon even on failure so the node stays schedulable
      [[ -n "$node_name" ]] && kubectl uncordon "$node_name" 2>/dev/null || true
      continue
    fi
    log "  apt-get upgrade complete on ${node_ip}."

    # Check if reboot is required
    local needs_reboot
    needs_reboot=$(run_on "$node_ip" \
      "test -f /var/run/reboot-required && echo yes || echo no" \
      2>/dev/null | tr -d '[:space:]')

    if [[ "$needs_reboot" == "yes" ]]; then
      info "  Reboot required — rebooting ${node_ip}..."
      reboot_and_wait "$node_ip" "${NVIDIA_REBOOT_TIMEOUT:-300}"
      log "  ${node_ip} is back online after reboot."
    else
      info "  No reboot required for ${node_ip}."
    fi

    # Uncordon
    if [[ -n "$node_name" ]]; then
      info "  Uncordoning ${node_name}..."
      kubectl uncordon "$node_name"
      # Wait for node to be Ready
      local ready_wait=0
      while (( ready_wait < 120 )); do
        local node_status
        node_status=$(kubectl get node "$node_name" \
          --no-headers 2>/dev/null | awk '{print $2}')
        [[ "$node_status" == "Ready" ]] && break
        sleep 5; ready_wait=$(( ready_wait + 5 ))
      done
      if [[ "$(kubectl get node "$node_name" --no-headers 2>/dev/null | awk '{print $2}')" == "Ready" ]]; then
        log "  ${node_name} is Ready."
      else
        warn "  ${node_name} not Ready after 120s — check manually."
      fi
    fi

    patched=$(( patched + 1 ))
    log "  ✔ ${node_ip} patched successfully."
  done

  info ""
  log "Rolling OS patch complete: ${patched}/${#all_nodes[@]} node(s) patched${failed:+, ${failed} failed}."
}
