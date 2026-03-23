#!/usr/bin/env bash
# =============================================================================
# ops_vllm_health.sh — vLLM model health endpoint polling
# After pods reach Running, hits /v1/models and verifies expected model IDs.
# =============================================================================
# shellcheck shell=bash

check_vllm_health() {
  section "vLLM Model Health Check"

  if [[ "${INSTALL_VLLM:-false}" != "true" ]]; then
    info "INSTALL_VLLM=false — skipping vLLM health check."
    return
  fi

  local endpoint="http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT:-32080}/v1/models"
  local max_wait="${VLLM_HEALTH_TIMEOUT:-600}"
  local interval=15 elapsed=0

  info "Polling ${endpoint} until all models respond (up to $((max_wait/60)) min)..."

  while (( elapsed < max_wait )); do
    local response http_code
    response=$(curl -sf --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || echo "")
    http_code=$(curl -so /dev/null -w "%{http_code}" --connect-timeout 5 \
      --max-time 10 "$endpoint" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" && -n "$response" ]]; then
      # Parse model IDs from response
      local model_ids
      model_ids=$(echo "$response" | \
        python3 -c "import sys,json; \
          d=json.load(sys.stdin); \
          [print(m['id']) for m in d.get('data',[])]" 2>/dev/null || \
        echo "$response" | grep -oP '"id":"\K[^"]+' || echo "")

      if [[ -n "$model_ids" ]]; then
        log "vLLM /v1/models responded after ${elapsed}s."
        log "Available models:"
        while IFS= read -r mid; do
          log "  • ${mid}"
        done <<< "$model_ids"

        # Verify expected models are present from VLLM_MODELS config
        if declare -p VLLM_MODELS &>/dev/null && [[ ${#VLLM_MODELS[@]} -gt 0 ]]; then
          local missing=0
          for spec in "${VLLM_MODELS[@]}"; do
            local expected_id; IFS='|' read -r expected_id _ <<< "$spec"
            if echo "$model_ids" | grep -qF "$expected_id"; then
              log "  ✔ ${expected_id} — present"
            else
              warn "  ✖ ${expected_id} — NOT found in /v1/models response"
              missing=$(( missing + 1 ))
            fi
          done
          (( missing > 0 )) && warn "${missing} expected model(s) not yet loaded." \
                             || log "All expected models confirmed loaded."
        fi
        return 0
      fi
    fi

    info "  [${elapsed}s] HTTP ${http_code} — models not ready yet..."
    sleep $interval
    elapsed=$(( elapsed + interval ))
  done

  warn "vLLM /v1/models did not respond within ${max_wait}s."
  warn "Check pod logs: kubectl logs -n ${VLLM_NAMESPACE:-vllm} -l app=vllm-stack -f"
  return 1
}
