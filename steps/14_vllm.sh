#!/usr/bin/env bash
# =============================================================================
# 14_vllm.sh — vLLM Production Stack (multi-model support)
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
#
# Multi-model configuration:
#   VLLM_MODELS — bash array of model specs.  Each element is a
#   pipe-delimited string with 14 fields (see _parse_model_spec below).
#   When VLLM_MODELS is empty or unset the installer falls back to the legacy
#   single-model variables (VLLM_MODEL, VLLM_GPU_COUNT, …) for backward
#   compatibility with existing k8s_cluster.conf files.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

# ── Parse one pipe-delimited model spec string into named locals ──────────────
# Field order (must match _build_model_spec and wizard):
#   1  model_id          HuggingFace model ID
#   2  gpu_count         GPUs per replica
#   3  dtype             auto|float16|bfloat16|float32
#   4  max_model_len     token context length
#   5  cpu_request       CPU cores requested
#   6  cpu_limit         CPU cores limit
#   7  mem_request       memory request  (e.g. 16Gi)
#   8  mem_limit         memory limit    (e.g. 32Gi)
#   9  extra_args        extra --engine flags (space-separated)
#   10 storage_size      PVC size (e.g. 50Gi); empty = reuse
#   11 reuse_pvc         true|false
#   12 pvc_name          PVC name
#   13 quantization      none|awq|gptq|bnb
#   14 hf_token          HuggingFace token (may be empty)
#   15 node_selector     node pin — hostname, IP, or label key=value
#                        (empty = any GPU node)
#                        Examples:  gpu-node-01
#                                   192.168.1.50
#                                   gpu-type=a100
#                                   hostname=worker-3,gpu-type=h100
_parse_model_spec() {
  local spec="$1"
  IFS='|' read -r \
    _ms_model_id _ms_gpu_count _ms_dtype _ms_max_len \
    _ms_cpu_req  _ms_cpu_lim  _ms_mem_req _ms_mem_lim \
    _ms_extra    _ms_storage  _ms_reuse   _ms_pvc \
    _ms_quant    _ms_hf_token _ms_node_selector \
    <<< "$spec"
  # Defaults for any empty fields
  _ms_model_id="${_ms_model_id:-meta-llama/Llama-3.2-1B-Instruct}"
  _ms_gpu_count="${_ms_gpu_count:-1}"
  _ms_dtype="${_ms_dtype:-auto}"
  _ms_max_len="${_ms_max_len:-4096}"
  _ms_cpu_req="${_ms_cpu_req:-4}"
  _ms_cpu_lim="${_ms_cpu_lim:-8}"
  _ms_mem_req="${_ms_mem_req:-16Gi}"
  _ms_mem_lim="${_ms_mem_lim:-32Gi}"
  _ms_extra="${_ms_extra:-}"
  _ms_storage="${_ms_storage:-50Gi}"
  _ms_reuse="${_ms_reuse:-false}"
  _ms_pvc="${_ms_pvc:-vllm-model-cache}"
  _ms_quant="${_ms_quant:-none}"
  _ms_hf_token="${_ms_hf_token:-}"
  _ms_node_selector="${_ms_node_selector:-}"
}

# ── Compute startup probe parameters from model ID + GPU count ────────────────
_probe_timing() {
  local model_id="$1" gpu_count="${2:-1}"
  local model_class="small"
  echo "$model_id" | grep -qiE "70b|65b|72b|mixtral.*8x7" && model_class="70b"
  echo "$model_id" | grep -qiE "34b|33b|30b|40b"          && model_class="34b"
  echo "$model_id" | grep -qiE "13b|14b|15b|20b"           && model_class="13b"
  echo "$model_id" | grep -qiE "7b|8b|9b|mistral|qwen.*7|llama.*8" && model_class="7b"

  local init_delay thresh
  case "$model_class" in
    70b) init_delay=2400; thresh=300 ;;
    34b) init_delay=1200; thresh=240 ;;
    13b) init_delay=720;  thresh=210 ;;
    7b)  init_delay=480;  thresh=210 ;;
    *)   init_delay=300;  thresh=210 ;;
  esac
  # Multi-GPU: NCCL init adds ~60s per extra GPU
  (( gpu_count > 1 )) && init_delay=$(( init_delay + (gpu_count - 1) * 60 ))
  echo "${init_delay} ${thresh}"
}

# ── Derive safe k8s name from model ID ───────────────────────────────────────
_model_k8s_name() {
  echo "$1" \
    | awk -F'/' '{print $NF}' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-40
}

# ── Build extra_args YAML list from space-separated flags ────────────────────
_extra_args_yaml() {
  local raw="$1" quant="$2"
  # Append quantization flag if set
  [[ "$quant" != "none" && -n "$quant" ]] && raw="${raw} --quantization ${quant}"
  raw="${raw# }"  # strip leading space
  if [[ -z "$raw" ]]; then
    echo "[]"
    return
  fi
  local list="["
  for arg in $raw; do list+="\"${arg}\", "; done
  echo "${list%, }]"
}

# ── Build nodeSelectorTerms YAML for a model spec ────────────────────────────
# Accepts: empty (any GPU node), hostname, IP address, or label key=value pairs
# (comma-separated for multiple labels).
#
# A plain hostname or IP is resolved to kubernetes.io/hostname=<node-name>.
# The implicit nvidia.com/gpu.present=true requirement is always included.
#
# Output is appended to the values_file — caller passes the file path.
_node_selector_yaml() {
  local selector="$1"
  local values_file="$2"

  # Always require a GPU node as the baseline
  cat >> "$values_file" <<NSEOF
      nodeSelectorTerms:
        - matchExpressions:
            - key: nvidia.com/gpu.present
              operator: In
              values:
                - "true"
NSEOF

  [[ -z "$selector" ]] && return 0   # no further pinning requested

  # Resolve a bare hostname or IP to the Kubernetes node name
  local node_name=""
  if [[ "$selector" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # IP address — look up the matching node name
    node_name=$(kubectl get nodes       -o jsonpath='{range .items[*]}{.metadata.name}{"	"}{range .status.addresses[*]}{.type}{"	"}{.address}{"
"}{end}{end}'       2>/dev/null | awk -v ip="$selector" '$2=="InternalIP" && $3==ip {print $1; exit}')
    if [[ -z "$node_name" ]]; then
      warn "Could not resolve IP ${selector} to a node name — skipping node pin for this model."
      warn "Check: kubectl get nodes -o wide"
      return 0
    fi
    info "  Resolved IP ${selector} → node '${node_name}'"
    selector="kubernetes.io/hostname=${node_name}"
  elif [[ ! "$selector" == *"="* ]]; then
    # Plain hostname — treat as kubernetes.io/hostname value
    selector="kubernetes.io/hostname=${selector}"
  fi
  # selector is now one or more key=value pairs (comma-separated)
  # Each pair becomes a separate matchExpression with operator In
  IFS=',' read -ra _label_pairs <<< "$selector"
  for pair in "${_label_pairs[@]}"; do
    local key="${pair%%=*}"
    local val="${pair#*=}"
    [[ -z "$key" || -z "$val" ]] && continue
    cat >> "$values_file" <<LEOF
            - key: ${key}
              operator: In
              values:
                - "${val}"
LEOF
  done
}

install_vllm() {
  section "Step — vLLM Production Stack"

  if [[ "${INSTALL_VLLM}" != "true" ]]; then
    warn "INSTALL_VLLM=false — skipping vLLM stack."
    return
  fi
  if [[ "${INSTALL_NVIDIA}" != "true" ]]; then
    warn "vLLM requires NVIDIA GPU Operator — INSTALL_NVIDIA=false, skipping."
    return
  fi

  local gpu_nodes
  gpu_nodes=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
  if (( gpu_nodes == 0 )); then
    warn "No nodes labelled nvidia.com/gpu.present=true — vLLM pods will Pending."
  else
    info "Found ${gpu_nodes} GPU node(s)."
  fi

  # ── Resolve model list ────────────────────────────────────────────────────
  # Build from VLLM_MODELS array if present, else construct one entry from
  # legacy single-model variables for backward compatibility.
  local -a model_specs=()

  if declare -p VLLM_MODELS &>/dev/null 2>&1 && \
     [[ "${#VLLM_MODELS[@]}" -gt 0 ]]; then
    model_specs=("${VLLM_MODELS[@]}")
    info "Multi-model mode: ${#model_specs[@]} model(s) configured."
  else
    # Legacy single-model fallback
    local legacy_spec
    legacy_spec="${VLLM_MODEL:-meta-llama/Llama-3.2-1B-Instruct}"
    legacy_spec+="|${VLLM_GPU_COUNT:-1}"
    legacy_spec+="|${VLLM_DTYPE:-auto}"
    legacy_spec+="|${VLLM_MAX_MODEL_LEN:-4096}"
    legacy_spec+="|${VLLM_CPU_REQUEST:-4}"
    legacy_spec+="|${VLLM_CPU_LIMIT:-8}"
    legacy_spec+="|${VLLM_MEM_REQUEST:-16Gi}"
    legacy_spec+="|${VLLM_MEM_LIMIT:-32Gi}"
    legacy_spec+="|${VLLM_EXTRA_ARGS:-}"
    legacy_spec+="|${VLLM_STORAGE_SIZE:-50Gi}"
    legacy_spec+="|${VLLM_REUSE_PVC:-false}"
    legacy_spec+="|${VLLM_PVC_NAME:-vllm-model-cache}"
    legacy_spec+="|${VLLM_QUANTIZATION:-none}"
    legacy_spec+="|${VLLM_HF_TOKEN:-}"
    legacy_spec+="|${VLLM_NODE_SELECTOR:-}"
    model_specs=("$legacy_spec")
    info "Single-model mode (legacy config): ${VLLM_MODEL:-meta-llama/Llama-3.2-1B-Instruct}"
  fi

  kubectl create namespace "$VLLM_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # ── Validate GPU capacity ─────────────────────────────────────────────────
  local total_gpus_needed=0
  for spec in "${model_specs[@]}"; do
    _parse_model_spec "$spec"
    total_gpus_needed=$(( total_gpus_needed + _ms_gpu_count ))
  done
  local total_gpus_available
  total_gpus_available=$(kubectl get nodes -l nvidia.com/gpu.present=true \
    -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null \
    | tr ' ' '\n' | awk '{s+=$1}END{print s+0}')
  info "GPU capacity check: need ${total_gpus_needed} GPU(s), cluster has ${total_gpus_available:-unknown} allocatable."
  if [[ -n "$total_gpus_available" ]] && \
     (( total_gpus_available > 0 && total_gpus_needed > total_gpus_available )); then
    warn "Total GPU demand (${total_gpus_needed}) exceeds cluster capacity (${total_gpus_available})."
    warn "Some models may remain Pending. Consider reducing GPU counts or enabling time-slicing."
  fi

  # ── Pre-pull images on all nodes ─────────────────────────────────────────
  local vllm_image="docker.io/lmcache/vllm-openai:latest"
  local router_image="docker.io/lmcache/lmstack-router:latest"

  local pull_nodes=()
  for w in "${WORKER_IPS[@]:-}"; do [[ -n "$w" ]] && pull_nodes+=("$w"); done
  pull_nodes+=("${CONTROL_PLANE_IP}")

  local seen=() unique_nodes=()
  for n in "${pull_nodes[@]}"; do
    local dup=false
    for s in "${seen[@]:-}"; do [[ "$s" == "$n" ]] && dup=true && break; done
    $dup || { unique_nodes+=("$n"); seen+=("$n"); }
  done

  info "Pre-pulling vLLM images on ${#unique_nodes[@]} node(s)..."
  local pull_script="/tmp/vllm_prepull_$$.sh"
  cat > "$pull_script" <<PULLEOF
#!/usr/bin/env bash
set -euo pipefail
CTR=/usr/bin/ctr; NS=k8s.io
for IMG in "${vllm_image}" "${router_image}"; do
  echo "[prepull] Checking \${IMG}..."
  if \${CTR} --namespace \${NS} images check "name==\${IMG}" 2>/dev/null | grep -q "\${IMG}"; then
    echo "[prepull] \${IMG} already cached."
  else
    echo "[prepull] Pulling \${IMG}..."
    \${CTR} --namespace \${NS} images pull "\${IMG}"
    echo "[prepull] \${IMG} pulled OK."
  fi
done
PULLEOF
  chmod 700 "$pull_script"
  local pull_failed=false
  for node in "${unique_nodes[@]}"; do
    info "  Pulling on ${node}..."
    run_script_on "$node" "$pull_script" || { warn "Pull on ${node} failed."; pull_failed=true; }
  done
  rm -f "$pull_script"
  $pull_failed && warn "Some nodes had pull errors — proceeding anyway." \
               || log "Images pre-pulled on all nodes."

  # ── Build Helm values ─────────────────────────────────────────────────────
  helm repo add vllm https://vllm-project.github.io/production-stack 2>/dev/null || true
  helm repo update

  local values_file="/tmp/vllm-values-$$.yaml"

  # Use the WORST-CASE (largest) probe timing across all models so the single
  # servingEngineSpec startupProbe covers every modelSpec entry.
  local max_init_delay=300 max_thresh=210
  for spec in "${model_specs[@]}"; do
    _parse_model_spec "$spec"
    read -r _d _t <<< "$(_probe_timing "$_ms_model_id" "$_ms_gpu_count")"
    (( _d > max_init_delay )) && max_init_delay=$_d
    (( _t > max_thresh ))     && max_thresh=$_t
  done
  local engine_period=10
  local engine_budget=$(( max_init_delay + max_thresh * engine_period ))
  info "Startup probe (worst-case across ${#model_specs[@]} model(s)): ${max_init_delay}s delay + ${max_thresh}x${engine_period}s = ~$((engine_budget/60)) min"

  : > "$values_file"
  cat >> "$values_file" <<EOF
# vLLM production stack — generated by k8s_cluster_setup.sh
# Models: $(IFS=', '; echo "${model_specs[*]}" | tr '|' '/' | awk -F'/' '{print $1}' | tr '\n' ',' | sed 's/,$//')

servingEngineSpec:
  runtimeClassName: ""
  imagePullPolicy: "IfNotPresent"
  dnsPolicy: "ClusterFirst"
  # Disable Kubernetes service link injection into engine pods.
  # Without this, every Service in the namespace gets injected as env vars
  # starting with VLLM_STACK_*, which vLLM's envs.py warns about as unknown
  # VLLM_ variables. The pods still use DNS for service discovery.
  enableServiceLinks: false

  startupProbe:
    initialDelaySeconds: ${max_init_delay}
    periodSeconds: ${engine_period}
    failureThreshold: ${max_thresh}
    timeoutSeconds: 5

  livenessProbe:
    initialDelaySeconds: 0
    periodSeconds: 30
    failureThreshold: 3
    timeoutSeconds: 10

  readinessProbe:
    initialDelaySeconds: 0
    periodSeconds: 15
    failureThreshold: 3
    timeoutSeconds: 10

  modelSpec:
EOF

  # ── Emit one modelSpec entry per model ────────────────────────────────────
  local model_idx=0
  for spec in "${model_specs[@]}"; do
    _parse_model_spec "$spec"
    local k8s_name; k8s_name=$(_model_k8s_name "$_ms_model_id")
    # Append index suffix for uniqueness when multiple models share the same
    # base name (e.g. two Llama variants)
    (( model_idx > 0 )) && k8s_name="${k8s_name}-${model_idx}"
    local extra_yaml; extra_yaml=$(_extra_args_yaml "$_ms_extra" "$_ms_quant")

    local _pin_info=""
    [[ -n "$_ms_node_selector" ]] && _pin_info=" → pinned to: ${_ms_node_selector}"
    info "  Model $((model_idx+1))/${#model_specs[@]}: ${_ms_model_id} (${_ms_gpu_count} GPU, ${_ms_mem_req}${_pin_info})"

    # Validate PVC uniqueness: two models sharing the same PVC is only valid
    # when reuse_pvc=true on both (shared read-only cache).
    # Warn if two models create a PVC with the same name.
    if [[ "$_ms_reuse" != "true" ]]; then
      for other_spec in "${model_specs[@]}"; do
        [[ "$other_spec" == "$spec" ]] && continue
        _parse_model_spec "$other_spec"; local other_pvc="$_ms_pvc"
        _parse_model_spec "$spec"       # restore
        if [[ "$other_pvc" == "$_ms_pvc" ]]; then
          warn "Two models share PVC name '${_ms_pvc}' but neither sets reuse_pvc=true."
          warn "Use distinct PVC names or set reuse_pvc=true to share a cache PVC."
        fi
      done
    fi

    cat >> "$values_file" <<EOF
    - name: "${k8s_name}"
      repository: "lmcache/vllm-openai"
      tag: "latest"
      modelURL: "${_ms_model_id}"
      replicaCount: 1
      requestCPU: ${_ms_cpu_req}
      requestMemory: "${_ms_mem_req}"
      requestGPU: ${_ms_gpu_count}
      limitCPU: "${_ms_cpu_lim}"
      limitMemory: "${_ms_mem_lim}"
EOF
    [[ "$_ms_reuse" != "true" && -n "$_ms_storage" ]] && \
      echo "      pvcStorage: \"${_ms_storage}\""  >> "$values_file"
    [[ -n "$_ms_pvc" ]] && \
      echo "      existingClaim: ${_ms_pvc}"       >> "$values_file"
    [[ -n "$_ms_hf_token" ]] && \
      echo "      hf_token: \"${_ms_hf_token}\""  >> "$values_file"
    cat >> "$values_file" <<EOF
      vllmConfig:
        dtype: "${_ms_dtype}"
        maxModelLen: ${_ms_max_len}
        extraArgs: ${extra_yaml}
EOF
    # Emit nodeSelectorTerms — always includes nvidia.com/gpu.present=true,
    # plus any user-specified hostname/IP/label pin for this model
    _node_selector_yaml "${_ms_node_selector:-}" "$values_file"
    model_idx=$(( model_idx + 1 ))
  done

  # ── Router spec ──────────────────────────────────────────────────────────
  cat >> "$values_file" <<EOF

routerSpec:
  repository: "lmcache/lmstack-router"
  tag: "latest"
  imagePullPolicy: "IfNotPresent"
  enableServiceLinks: false
  startupProbe:
    initialDelaySeconds: 30
    periodSeconds: 10
    failureThreshold: 30
    timeoutSeconds: 5
  livenessProbe:
    initialDelaySeconds: 0
    periodSeconds: 30
    failureThreshold: 5
    timeoutSeconds: 10
  readinessProbe:
    initialDelaySeconds: 0
    periodSeconds: 15
    failureThreshold: 5
    timeoutSeconds: 10
  resources:
    requests:
      cpu: "1"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
EOF

  # ── Deploy ────────────────────────────────────────────────────────────────
  info "Deploying vLLM production stack (${#model_specs[@]} model(s))..."
  helm upgrade --install vllm-stack vllm/vllm-stack \
    --namespace "$VLLM_NAMESPACE" \
    --values "$values_file" \
    --timeout 5m || {
      error "Helm install/upgrade failed."
      warn "Dumping generated values for diagnosis:"
      cat "$values_file" | tee -a "$LOG_FILE" || true
      rm -f "$values_file"
      exit 1
    }
  rm -f "$values_file"

  # ── Patch router service to NodePort ─────────────────────────────────────
  info "Patching vLLM router service to NodePort ${VLLM_NODEPORT}..."
  local svc_name="" svc_wait=0
  while (( svc_wait < 30 )); do
    svc_name=$(kubectl get svc -n "$VLLM_NAMESPACE" \
      --no-headers 2>/dev/null | awk '/router/{print $1; exit}')
    [[ -n "$svc_name" ]] && break
    sleep 3; svc_wait=$(( svc_wait + 3 ))
  done
  [[ -z "$svc_name" ]] && \
    svc_name=$(kubectl get svc -n "$VLLM_NAMESPACE" --no-headers 2>/dev/null | awk 'NR==1{print $1}')

  if [[ -z "$svc_name" ]]; then
    warn "Could not find vLLM router service — patch manually."
  else
    local router_port
    router_port=$(kubectl get svc "$svc_name" -n "$VLLM_NAMESPACE" \
      -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
    kubectl patch svc "$svc_name" -n "$VLLM_NAMESPACE" \
      --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
           {\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${VLLM_NODEPORT}}]" \
      2>/dev/null || \
    kubectl patch svc "$svc_name" -n "$VLLM_NAMESPACE" \
      -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":${router_port},\"nodePort\":${VLLM_NODEPORT}}]}}" || \
      warn "NodePort patch failed — patch manually."
    log "Router '${svc_name}' → NodePort ${VLLM_NODEPORT}"
  fi

  # ── Readiness poll ────────────────────────────────────────────────────────
  local poll_max=1800 poll_interval=20 elapsed=0
  local -A engine_ready=()
  local router_ready=false

  info "Waiting for vLLM pods (up to $((poll_max/60)) min)..."
  while (( elapsed < poll_max )); do
    local router_status
    router_status=$(kubectl get pods -n "$VLLM_NAMESPACE" \
      --no-headers 2>/dev/null | awk '/router/{print $3; exit}')
    [[ "$router_status" == "Running" ]] && router_ready=true

    # Check each model engine pod (matched by k8s name prefix)
    local all_engines_ready=true
    local mid=0
    for spec in "${model_specs[@]}"; do
      _parse_model_spec "$spec"
      local kn; kn=$(_model_k8s_name "$_ms_model_id")
      (( mid > 0 )) && kn="${kn}-${mid}"
      local engine_status
      engine_status=$(kubectl get pods -n "$VLLM_NAMESPACE" \
        --no-headers 2>/dev/null | awk -v n="$kn" '$0~n && !/router/{print $3; exit}')
      case "${engine_status:-Pending}" in
        CrashLoopBackOff|ImagePullBackOff|ErrImagePull|OOMKilled|Error)
          error "Model ${_ms_model_id} engine pod: ${engine_status}"
          kubectl get events -n "$VLLM_NAMESPACE" \
            --sort-by='.lastTimestamp' 2>/dev/null | tail -10 | tee -a "$LOG_FILE" || true
          warn "Deployment left in place for diagnosis."
          return 1 ;;
      esac
      [[ "${engine_status:-}" != "Running" ]] && all_engines_ready=false
      mid=$(( mid + 1 ))
    done

    if $router_ready && $all_engines_ready; then
      log "All vLLM pods Running after ${elapsed}s."
      break
    fi

    info "  [${elapsed}s] router=${router_status:-Pending} | engines: $( \
      for s in "${model_specs[@]}"; do \
        _parse_model_spec "$s"; echo -n "${_ms_model_id##*/}="; \
        kubectl get pods -n "$VLLM_NAMESPACE" --no-headers 2>/dev/null \
          | awk -v n="$(_model_k8s_name "$_ms_model_id")" '$0~n && !/router/{print $3": "; exit}' \
          2>/dev/null || echo "?  "; \
      done)"
    sleep $poll_interval
    elapsed=$(( elapsed + poll_interval ))
  done

  $router_ready || warn "Router not Running after ${poll_max}s — check: kubectl get pods -n ${VLLM_NAMESPACE}"

  # ── Summary ───────────────────────────────────────────────────────────────
  log "vLLM deployed in namespace ${VLLM_NAMESPACE} with ${#model_specs[@]} model(s)."
  info "Router:  http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1"
  info "Models:"
  for spec in "${model_specs[@]}"; do
    _parse_model_spec "$spec"
    local _suf=""
    [[ -n "${_ms_node_selector:-}" ]] && _suf="  pinned: ${_ms_node_selector}"
    info "  ${_ms_model_id}  (${_ms_gpu_count} GPU, ${_ms_mem_req}${_suf})"
  done
  info ""
  info "List models:  curl http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1/models"
  info ""
  info "Chat example:"
  _parse_model_spec "${model_specs[0]}"
  info "  curl http://${CONTROL_PLANE_IP}:${VLLM_NODEPORT}/v1/chat/completions \\"
  info "    -H 'Content-Type: application/json' \\"
  info "    -d '{\"model\":\"${_ms_model_id}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
}
