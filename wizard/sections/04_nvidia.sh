#!/usr/bin/env bash
# =============================================================================
# wizard/sections/04_nvidia.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_nvidia() {
  section_header "NVIDIA Drivers" "4/10"
  hint "The installer auto-detects GPUs via lspci and skips non-GPU nodes."
  echo ""

  prompt_yes_no INSTALL_NVIDIA "Install NVIDIA drivers and GPU Operator?" "y"
  echo ""

  if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    echo -e "  ${BOLD}${BLUE}  Driver Branch Reference:${NC}"
    echo -e "  ${DIM}  590  │ LATEST   │ RTX 50xx, GB200/B200/B100 (Blackwell), H200${NC}"
    echo -e "  ${DIM}  580  │ Latest-1 │ RTX 50xx, Blackwell, H200 — previous latest${NC}"
    echo -e "  ${DIM}  570  │ Stable   │ RTX 50xx, Blackwell, H200 — stable${NC}"
    echo -e "  ${DIM}  565  │ Stable   │ RTX 40xx, A/H series — production stable${NC}"
    echo -e "  ${DIM}  560  │ Stable   │ RTX 40xx, A/H series — previous stable${NC}"
    echo -e "  ${DIM}  550  │ LTS      │ Ampere/Hopper/Lovelace — widely deployed${NC}"
    echo -e "  ${DIM}  535  │ LTS      │ Ampere DataCenter A100/A30/A10${NC}"
    echo -e "  ${DIM}  525  │ Legacy   │ Older Ampere platforms${NC}"
    echo ""

    prompt_choice NVIDIA_DRIVER_VERSION \
      "Select NVIDIA driver branch" \
      "590 (LATEST — Blackwell/RTX 50xx/GB200/H200)" \
      "580 (Previous latest — Blackwell/RTX 50xx/H200)" \
      "570 (Stable — Blackwell/RTX 50xx/H200)" \
      "565 (Stable — RTX 40xx / A-H series)" \
      "560 (Previous stable — RTX 40xx / A-H series)" \
      "550 (LTS — Ampere/Hopper/Lovelace — recommended for older HW)" \
      "535 (LTS — Ampere DataCenter A100/A30/A10)" \
      "525 (Legacy LTS — older Ampere)"
    NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION%% *}"
    ok "NVIDIA driver branch: ${NVIDIA_DRIVER_VERSION}"
    echo ""

    echo -e "  ${BOLD}${BLUE}  Open Kernel Modules:${NC}"
    echo -e "  ${DIM}  Recommended for Turing (RTX 20xx) and newer GPUs.${NC}"
    echo -e "  ${DIM}  REQUIRED for Blackwell (B-series).${NC}"
    echo ""
    local default_open="n"
    if [[ "$NVIDIA_DRIVER_VERSION" =~ ^(590|580|570)$ ]]; then
      default_open="y"
      hint "Branch ${NVIDIA_DRIVER_VERSION} targets Blackwell/RTX 50xx — open kernel modules are strongly recommended."
    fi
    prompt_yes_no NVIDIA_OPEN_KERNEL \
      "Use open kernel modules (nvidia-driver-${NVIDIA_DRIVER_VERSION}-open)?" "$default_open"
    if [[ "$NVIDIA_OPEN_KERNEL" == "true" ]]; then
      ok "Open kernel modules: enabled"
    else
      ok "Open kernel modules: disabled (proprietary)"
    fi
    echo ""

    echo -e "  ${BOLD}${BLUE}  Fabric Manager:${NC}"
    echo -e "  ${DIM}  Required for NVLink/NVSwitch multi-GPU systems (A100 SXM4, H100 SXM5, DGX, HGX).${NC}"
    echo -e "  ${DIM}  Not needed for single PCIe GPU nodes.${NC}"
    echo ""
    prompt_choice NVIDIA_FABRIC_MANAGER \
      "Fabric Manager installation" \
      "auto (detect NVSwitch/SXM at install time — recommended)" \
      "yes (always install)" \
      "no (never install)"
    case "$NVIDIA_FABRIC_MANAGER" in
      auto*) NVIDIA_FABRIC_MANAGER="auto" ;;
      yes*)  NVIDIA_FABRIC_MANAGER="true" ;;
      no*)   NVIDIA_FABRIC_MANAGER="false" ;;
    esac
    ok "Fabric Manager: ${NVIDIA_FABRIC_MANAGER}"
    echo ""

    # ── GPU Time-Slicing ──────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  GPU Time-Slicing:${NC}"
    echo -e "  ${DIM}  Expose multiple virtual GPUs per physical GPU.${NC}"
    echo -e "  ${DIM}  Useful for sharing one GPU across multiple inference pods.${NC}"
    echo -e "  ${DIM}  No memory isolation — all slices share VRAM. Works on any GPU.${NC}"
    echo ""
    prompt_yes_no GPU_TIMESLICING_ENABLED "Enable GPU time-slicing?" "n"
    if [[ "$GPU_TIMESLICING_ENABLED" == "true" ]]; then
      while true; do
        prompt_input GPU_TIMESLICE_COUNT "Virtual GPUs per physical GPU" "4"
        [[ "$GPU_TIMESLICE_COUNT" =~ ^[2-9]$|^[1-9][0-9]+$ ]]           && ok "Time-slicing: ${GPU_TIMESLICE_COUNT}x virtual GPUs per physical GPU"           && break
        err "Must be an integer >= 2."
      done
    else
      GPU_TIMESLICE_COUNT="4"
      ok "GPU time-slicing: disabled"
    fi
    echo ""

    # ── Toolkit ISA compatibility ─────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Toolkit CPU Compatibility${NC}"
    echo -e "  ${DIM}  The NVIDIA Container Toolkit ships x86-64-v3 (AVX2) binaries by default.${NC}"
    echo -e "  ${DIM}  Older server CPUs (Sandy/Ivy Bridge, Xeon E5 v2/v3, pre-Broadwell)${NC}"
    echo -e "  ${DIM}  will fail with: "CPU ISA level is lower than required"${NC}"
    echo -e "  ${DIM}  The -ubi8 toolkit tag ships x86-64-v2 compatible binaries.${NC}"
    echo ""

    # Try to auto-detect AVX2 on this machine (control plane)
    local _has_avx2="unknown"
    if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
      _has_avx2="yes"
    elif [[ -f /proc/cpuinfo ]]; then
      _has_avx2="no"
    fi

    if [[ "$_has_avx2" == "no" ]]; then
      warn_msg "⚠  This machine does NOT have AVX2 — GPU nodes may need the -ubi8 toolkit."
      hint "Setting default to 'v1.17.3-ubi8' (x86-64-v2 compatible)."
      NVIDIA_TOOLKIT_VERSION="v1.17.3-ubi8"
    elif [[ "$_has_avx2" == "yes" ]]; then
      hint "AVX2 detected on this machine — default toolkit should work."
      hint "If GPU worker nodes have older CPUs without AVX2, choose the ubi8 option."
      NVIDIA_TOOLKIT_VERSION="auto"
    else
      NVIDIA_TOOLKIT_VERSION="auto"
    fi

    prompt_choice NVIDIA_TOOLKIT_VERSION       "Toolkit image compatibility"       "auto (detect AVX2 at install time — recommended)"       "v1.17.3-ubi8 (x86-64-v2 / no AVX2 — older Xeon E5, Sandy/Ivy Bridge)"       "default (always use chart default — fastest, may fail on old CPUs)"       "custom (enter a specific toolkit version tag)"
    case "$NVIDIA_TOOLKIT_VERSION" in
      auto*)    NVIDIA_TOOLKIT_VERSION="auto" ;;
      v1.17*|*ubi8*) NVIDIA_TOOLKIT_VERSION="v1.17.3-ubi8" ;;
      default*) NVIDIA_TOOLKIT_VERSION="default" ;;
      custom*)
        prompt_input NVIDIA_TOOLKIT_VERSION           "Toolkit version tag (e.g. v1.17.3-ubi8)" "v1.17.3-ubi8" ;;
    esac
    ok "Toolkit compatibility: ${NVIDIA_TOOLKIT_VERSION}"
    echo ""

    echo -e "  ${BOLD}${BLUE}  Reboot Timeout:${NC}"
    echo -e "  ${DIM}  After the driver installs, each node reboots. This is the max seconds${NC}"
    echo -e "  ${DIM}  to wait per node for SSH to return. Slow hardware may need 600s.${NC}"
    echo ""
    while true; do
      prompt_input NVIDIA_REBOOT_TIMEOUT "Seconds to wait per node after reboot" "300"
      [[ "$NVIDIA_REBOOT_TIMEOUT" =~ ^[0-9]+$ ]] && (( NVIDIA_REBOOT_TIMEOUT >= 60 )) \
        && ok "Reboot timeout: ${NVIDIA_REBOOT_TIMEOUT}s" && break
      err "Must be a number >= 60."
    done

  else
    NVIDIA_DRIVER_VERSION="590"
    NVIDIA_OPEN_KERNEL="false"
    NVIDIA_FABRIC_MANAGER="auto"
    NVIDIA_REBOOT_TIMEOUT="300"
    NVIDIA_TOOLKIT_VERSION="auto"
    GPU_TIMESLICING_ENABLED="false"
    GPU_TIMESLICE_COUNT="4"
    warn_msg "Skipping NVIDIA. GPU Operator will also be skipped."
  fi

  show_progress
}

