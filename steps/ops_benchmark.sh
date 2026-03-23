#!/usr/bin/env bash
# =============================================================================
# ops_benchmark.sh — Inference benchmark against vLLM endpoint
# Uses curl to run a timed load test: N concurrent requests × M total requests.
# Reports: tokens/sec, P50/P95/P99 latency, GPU utilisation snapshot.
# =============================================================================
# shellcheck shell=bash

benchmark_vllm() {
  section "vLLM Inference Benchmark"

  if [[ "${INSTALL_VLLM:-false}" != "true" ]]; then
    info "INSTALL_VLLM=false — skipping benchmark."
    return
  fi

  local endpoint="http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT:-32080}"
  local concurrency="${BENCH_CONCURRENCY:-4}"
  local total_requests="${BENCH_REQUESTS:-20}"
  local prompt="${BENCH_PROMPT:-Tell me a short story about a robot learning to cook.}"
  local max_tokens="${BENCH_MAX_TOKENS:-100}"

  # Detect model to benchmark
  local model_id="${VLLM_MODEL:-}"
  if declare -p VLLM_MODELS &>/dev/null && [[ ${#VLLM_MODELS[@]} -gt 0 ]]; then
    IFS='|' read -r model_id _ <<< "${VLLM_MODELS[0]}"
  fi

  info "Benchmark configuration:"
  info "  Endpoint:    ${endpoint}/v1/chat/completions"
  info "  Model:       ${model_id}"
  info "  Concurrency: ${concurrency}"
  info "  Requests:    ${total_requests}"
  info "  Max tokens:  ${max_tokens}"

  # ── Check endpoint is live ────────────────────────────────────────────────
  if ! curl -sf --connect-timeout 5 "${endpoint}/v1/models" &>/dev/null; then
    error "vLLM endpoint not reachable at ${endpoint} — run check_vllm_health first."
    return 1
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d /tmp/vllm_bench_XXXXXX)
  local payload
  payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%d,"stream":false}' \
    "$model_id" "$prompt" "$max_tokens")

  # ── Run requests (bash parallel with background jobs) ─────────────────────
  info "Running ${total_requests} requests (${concurrency} concurrent)..."
  local start_epoch; start_epoch=$(date +%s%3N)
  local completed=0 errors=0
  local latencies=()

  _run_request() {
    local req_id="$1" out_file="$2"
    local t_start; t_start=$(date +%s%3N)
    local http_code
    http_code=$(curl -so "$out_file" -w "%{http_code}" \
      --connect-timeout 10 --max-time 120 \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${endpoint}/v1/chat/completions" 2>/dev/null)
    local t_end; t_end=$(date +%s%3N)
    echo "$((t_end - t_start)) $http_code" > "${out_file}.meta"
  }

  local slot=0
  local pids=()
  for (( i=1; i<=total_requests; i++ )); do
    local out="${tmp_dir}/req_${i}"
    _run_request "$i" "$out" &
    pids+=($!)
    slot=$(( slot + 1 ))
    if (( slot >= concurrency )); then
      wait "${pids[0]}" 2>/dev/null; pids=("${pids[@]:1}")
      slot=$(( slot - 1 ))
    fi
  done
  # Wait for remaining
  for pid in "${pids[@]:-}"; do wait "$pid" 2>/dev/null || true; done

  local end_epoch; end_epoch=$(date +%s%3N)
  local total_ms=$(( end_epoch - start_epoch ))

  # ── Collect results ───────────────────────────────────────────────────────
  local total_tokens=0
  for (( i=1; i<=total_requests; i++ )); do
    local meta="${tmp_dir}/req_${i}.meta"
    [[ -f "$meta" ]] || continue
    read -r latency_ms http_code < "$meta"
    if [[ "$http_code" == "200" ]]; then
      latencies+=("$latency_ms")
      completed=$(( completed + 1 ))
      # Count tokens from response
      local tokens
      tokens=$(python3 -c "
import sys,json
try:
  d=json.load(open('${tmp_dir}/req_${i}'))
  print(d.get('usage',{}).get('completion_tokens',0))
except: print(0)
" 2>/dev/null || echo 0)
      total_tokens=$(( total_tokens + tokens ))
    else
      errors=$(( errors + 1 ))
    fi
  done

  # ── Compute statistics ────────────────────────────────────────────────────
  local throughput_rps throughput_tps
  throughput_rps=$(python3 -c "print(f'{${completed} * 1000 / ${total_ms:.0f}:.2f}')" 2>/dev/null || echo "?")
  throughput_tps=$(python3 -c "print(f'{${total_tokens} * 1000 / ${total_ms}:.1f}')" 2>/dev/null || echo "?")

  local p50 p95 p99
  if (( ${#latencies[@]} > 0 )); then
    read -r p50 p95 p99 < <(python3 - <<PYEOF
lats = sorted([${latencies[*]:-0}])
n = len(lats)
def pct(p): return lats[min(int(n*p/100), n-1)] if n > 0 else 0
print(pct(50), pct(95), pct(99))
PYEOF
)
  else
    p50=0; p95=0; p99=0
  fi

  # ── GPU utilisation snapshot (via DCGM if available) ─────────────────────
  local gpu_util="N/A"
  if [[ "${INSTALL_MONITORING:-false}" == "true" ]]; then
    gpu_util=$(curl -sf --connect-timeout 5 --max-time 5 \
      "http://${CONTROL_PLANE_IP}:${PROMETHEUS_NODEPORT:-32001}/api/v1/query?query=avg(DCGM_FI_DEV_GPU_UTIL)" \
      2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); \
        v=d['data']['result']; print(f\"{float(v[0]['value'][1]):.1f}%\" if v else 'N/A')" \
      2>/dev/null || echo "N/A")
  fi

  # ── Report ────────────────────────────────────────────────────────────────
  info ""
  info "══════════════════════════════════════════════════"
  log  "  vLLM Benchmark Results"
  info "══════════════════════════════════════════════════"
  info "  Requests:       ${completed}/${total_requests} succeeded, ${errors} errors"
  info "  Total time:     $((total_ms / 1000)).$((total_ms % 1000 / 100))s"
  info "  Throughput:     ${throughput_rps} req/s"
  info "  Tokens/sec:     ${throughput_tps} tok/s"
  info "  Latency P50:    ${p50} ms"
  info "  Latency P95:    ${p95} ms"
  info "  Latency P99:    ${p99} ms"
  info "  GPU utilisation: ${gpu_util}"
  info "══════════════════════════════════════════════════"

  rm -rf "$tmp_dir"
  log "Benchmark complete."
}
