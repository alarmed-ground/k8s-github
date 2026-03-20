#!/usr/bin/env bash
# =============================================================================
# wizard/sections/08_vllm.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_vllm() {
  section_header "vLLM Production Stack" "8/10"
  hint "Deploys the vLLM production stack Helm chart for GPU-accelerated LLM inference."
  hint "Requires NVIDIA GPU Operator to be enabled."
  echo ""

  _vllm_defaults() {
    VLLM_NAMESPACE="vllm"; VLLM_NODEPORT="32080"
    VLLM_MODELS=()
    # Legacy single-model fallback values (used when VLLM_MODELS is empty)
    VLLM_MODEL="meta-llama/Llama-3.2-1B-Instruct"; VLLM_HF_TOKEN=""
    VLLM_DTYPE="auto"; VLLM_MAX_MODEL_LEN="4096"; VLLM_GPU_COUNT="1"
    VLLM_CPU_REQUEST="4"; VLLM_CPU_LIMIT="8"
    VLLM_MEM_REQUEST="16Gi"; VLLM_MEM_LIMIT="32Gi"
    VLLM_EXTRA_ARGS=""; VLLM_STORAGE_SIZE="50Gi"
    VLLM_REUSE_PVC="false"; VLLM_PVC_NAME="vllm-model-cache"
    VLLM_QUANTIZATION="none"
  }

  if [[ "$INSTALL_NVIDIA" != "true" ]]; then
    warn_msg "NVIDIA is disabled — vLLM requires GPU support and will be skipped."
    INSTALL_VLLM="false"; _vllm_defaults; show_progress; return
  fi

  prompt_yes_no INSTALL_VLLM "Install vLLM production stack?" "n"
  echo ""
  if [[ "$INSTALL_VLLM" != "true" ]]; then
    _vllm_defaults; warn_msg "vLLM stack will be skipped."; show_progress; return
  fi

  # Namespace & NodePort
  while true; do
    prompt_input VLLM_NAMESPACE "vLLM namespace" "vllm"
    validate_namespace "$VLLM_NAMESPACE" && ok "Namespace: ${VLLM_NAMESPACE}" && break
  done
  echo ""
  while true; do
    prompt_input VLLM_NODEPORT "vLLM router NodePort" "32080"
    validate_nodeport "$VLLM_NODEPORT" && ok "vLLM NodePort: ${VLLM_NODEPORT}" && break
  done
  echo ""

  # ── Multi-model configuration ──────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Multi-Model Configuration${NC}"
  echo -e "  ${DIM}  The vLLM router load-balances across all configured models.${NC}"
  echo -e "  ${DIM}  Each model runs as a separate engine pod with its own GPU allocation.${NC}"
  echo -e "  ${DIM}  Models can share a GPU via time-slicing or use dedicated GPUs.${NC}"
  echo ""
  hint "You can deploy one model (standard) or multiple models simultaneously."

  VLLM_MODELS=()
  local model_num=1

  while true; do
    echo ""
    echo -e "  ${BOLD}${CYAN}── Model ${model_num} ────────────────────────────────────────────${NC}"

    # ── Model selection ──────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Model Selection${NC}"
    echo -e "  ${DIM}  Common models:${NC}"
    echo -e "  ${DIM}    1) meta-llama/Llama-3.2-1B-Instruct   (1B  — ~2 GB VRAM)${NC}"
    echo -e "  ${DIM}    2) meta-llama/Llama-3.2-3B-Instruct   (3B  — ~6 GB VRAM)${NC}"
    echo -e "  ${DIM}    3) meta-llama/Llama-3.1-8B-Instruct   (8B  — ~16 GB VRAM)${NC}"
    echo -e "  ${DIM}    4) Qwen/Qwen2.5-7B-Instruct           (7B  — ~14 GB VRAM, public)${NC}"
    echo -e "  ${DIM}    5) mistralai/Mistral-7B-Instruct-v0.3 (7B  — ~14 GB VRAM)${NC}"
    echo -e "  ${DIM}    6) Custom model ID${NC}"
    echo ""
    local _m_model="" model_choice=""
    read -e -p "  ${RL_S}${BOLD}${RL_E}Model [1-6 or HF model ID]${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}[1]${RL_S}${NC}${RL_E}: " model_choice
    case "${model_choice:-1}" in
      1|"") _m_model="meta-llama/Llama-3.2-1B-Instruct" ;;
      2)    _m_model="meta-llama/Llama-3.2-3B-Instruct" ;;
      3)    _m_model="meta-llama/Llama-3.1-8B-Instruct" ;;
      4)    _m_model="Qwen/Qwen2.5-7B-Instruct" ;;
      5)    _m_model="mistralai/Mistral-7B-Instruct-v0.3" ;;
      6)    prompt_input _m_model "HuggingFace model ID" "meta-llama/Llama-3.2-1B-Instruct" ;;
      *)    _m_model="$model_choice" ;;
    esac
    ok "Model: ${_m_model}"
    echo ""

    # ── HuggingFace token ────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  HuggingFace Token${NC}"
    hint "Required for gated models (Llama, Gemma, Mistral). Leave blank for public models."
    if echo "$_m_model" | grep -qiE "llama|gemma|mistral|falcon"; then
      hint "⚠  '${_m_model}' is typically gated — a HF token is likely required."
    fi
    echo ""
    echo -ne "  ${BOLD}HuggingFace token${NC} ${DIM}(Enter to skip)${NC}: "
    local _m_hf_token=""; read -r -s _m_hf_token; echo ""
    if [[ -n "$_m_hf_token" ]]; then
      ok "HuggingFace token: set (hidden)"
    else
      warn_msg "No HF token — will fail for gated models."
    fi
    echo ""

    # ── Engine parameters ────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Engine Parameters${NC}"
    local _m_dtype="auto"
    prompt_choice _m_dtype "Tensor dtype" \
      "auto (recommended)" \
      "float16" "bfloat16" "float32"
    case "$_m_dtype" in
      auto*) _m_dtype="auto" ;; float16*) _m_dtype="float16" ;;
      bfloat16*) _m_dtype="bfloat16" ;; float32*) _m_dtype="float32" ;;
    esac
    ok "dtype: ${_m_dtype}"; echo ""

    local _m_max_len="4096"
    prompt_input _m_max_len "Max context length (tokens)" "4096"
    ok "Max context: ${_m_max_len}"; echo ""

    # ── GPU allocation ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  GPU Allocation${NC}"
    hint "Assign multiple GPUs for tensor parallelism (large models)."
    hint "Assign 1 GPU per model if using time-slicing to share across models."
    if [[ ${#VLLM_MODELS[@]} -gt 0 ]]; then
      hint "You already have ${#VLLM_MODELS[@]} model(s) configured."
      local gpus_used=0
      for _prev_spec in "${VLLM_MODELS[@]}"; do
        IFS='|' read -r _ _pg _ <<< "$_prev_spec"
        gpus_used=$(( gpus_used + ${_pg:-1} ))
      done
      hint "GPUs already allocated: ${gpus_used}"
    fi
    local _m_gpus="1"
    while true; do
      prompt_input _m_gpus "GPUs for this model" "1"
      [[ "$_m_gpus" =~ ^[1-9][0-9]*$ ]] && ok "GPUs: ${_m_gpus}" && break
      err "Must be a positive integer."
    done
    echo ""

    # ── Resource limits ──────────────────────────────────────────────────────
    local _sugg_mem_req="16Gi" _sugg_mem_lim="32Gi"
    local _sugg_cpu_req="4"   _sugg_cpu_lim="8"
    if (( _m_gpus >= 4 )); then
      _sugg_mem_req="64Gi"; _sugg_mem_lim="128Gi"
      _sugg_cpu_req="16";   _sugg_cpu_lim="32"
    elif (( _m_gpus >= 2 )); then
      _sugg_mem_req="32Gi"; _sugg_mem_lim="64Gi"
      _sugg_cpu_req="8";    _sugg_cpu_lim="16"
    fi
    # Large model memory advisory
    if echo "$_m_model" | grep -qiE "70b|65b|34b" && \
       [[ $(echo "$_sugg_mem_req" | grep -oE '[0-9]+') -lt 80 ]]; then
      hint "Large model (34–70B) — recommend ≥80Gi memory request."
      _sugg_mem_req="80Gi"; _sugg_mem_lim="160Gi"
    elif echo "$_m_model" | grep -qiE "13b|14b" && \
         [[ $(echo "$_sugg_mem_req" | grep -oE '[0-9]+') -lt 28 ]]; then
      hint "13–14B model — recommend ≥28Gi memory request."
      _sugg_mem_req="28Gi"; _sugg_mem_lim="56Gi"
    fi

    echo -e "  ${BOLD}${BLUE}  Resource Limits${NC}"
    local _m_cpu_req="$_sugg_cpu_req" _m_cpu_lim="$_sugg_cpu_lim"
    local _m_mem_req="$_sugg_mem_req" _m_mem_lim="$_sugg_mem_lim"
    prompt_input _m_cpu_req "CPU request (cores)" "$_sugg_cpu_req"
    prompt_input _m_cpu_lim "CPU limit (cores)"   "$_sugg_cpu_lim"
    prompt_input _m_mem_req "Memory request"       "$_sugg_mem_req"
    prompt_input _m_mem_lim "Memory limit"         "$_sugg_mem_lim"
    ok "Resources: CPU ${_m_cpu_req}–${_m_cpu_lim} | Mem ${_m_mem_req}–${_m_mem_lim}"; echo ""

    # ── Quantization ─────────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Quantization${NC}"
    echo -e "  ${DIM}  Reduces VRAM. AWQ/GPTQ need a pre-quantized model. BNB works on any.${NC}"
    local _m_quant="none"
    prompt_choice _m_quant "Quantization" \
      "none (full precision)" \
      "awq (pre-quantized model required)" \
      "gptq (pre-quantized model required)" \
      "bnb (bitsandbytes 4-bit — quantizes on load)"
    case "$_m_quant" in
      none*) _m_quant="none" ;; awq*) _m_quant="awq" ;;
      gptq*) _m_quant="gptq" ;; bnb*) _m_quant="bnb" ;;
    esac
    ok "Quantization: ${_m_quant}"; echo ""

    # ── Extra args ───────────────────────────────────────────────────────────
    local _m_extra=""
    echo -e "  ${BOLD}${BLUE}  Extra vLLM Arguments${NC}"
    hint "Additional engine flags. Quantization is handled above."
    prompt_optional _m_extra "Extra args" ""
    [[ -n "$_m_extra" ]] && ok "Extra args: ${_m_extra}" || ok "No extra args."; echo ""

    # ── Model cache PVC ──────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Model Cache Storage${NC}"
    hint "Each model needs a PVC to cache downloaded weights."
    hint "Models can share a PVC (read-only cache) — use the same PVC name and set reuse=true."
    local _m_reuse="false" _m_pvc="vllm-model-cache-${model_num}" _m_storage="50Gi"
    echo ""

    # Offer to share cache with a previously configured model
    if [[ ${#VLLM_MODELS[@]} -gt 0 ]]; then
      hint "Previously configured models and their PVCs:"
      local _pi=1
      for _prev_spec in "${VLLM_MODELS[@]}"; do
        IFS='|' read -r _pm _ _ _ _ _ _ _ _ _ps _pr _pp _ _ <<< "$_prev_spec"
        hint "  ${_pi}) ${_pm} → PVC: ${_pp} (reuse=${_pr}, size=${_ps:-new})"
        _pi=$(( _pi + 1 ))
      done
      echo ""
    fi

    prompt_yes_no _m_reuse "Reuse an existing PVC (shared cache)?" "n"
    if [[ "$_m_reuse" == "true" ]]; then
      prompt_input _m_pvc "Existing PVC name" "vllm-model-cache"
      _m_storage=""
      ok "Will reuse PVC: ${_m_pvc}"
    else
      local default_pvc="vllm-model-cache"
      (( model_num > 1 )) && default_pvc="vllm-model-cache-${model_num}"
      prompt_input _m_pvc "PVC name to create" "$default_pvc"
      prompt_input _m_storage "Storage size" "50Gi"
      ok "Will create PVC ${_m_pvc} (${_m_storage})"
    fi
    echo ""

    # ── Node placement ───────────────────────────────────────────────────────
    echo -e "  ${BOLD}${BLUE}  Node Placement${NC}"
    echo -e "  ${DIM}  Pin this model's engine pod to a specific node.${NC}"
    echo -e "  ${DIM}  Useful when nodes have different GPU types or VRAM sizes.${NC}"
    echo ""
    echo -e "  ${DIM}  Accepted formats:${NC}"
    echo -e "  ${DIM}    hostname     e.g.  gpu-worker-01${NC}"
    echo -e "  ${DIM}    IP address   e.g.  192.168.1.50${NC}"
    echo -e "  ${DIM}    label        e.g.  gpu-type=a100${NC}"
    echo -e "  ${DIM}    multi-label  e.g.  gpu-type=h100,zone=dc1${NC}"
    echo -e "  ${DIM}    (Leave blank to schedule on any GPU node)${NC}"

    # Show available GPU nodes to help the user choose
    local _gpu_nodes=""
    if command -v kubectl &>/dev/null 2>&1; then
      _gpu_nodes=$(kubectl get nodes -l nvidia.com/gpu.present=true         --no-headers         -o custom-columns='NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address,GPU:.status.allocatable.nvidia\.com/gpu'         2>/dev/null || true)
    fi
    if [[ -n "$_gpu_nodes" ]]; then
      echo ""
      echo -e "  ${DIM}  GPU nodes currently in the cluster:${NC}"
      while IFS= read -r line; do
        echo -e "  ${DIM}    ${line}${NC}"
      done <<< "$_gpu_nodes"
    fi
    echo ""

    local _m_node_selector=""
    prompt_optional _m_node_selector "Node hostname, IP, or label" ""

    if [[ -n "$_m_node_selector" ]]; then
      # Validate label format if it contains '='
      if [[ "$_m_node_selector" == *"="* ]]; then
        local _valid=true
        IFS=',' read -ra _pairs <<< "$_m_node_selector"
        for _pair in "${_pairs[@]}"; do
          if [[ ! "$_pair" =~ ^[a-zA-Z0-9._/-]+=[a-zA-Z0-9._/-]+$ ]]; then
            warn_msg "Label '${_pair}' looks invalid — expected key=value format."
            _valid=false
          fi
        done
        $_valid && ok "Node pin: ${_m_node_selector}"                 || warn_msg "Saved anyway — double-check label format before deploying."
      else
        ok "Node pin: ${_m_node_selector}"
      fi
    else
      ok "No node pin — schedules on any GPU node."
    fi
    echo ""

    # ── Save this model spec ─────────────────────────────────────────────────
    local _this_spec="${_m_model}|${_m_gpus}|${_m_dtype}|${_m_max_len}"
    _this_spec+="|${_m_cpu_req}|${_m_cpu_lim}|${_m_mem_req}|${_m_mem_lim}"
    _this_spec+="|${_m_extra}|${_m_storage}|${_m_reuse}|${_m_pvc}"
    _this_spec+="|${_m_quant}|${_m_hf_token}|${_m_node_selector}"
    VLLM_MODELS+=("$_this_spec")

    ok "Model ${model_num} saved: ${_m_model} (${_m_gpus} GPU)"
    echo ""

    # ── Add another model? ───────────────────────────────────────────────────
    echo -e "  ${BOLD}${CYAN}  Configured models so far:${NC}"
    local _si=1
    for _sm in "${VLLM_MODELS[@]}"; do
      IFS='|' read -r _smid _sgpu _ _ _ _ _smemr _ _ _ _ _spvc _ _ _snodesel <<< "$_sm"
      local _snode_str=""
      [[ -n "${_snodesel:-}" ]] && _snode_str=", node: ${_snodesel}"
      echo -e "  ${DIM}    ${_si}) ${_smid}  (${_sgpu} GPU, ${_smemr}, PVC: ${_spvc}${_snode_str})${NC}"
      _si=$(( _si + 1 ))
    done
    echo ""

    local _add_another="n"
    prompt_yes_no _add_another "Add another model?" "n"
    [[ "$_add_another" == "true" ]] || break
    model_num=$(( model_num + 1 ))
  done

  # Update legacy single-model vars from first model for backward compat
  if [[ ${#VLLM_MODELS[@]} -gt 0 ]]; then
    IFS='|' read -r VLLM_MODEL VLLM_GPU_COUNT VLLM_DTYPE VLLM_MAX_MODEL_LEN \
      VLLM_CPU_REQUEST VLLM_CPU_LIMIT VLLM_MEM_REQUEST VLLM_MEM_LIMIT \
      VLLM_EXTRA_ARGS VLLM_STORAGE_SIZE VLLM_REUSE_PVC VLLM_PVC_NAME \
      VLLM_QUANTIZATION VLLM_HF_TOKEN \
      <<< "${VLLM_MODELS[0]}"
  fi

  echo ""
  ok "vLLM: ${#VLLM_MODELS[@]} model(s) configured, namespace ${VLLM_NAMESPACE}, NodePort ${VLLM_NODEPORT}"
  show_progress
}

