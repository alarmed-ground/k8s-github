#!/usr/bin/env bash
# =============================================================================
# 03_nvidia.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_nvidia_drivers() {
  section "Step 3 — NVIDIA Driver Installation"
  if [[ "${INSTALL_NVIDIA}" != "true" ]]; then
    warn "INSTALL_NVIDIA=false — skipping NVIDIA drivers."
    return
  fi

  local open_kernel="${NVIDIA_OPEN_KERNEL:-false}"
  local fabric_mgr="${NVIDIA_FABRIC_MANAGER:-auto}"
  local reboot_timeout="${NVIDIA_REBOOT_TIMEOUT:-300}"  # configurable via conf

  info "Driver branch  : ${NVIDIA_DRIVER_VERSION}"
  info "Open kernel    : ${open_kernel}"
  info "Fabric Manager : ${fabric_mgr}"
  info "Reboot timeout : ${reboot_timeout}s per node"

  # Generate both phase scripts once
  local phase1_script="/tmp/nvidia_phase1_$$.sh"
  local phase2_script="/tmp/nvidia_phase2_$$.sh"

  generate_nvidia_install_script \
    "$NVIDIA_DRIVER_VERSION" "$open_kernel" "$fabric_mgr" > "$phase1_script"
  generate_nvidia_postboot_script \
    "$NVIDIA_DRIVER_VERSION" > "$phase2_script"

  chmod 600 "$phase1_script" "$phase2_script"

  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  for node in "${all_nodes[@]}"; do
    [[ -z "$node" ]] && continue

    section "  NVIDIA Install — Node ${node}"

    # ── GPU detection — done HERE, before uploading anything ─────────────────
    # Run lspci as SSH_USER (no sudo needed — lspci is world-readable).
    # If lspci is missing, install pciutils first via a quick sudo one-liner,
    # then re-check. We do NOT rely on a sentinel file; the decision is made
    # locally based on the SSH output before any reboot logic is reached.
    info "[${node}] Probing for NVIDIA GPU..."

    # Ensure lspci is available (may not be on minimal Ubuntu cloud images)
    if ! run_on "$node" "command -v lspci" &>/dev/null; then
      info "[${node}] pciutils not found — installing..."
      run_on "$node" "apt-get install -y -qq pciutils" 2>/dev/null || true
    fi

    # lspci output is checked with grep -qi; exit code 1 = no match = no GPU
    if ! run_on "$node" "lspci 2>/dev/null | grep -qi nvidia"; then
      warn "[${node}] No NVIDIA GPU detected — skipping driver install and reboot."
      continue   # <── straight to next node, no Phase 1, no reboot, no Phase 2
    fi

    local gpu_name
    gpu_name=$(run_on "$node" "lspci 2>/dev/null | grep -i nvidia | head -1" 2>/dev/null || echo "unknown")
    log "[${node}] GPU detected: ${gpu_name}"

    # ── Phase 1: install driver packages ─────────────────────────────────────
    info "[${node}] Phase 1 — Installing driver packages..."
    run_script_on "$node" "$phase1_script" || {
      error "NVIDIA Phase 1 failed on ${node}."
      rm -f "$phase1_script" "$phase2_script"
      exit 1
    }
    log "[${node}] Phase 1 complete."

    # ── Reboot — only runs because we confirmed a GPU exists above ────────────
    info "[${node}] Rebooting to load NVIDIA kernel module..."
    reboot_and_wait "$node" "$reboot_timeout" || {
      error "Node ${node} did not come back after reboot. Installation cannot continue."
      rm -f "$phase1_script" "$phase2_script"
      exit 1
    }
    log "[${node}] Node is back online."

    # ── Phase 2: verify nvidia-smi + container toolkit ────────────────────────
    info "[${node}] Phase 2 — Post-reboot verification and container toolkit..."
    run_script_on "$node" "$phase2_script" || {
      error "NVIDIA Phase 2 failed on ${node}. Check nvidia-smi and dmesg on the node."
      rm -f "$phase1_script" "$phase2_script"
      exit 1
    }
    log "[${node}] NVIDIA fully activated and container toolkit configured."
  done

  rm -f "$phase1_script" "$phase2_script"
  section "Step — NVIDIA Installation Complete (all nodes)"
}

