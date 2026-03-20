#!/usr/bin/env bash
# =============================================================================
# ops_vllm_swap.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

vllm_swap() {
  section "vLLM Model Swap"

  if [[ "${INSTALL_VLLM:-false}" != "true" ]]; then
    warn "INSTALL_VLLM=false — vLLM is not deployed."
    return
  fi

  local new_model="${VLLM_SWAP_MODEL:-}"
  if [[ -z "$new_model" ]]; then
    info "Current model: ${VLLM_MODEL}"
    echo -ne "  New HuggingFace model ID: "
    read -r new_model </dev/tty
  fi
  [[ -z "$new_model" ]] && { error "No model ID provided."; exit 1; }

  # Derive short name (same logic as install_vllm)
  local new_name
  new_name=$(echo "$new_model" | tr '[:upper:]' '[:lower:]' | sed 's|.*/||;s/[^a-z0-9-]/-/g;s/-\+/-/g;s/^-//;s/-$//' | cut -c1-40)

  info "Swapping vLLM model: ${VLLM_MODEL} -> ${new_model}"
  info "The new engine pod will start alongside the old one."
  info "Traffic will shift to the new pod once it passes its readiness probe."

  helm upgrade vllm-stack vllm/vllm-stack \
    -n "$VLLM_NAMESPACE" \
    --reuse-values \
    --set "servingEngineSpec.modelSpec[0].modelURL=${new_model}" \
    --set "servingEngineSpec.modelSpec[0].name=${new_name}" \
    --timeout 2m || {
      error "Helm upgrade failed."
      exit 1
    }

  info "Helm upgrade applied. Watching rollout (this may take ${VLLM_MODEL_LOAD_WAIT:-20} min)..."
  local elapsed=0
  local max=1800
  while (( elapsed < max )); do
    local status
    status=$(kubectl get pods -n "$VLLM_NAMESPACE" --no-headers 2>/dev/null \
      | awk '!/router/ && NF>0 {print $3}' | sort -u | tr '\n' '/')
    info "  Engine pod status: ${status:-Unknown} (${elapsed}s)"
    if echo "$status" | grep -q "Running"; then
      log "New engine pod is Running."
      break
    fi
    sleep 20; elapsed=$(( elapsed + 20 ))
  done

  # Verify new model is served
  local api_model
  api_model=$(curl -sf "http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1/models" \
    | python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin)['data']]" \
    2>/dev/null || echo "unknown")
  info "Models now served: ${api_model}"
  log "Model swap complete. Update VLLM_MODEL=${new_model} in k8s_cluster.conf."
}

