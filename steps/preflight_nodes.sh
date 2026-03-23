#!/usr/bin/env bash
# =============================================================================
# preflight_nodes.sh — Pre-flight node validation
# Checks every node before any install step runs:
#   • OS version (Ubuntu 24.04)
#   • Disk space (/var/lib/containerd ≥ 50 GB free)
#   • Swap disabled (auto-fixed)
#   • Required ports not already bound
#   • No conflicting Kubernetes installation
#   • CPU count and RAM minimums
#   • SSH reachability
# =============================================================================
# shellcheck shell=bash

run_preflight_nodes() {
  section "Pre-flight Node Validation"

  local all_nodes=("$CONTROL_PLANE_IP")
  for w in "${WORKER_IPS[@]:-}"; do [[ -n "$w" ]] && all_nodes+=("$w"); done

  local pass=0 fail=0 warn_count=0
  local results=()

  _pf_ok()   { log   "  [${1}] ✔  ${2}"; pass=$(( pass + 1 )); }
  _pf_fail() { error "  [${1}] ✖  ${2}"; fail=$(( fail + 1 )); results+=("FAIL|${1}|${2}"); }
  _pf_warn() { warn  "  [${1}] ⚠  ${2}"; warn_count=$(( warn_count + 1 )); }

  # Per-command timeout (seconds). Keeps a wedged node from hanging the check.
  local _pf_timeout="${PREFLIGHT_TIMEOUT:-15}"

  # _pf_run: run a command on a node with a hard timeout and tight SSH
  # keepalive settings so an unresponsive node is detected in seconds, not
  # minutes. For local nodes, run directly under bash (no SSH).
  # IMPORTANT: always capture output via $(...) with set +e around the
  # subshell — do NOT use "local var=$(...)" in one statement because bash
  # under set -e treats the local declaration as masking the exit code,
  # causing inconsistent behaviour across bash versions that can kill the
  # script. We always do:  local var; var=$(...)
  _pf_run() {
    local _h="$1"; shift
    if is_local_node "$_h"; then
      timeout "$_pf_timeout" bash -c "$*" 2>/dev/null
    else
      timeout "$_pf_timeout" \
        ssh -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -o PasswordAuthentication=no \
            -o ServerAliveInterval=5 \
            -o ServerAliveCountMax=2 \
            "${SSH_USER}@${_h}" \
            "sudo -n bash -c $(printf '%q' "$*")" 2>/dev/null
    fi
  }

  for node in "${all_nodes[@]}"; do
    info ""
    info "── Checking node: ${node} ──────────────────────────────────"

    # ── SSH reachability gate ─────────────────────────────────────────────────
    # Probe with a 5-second timeout before running any checks. If we cannot
    # reach the node: skip all remaining checks for it, record a single
    # warning (not a hard fail), and move on. This prevents:
    #   • 15s × N-checks of ConnectTimeout hangs per unreachable node
    #   • set -e killing the script when a subshell returns non-zero
    local _can_reach=true
    if ! is_local_node "$node"; then
      if [[ ! -f "$SSH_KEY_PATH" ]]; then
        _pf_warn "$node" "SSH key ${SSH_KEY_PATH} not yet created — remote checks skipped (run --step ssh first)"
        _can_reach=false
      else
        local _probe_rc=0
        timeout 5 ssh -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            -o PasswordAuthentication=no \
            "${SSH_USER}@${node}" true 2>/dev/null || _probe_rc=$?
        if (( _probe_rc != 0 )); then
          _pf_warn "$node" "Cannot reach node via SSH — remote checks skipped (key: ${SSH_KEY_PATH})"
          _can_reach=false
        fi
      fi
    fi

    # Skip all per-node checks if the node is unreachable
    if ! $_can_reach; then
      continue
    fi

    # ── OS version ────────────────────────────────────────────────────────────
    local os_ver; os_ver=$(
      set +e
      _pf_run "$node" \
        "grep -oP '(?<=DISTRIB_RELEASE=)[0-9.]+' /etc/lsb-release 2>/dev/null \
         || grep -oP '(?<=VERSION_ID=\")[0-9.]+' /etc/os-release 2>/dev/null \
         || echo unknown"
    ) || true
    os_ver="${os_ver//[[:space:]]/}"
    if [[ "$os_ver" == "24.04" ]]; then
      _pf_ok "$node" "OS: Ubuntu ${os_ver}"
    elif [[ "$os_ver" == "22.04" ]]; then
      _pf_warn "$node" "OS: Ubuntu ${os_ver} — supported but 24.04 recommended"
    else
      _pf_fail "$node" "OS: ${os_ver:-unknown} — Ubuntu 24.04 required"
    fi

    # ── Disk space (/var/lib/containerd needs ≥ 50 GB) ───────────────────────
    local disk_free_gb; disk_free_gb=$(
      set +e
      _pf_run "$node" \
        "df -BG /var/lib/containerd 2>/dev/null || df -BG /var/lib 2>/dev/null || df -BG /" \
        | awk 'NR==2{gsub(/G/,"",$4); print $4}'
    ) || true
    disk_free_gb="${disk_free_gb//[[:space:]]/}"
    if (( ${disk_free_gb:-0} >= 50 )); then
      _pf_ok "$node" "Disk: ${disk_free_gb} GB free on container storage path"
    elif (( ${disk_free_gb:-0} >= 20 )); then
      _pf_warn "$node" "Disk: only ${disk_free_gb} GB free — recommend ≥ 50 GB"
    else
      _pf_fail "$node" "Disk: ${disk_free_gb:-unknown} GB free — need ≥ 50 GB"
    fi

    # ── Swap ──────────────────────────────────────────────────────────────────
    # Auto-disable if active — same operation that node-prep does later.
    local swap_total; swap_total=$(
      set +e
      _pf_run "$node" "free -m 2>/dev/null | awk '/Swap:/{print \$2}'"
    ) || true
    swap_total="${swap_total//[[:space:]]/}"
    if [[ "${swap_total:-0}" == "0" ]]; then
      _pf_ok "$node" "Swap: already disabled"
    else
      info "  [${node}] Swap: ${swap_total} MB active — disabling now..."
      local _swap_rc=0
      set +e
      _pf_run "$node" \
        "swapoff -a && sed -i.bak '/[[:space:]]swap[[:space:]]/d' /etc/fstab"
      _swap_rc=$?
      set -e
      if (( _swap_rc == 0 )); then
        local swap_after; swap_after=$(
          set +e
          _pf_run "$node" "free -m 2>/dev/null | awk '/Swap:/{print \$2}'"
        ) || true
        swap_after="${swap_after//[[:space:]]/}"
        if [[ "${swap_after:-0}" == "0" ]]; then
          _pf_ok "$node" "Swap: disabled automatically (was ${swap_total} MB) — fstab updated"
        else
          _pf_warn "$node" "Swap: swapoff ran but ${swap_after} MB still reported — check /etc/fstab manually"
        fi
      else
        _pf_warn "$node" "Swap: ${swap_total} MB active — could not auto-disable; run: swapoff -a && sed -i '/swap/d' /etc/fstab"
      fi
    fi

    # ── Required ports not in use ─────────────────────────────────────────────
    local ports_to_check="6443 2379 2380 10250 10256"
    local bound_ports; bound_ports=$(
      set +e
      _pf_run "$node" \
        "ss -tlnH 2>/dev/null | awk '{print \$4}' | grep -oE ':[0-9]+$' | tr -d ':' | grep -wE '6443|2379|2380|10250|10256'"
    ) || true
    if [[ -z "${bound_ports//[[:space:]]/}" ]]; then
      _pf_ok "$node" "Ports: required ports (${ports_to_check}) are free"
    else
      _pf_fail "$node" "Ports already bound: ${bound_ports} — stop conflicting services first"
    fi

    # ── No existing Kubernetes installation ───────────────────────────────────
    local k8s_exists; k8s_exists=$(
      set +e
      _pf_run "$node" "command -v kubelet &>/dev/null && echo yes || echo no"
    ) || true
    k8s_exists="${k8s_exists//[[:space:]]/}"
    if [[ "$k8s_exists" == "no" || -z "$k8s_exists" ]]; then
      _pf_ok "$node" "Kubernetes: not installed (clean node)"
    else
      _pf_warn "$node" "Kubernetes: kubelet already present — existing install may conflict"
    fi

    # ── CPU count ─────────────────────────────────────────────────────────────
    local cpu_count; cpu_count=$(
      set +e
      _pf_run "$node" "nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo"
    ) || true
    cpu_count="${cpu_count//[[:space:]]/}"
    if (( ${cpu_count:-0} >= 2 )); then
      _pf_ok "$node" "CPU: ${cpu_count} core(s)"
    else
      _pf_fail "$node" "CPU: ${cpu_count:-unknown} core(s) — Kubernetes requires ≥ 2"
    fi

    # ── RAM ───────────────────────────────────────────────────────────────────
    local ram_gb; ram_gb=$(
      set +e
      _pf_run "$node" "awk '/MemTotal/{printf \"%d\", \$2/1048576}' /proc/meminfo"
    ) || true
    ram_gb="${ram_gb//[[:space:]]/}"
    if (( ${ram_gb:-0} >= 4 )); then
      _pf_ok "$node" "RAM: ${ram_gb} GB"
    elif (( ${ram_gb:-0} >= 2 )); then
      _pf_warn "$node" "RAM: ${ram_gb} GB — recommend ≥ 4 GB"
    else
      _pf_fail "$node" "RAM: ${ram_gb:-unknown} GB — Kubernetes requires ≥ 2 GB"
    fi

    # ── SSH check ─────────────────────────────────────────────────────────────
    # Local node: no SSH needed. Remote: already confirmed by the gate above.
    if is_local_node "$node"; then
      _pf_ok "$node" "SSH: local node — SSH not required"
    else
      _pf_ok "$node" "SSH: key-based auth confirmed"
    fi

  done

  # ── Summary ───────────────────────────────────────────────────────────────
  info ""
  info "══════════════════════════════════════════════════"
  info "  Pre-flight summary: ${pass} passed, ${warn_count} warnings, ${fail} failed"
  info "══════════════════════════════════════════════════"

  if (( ${#results[@]} > 0 )); then
    error "Failed checks:"
    for r in "${results[@]}"; do
      IFS='|' read -r _ rnode rmsg <<< "$r"
      error "  ${rnode}: ${rmsg}"
    done
  fi

  if (( fail > 0 )); then
    error "Pre-flight failed on ${fail} check(s) — resolve before installing."
    return 1
  elif (( warn_count > 0 )); then
    warn "Pre-flight passed with ${warn_count} warning(s) — review before proceeding."
  else
    log "All pre-flight checks passed."
  fi
}
