#!/usr/bin/env bash
# =============================================================================
# addon_mig.sh — NVIDIA MIG (Multi-Instance GPU) configuration
# Configures MIG on A100/H100 GPUs via the GPU Operator MIG manager.
# MIG_STRATEGY: none | single | mixed
#   single — all GPUs use the same MIG profile
#   mixed  — each GPU can have a different profile
# MIG_PROFILE: e.g. "1g.5gb" "2g.10gb" "3g.20gb" "4g.20gb" "7g.40gb"
# =============================================================================
# shellcheck shell=bash

configure_mig() {
  section "NVIDIA MIG Configuration"

  if [[ "${INSTALL_MIG:-false}" != "true" ]]; then
    info "INSTALL_MIG=false — skipping MIG configuration."
    return
  fi
  if [[ "${INSTALL_NVIDIA:-false}" != "true" ]]; then
    warn "INSTALL_NVIDIA=false — skipping MIG configuration."
    return
  fi

  local strategy="${MIG_STRATEGY:-none}"

  if [[ "$strategy" == "none" ]]; then
    info "MIG_STRATEGY=none — MIG not configured (standard GPU mode)."
    return
  fi

  local profile="${MIG_PROFILE:-1g.5gb}"
  info "MIG strategy: ${strategy}"
  info "MIG profile:  ${profile}"

  # ── Verify GPU Operator is deployed ──────────────────────────────────────
  if ! kubectl get namespace "$NS_GPU_OPERATOR" &>/dev/null 2>&1; then
    error "GPU Operator namespace '${NS_GPU_OPERATOR}' not found — install GPU Operator first."
    return 1
  fi

  # ── Label MIG strategy on GPU nodes ──────────────────────────────────────
  info "Labelling GPU nodes with MIG strategy '${strategy}'..."
  local labelled=0
  while IFS= read -r node_name; do
    [[ -z "$node_name" ]] && continue
    kubectl label node "$node_name" \
      nvidia.com/mig.config="${profile}" \
      --overwrite 2>/dev/null && \
    kubectl annotate node "$node_name" \
      nvidia.com/mig.config.state="pending" \
      --overwrite 2>/dev/null || true
    info "  Labelled ${node_name}: nvidia.com/mig.config=${profile}"
    labelled=$(( labelled + 1 ))
  done < <(kubectl get nodes -l nvidia.com/gpu.present=true \
    --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null)

  if (( labelled == 0 )); then
    warn "No GPU nodes found — MIG labels not applied."
    return 1
  fi

  # ── Patch ClusterPolicy MIG strategy ─────────────────────────────────────
  local cp_name
  cp_name=$(kubectl get clusterpolicy \
    --no-headers -o custom-columns='NAME:.metadata.name' \
    2>/dev/null | head -1)

  if [[ -n "$cp_name" ]]; then
    info "Patching ClusterPolicy '${cp_name}' with MIG strategy '${strategy}'..."
    kubectl patch clusterpolicy "$cp_name" \
      --type=merge \
      -p "{\"spec\":{\"migManager\":{\"enabled\":true},\"devicePlugin\":{\"config\":{\"name\":\"mig-${strategy}\",\"default\":\"all-${profile}\"}}}}" \
      && log "ClusterPolicy patched for MIG." \
      || warn "ClusterPolicy MIG patch failed — may need manual configuration."
  fi

  # ── Wait for MIG manager to apply profiles ────────────────────────────────
  info "Waiting for MIG manager to apply profiles (up to 5 min)..."
  local mig_wait=0
  while (( mig_wait < 300 )); do
    local pending
    pending=$(kubectl get nodes -l "nvidia.com/mig.config.state=pending" \
      --no-headers 2>/dev/null | wc -l)
    (( pending == 0 )) && break
    info "  [${mig_wait}s] ${pending} node(s) still applying MIG config..."
    sleep 15; mig_wait=$(( mig_wait + 15 ))
  done

  # ── Verify MIG instances are visible ─────────────────────────────────────
  info "Verifying MIG instances..."
  kubectl get nodes -o json 2>/dev/null | \
    python3 -c "
import sys, json
nodes = json.load(sys.stdin)['items']
for n in nodes:
  alloc = n['status'].get('allocatable', {})
  mig_res = {k: v for k, v in alloc.items() if 'mig' in k.lower()}
  if mig_res:
    print(f\"  {n['metadata']['name']}: {mig_res}\")
" 2>/dev/null || true

  log "MIG configuration applied. Strategy: ${strategy}, Profile: ${profile}."
  info ""
  info "List MIG-capable resources:"
  info "  kubectl get nodes -o json | jq '.items[].status.allocatable | to_entries[] | select(.key|startswith(\"nvidia.com/mig\"))'"
  info ""
  info "Request a MIG instance in a pod:"
  info "  resources:"
  info "    limits:"
  info "      nvidia.com/mig-${profile}: 1"
}
