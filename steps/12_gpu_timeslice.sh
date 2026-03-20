#!/usr/bin/env bash
# =============================================================================
# 12_gpu_timeslice.sh — NVIDIA GPU Time-Slicing Configuration
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
#
# How GPU time-slicing works with the NVIDIA GPU Operator:
#   1. A ConfigMap is created containing the time-slicing profile
#      (resource name + replica count).
#   2. The ClusterPolicy CR is patched to point the device plugin at that
#      ConfigMap — this is a CLUSTER-SCOPED resource (no namespace flag).
#   3. Each GPU node is labelled nvidia.com/device-plugin.config=any so the
#      device plugin picks up the profile.
#   4. The device plugin DaemonSet is restarted; it re-advertises
#      count × physical_GPUs virtual GPU slots to the scheduler.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

configure_gpu_timeslicing() {
  section "GPU Time-Slicing Configuration"

  if [[ "${INSTALL_NVIDIA:-false}" != "true" ]]; then
    info "INSTALL_NVIDIA=false — skipping GPU time-slicing."
    return
  fi

  if [[ "${GPU_TIMESLICING_ENABLED:-false}" != "true" ]]; then
    info "GPU_TIMESLICING_ENABLED=false — skipping GPU time-slicing."
    info "To enable: set GPU_TIMESLICING_ENABLED=true GPU_TIMESLICE_COUNT=<n>"
    info "           in k8s_cluster.conf and re-run --step gpu-timeslice"
    return
  fi

  local count="${GPU_TIMESLICE_COUNT:-4}"
  info "Configuring GPU time-slicing: ${count} virtual GPU(s) per physical GPU."

  # ── Step 1: Wait for CUDA validation to complete ──────────────────────────
  # The GPU Operator initialises in strict order:
  #   toolkit install → CUDA validator → device plugin (re)start
  # The device plugin only begins advertising GPUs *after* the CUDA validator
  # pod completes successfully.  Applying timeslicing before that point means
  # the device plugin restarts against an operator that isn't ready, the
  # ClusterPolicy patch races with the validator, and nodes never appear with
  # the nvidia.com/gpu.present label that step 5 relies on.
  #
  # We poll until ALL of the following are true:
  #   a) ClusterPolicy is in Ready state
  #   b) Every cuda-validator pod in NS_GPU_OPERATOR has Succeeded
  #   c) At least one node has the nvidia.com/gpu.present=true label
  #      (set by the device plugin once it has confirmed GPU availability)
  #
  # Timeout: GPU_OP_READY_TIMEOUT seconds (default 900 = 15 min).
  # On a fresh node the toolkit install + CUDA workload typically takes
  # 5-10 minutes; allow generous headroom for slow disks or image pulls.

  local op_timeout="${GPU_OP_READY_TIMEOUT:-900}"
  local op_interval=15
  local op_elapsed=0
  info "Waiting for GPU Operator to complete CUDA validation (up to $((op_timeout/60)) min)..."
  info "This includes: toolkit install → CUDA validator → device plugin readiness."

  while (( op_elapsed < op_timeout )); do

    # ── a) ClusterPolicy ready? ───────────────────────────────────────────────
    local cp_state=""
    cp_state=$(kubectl get clusterpolicy       --no-headers       -o custom-columns='STATE:.status.state'       2>/dev/null | head -1 | tr -d ' ')

    # ── b) CUDA validator completed? ─────────────────────────────────────────
    # The GPU Operator runs a pod named like "nvidia-cuda-validator-<hash>"
    # in NS_GPU_OPERATOR.  We wait for every such pod to be Succeeded.
    # If none exist yet the operator hasn't created them — keep waiting.
    local cuda_total cuda_done cuda_failed
    cuda_total=$(kubectl get pods -n "${NS_GPU_OPERATOR}"       --no-headers 2>/dev/null       | awk '/cuda.validator/{count++} END{print count+0}')
    cuda_done=$(kubectl get pods -n "${NS_GPU_OPERATOR}"       --no-headers 2>/dev/null       | awk '/cuda.validator/ && $3=="Succeeded"{count++} END{print count+0}')
    cuda_failed=$(kubectl get pods -n "${NS_GPU_OPERATOR}"       --no-headers 2>/dev/null       | awk '/cuda.validator/ && ($3=="Failed"||$3=="Error"||$3=="CrashLoopBackOff"){count++} END{print count+0}')

    # ── c) At least one GPU node labelled? ────────────────────────────────────
    local gpu_nodes=0
    gpu_nodes=$(kubectl get nodes -l nvidia.com/gpu.present=true       --no-headers 2>/dev/null | wc -l)

    # ── Fail fast on validator errors ─────────────────────────────────────────
    if (( cuda_failed > 0 )); then
      error "CUDA validator pod(s) failed — cannot proceed with time-slicing."
      error "Diagnosis:"
      kubectl get pods -n "${NS_GPU_OPERATOR}" --no-headers 2>/dev/null         | awk '/cuda.validator/' | tee -a "$LOG_FILE" || true
      kubectl logs -n "${NS_GPU_OPERATOR}"         -l app=nvidia-cuda-validator --tail=30 2>/dev/null         | tee -a "$LOG_FILE" || true
      error "Resolve the driver/toolkit issue and re-run: --step gpu-timeslice"
      return 1
    fi

    # ── Check if all conditions are met ───────────────────────────────────────
    if [[ "$cp_state" == "ready" ]]     && (( cuda_total > 0 && cuda_done >= cuda_total ))     && (( gpu_nodes > 0 )); then
      log "GPU Operator ready: ClusterPolicy=${cp_state}, CUDA validators=${cuda_done}/${cuda_total} Succeeded, GPU nodes=${gpu_nodes}."
      break
    fi

    info "  [${op_elapsed}s] ClusterPolicy=${cp_state:-pending}  CUDA validators=${cuda_done}/${cuda_total} Succeeded  GPU nodes=${gpu_nodes}"
    sleep $op_interval
    op_elapsed=$(( op_elapsed + op_interval ))
  done

  # Check we actually exited due to success, not timeout
  if (( op_elapsed >= op_timeout && op_timeout > 0 )); then
    local cp_state_final
    cp_state_final=$(kubectl get clusterpolicy       --no-headers -o custom-columns='STATE:.status.state'       2>/dev/null | head -1 | tr -d ' ')
    warn "Timed out waiting for GPU Operator after ${op_timeout}s."
    warn "ClusterPolicy state: ${cp_state_final:-unknown}"
    warn "CUDA validator pods:"
    kubectl get pods -n "${NS_GPU_OPERATOR}" --no-headers 2>/dev/null       | awk '/cuda.validator/' | tee -a "$LOG_FILE" || true
    warn ""
    warn "You can re-run time-slicing once the operator is ready:"
    warn "  sudo bash $(basename "$0") --step gpu-timeslice"
    warn "Proceeding with time-slicing configuration anyway."
    warn "If this fails, re-run once the operator is ready:"
    warn "  sudo bash $(basename \"$0\") --step gpu-timeslice"
  fi

  # ── Step 8: Ensure the GPU Operator namespace exists ─────────────────────
  kubectl create namespace "${NS_GPU_OPERATOR}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # ── Step 2: Create the device-plugin ConfigMap ────────────────────────────
  # Key "any" matches the node label value nvidia.com/device-plugin.config=any.
  # The GPU Operator reads this ConfigMap and passes the config to the device
  # plugin DaemonSet on every node that carries the matching label.
  info "Creating time-slicing ConfigMap 'time-slicing-config' in ${NS_GPU_OPERATOR}..."
  kubectl apply -f - <<TSCONFIG
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: ${NS_GPU_OPERATOR}
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: false
        resources:
          - name: nvidia.com/gpu
            replicas: ${count}
TSCONFIG

  log "Time-slicing ConfigMap created (${count} replicas per GPU)."

  # ── Step 3: Discover the ClusterPolicy name ───────────────────────────────
  # ClusterPolicy is cluster-scoped — never pass -n here.
  # The GPU Operator typically creates it as "cluster-policy" but operators
  # installed via OLM or custom values may use a different name.
  info "Discovering ClusterPolicy name..."
  local cp_name=""
  cp_name=$(kubectl get clusterpolicy \
    --no-headers -o custom-columns='NAME:.metadata.name' \
    2>/dev/null | head -1)

  if [[ -z "$cp_name" ]]; then
    warn "No ClusterPolicy found. GPU Operator may not be ready yet."
    warn "Time-slicing ConfigMap was created — re-run this step once the"
    warn "GPU Operator is up:  sudo bash $(basename "$0") --step gpu-timeslice"
    return 1
  fi
  info "Found ClusterPolicy: ${cp_name}"

  # ── Step 4: Patch the ClusterPolicy to point at our ConfigMap ────────────
  # Use single-quoted JSON to avoid bash double-quote escape issues.
  # ClusterPolicy is cluster-scoped — no -n flag.
  info "Patching ClusterPolicy '${cp_name}' to use time-slicing config..."
  kubectl patch clusterpolicy "${cp_name}" \
    --type=merge \
    -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}' \
    && log "ClusterPolicy '${cp_name}' patched — device plugin will use 'time-slicing-config'." \
    || {
      warn "ClusterPolicy patch failed. Trying alternative path (GPU Operator < v23)..."
      kubectl patch clusterpolicy "${cp_name}" \
        --type=merge \
        -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config"}}}}' \
        && log "ClusterPolicy patched (alternative path)." \
        || { warn "ClusterPolicy patch failed. Re-run after GPU Operator is fully ready."; return 1; }
    }

  # ── Step 5: Label all GPU nodes to activate the time-slicing profile ─────
  # The device plugin only applies the ConfigMap profile on nodes that carry
  # the nvidia.com/device-plugin.config label matching the ConfigMap key.
  # We label every node the GPU Operator has already tagged with a GPU.
  info "Labelling GPU nodes with nvidia.com/device-plugin.config=any..."
  local labeled=0 failed_labels=0
  while IFS= read -r node_name; do
    [[ -z "$node_name" ]] && continue
    if kubectl label node "${node_name}" \
        nvidia.com/device-plugin.config=any --overwrite 2>/dev/null; then
      info "  ✔ Labelled: ${node_name}"
      labeled=$(( labeled + 1 ))
    else
      warn "  ✖ Failed to label: ${node_name}"
      failed_labels=$(( failed_labels + 1 ))
    fi
  done < <(kubectl get nodes -l nvidia.com/gpu.present=true \
    --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null)

  if (( labeled == 0 )); then
    warn "No nodes labelled nvidia.com/gpu.present=true were found."
    warn "GPU Operator may still be initialising — re-run --step gpu-timeslice"
    warn "once nodes show the label: kubectl get nodes -L nvidia.com/gpu.present"
    return 1
  fi
  log "Labelled ${labeled} GPU node(s) for time-slicing."

  # ── Step 6: Restart the device plugin DaemonSet ───────────────────────────
  # The device plugin must be restarted to re-read the ConfigMap and
  # re-advertise the new (multiplied) GPU count to the Kubernetes scheduler.
  info "Restarting NVIDIA device plugin DaemonSet in ${NS_GPU_OPERATOR}..."
  local dp_ds=""
  dp_ds=$(kubectl get daemonset -n "${NS_GPU_OPERATOR}" \
    --no-headers 2>/dev/null \
    | awk '/device.plugin/{print $1}' | head -1)

  if [[ -n "$dp_ds" ]]; then
    kubectl rollout restart "daemonset/${dp_ds}" -n "${NS_GPU_OPERATOR}"
    info "Waiting for DaemonSet '${dp_ds}' rollout to complete (up to 3 min)..."
    kubectl rollout status "daemonset/${dp_ds}" -n "${NS_GPU_OPERATOR}" \
      --timeout=180s \
      && log "Device plugin DaemonSet rollout complete." \
      || warn "Rollout did not complete within 3 min — check pod status manually."
  else
    warn "Could not find device plugin DaemonSet in ${NS_GPU_OPERATOR}."
    warn "Available DaemonSets:"
    kubectl get daemonset -n "${NS_GPU_OPERATOR}" --no-headers 2>/dev/null \
      | awk '{print "  "$1}' | tee -a "$LOG_FILE" || true
    warn "Restart the correct DaemonSet manually, then re-check GPU counts."
  fi

  # ── Step 7: Verify the virtual GPU count on each node ────────────────────
  # Allow up to 60s for the device plugin to re-register resources after restart.
  info "Waiting up to 60s for device plugin to re-register virtual GPUs..."
  local elapsed=0 total_virtual=0 nodes_ok=0
  while (( elapsed < 60 )); do
    total_virtual=0; nodes_ok=0
    while IFS= read -r line; do
      local nname vgpus
      nname=$(echo "$line" | awk '{print $1}')
      vgpus=$(echo  "$line" | awk '{print $2}')
      if (( ${vgpus:-0} >= count )); then
        total_virtual=$(( total_virtual + vgpus ))
        nodes_ok=$(( nodes_ok + 1 ))
      fi
    done < <(kubectl get nodes -l nvidia.com/gpu.present=true \
      --no-headers \
      -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu' \
      2>/dev/null)
    (( nodes_ok >= labeled )) && break
    sleep 10; elapsed=$(( elapsed + 10 ))
    info "  [${elapsed}s] waiting for virtual GPU counts to update..."
  done

  if (( total_virtual > 0 )); then
    log "GPU time-slicing is active."
    log "  ${nodes_ok} node(s) reporting ${count} virtual GPU(s) per physical GPU."
    log "  Total virtual GPUs available to scheduler: ${total_virtual}"
    info ""
    info "Verify:  kubectl get nodes -o json \\"
    info "           | jq '.items[].status.allocatable[\"nvidia.com/gpu\"]'"
    info ""
    info "Usage — request one time-slice in a pod spec:"
    info "  resources:"
    info "    limits:"
    info "      nvidia.com/gpu: 1   # gets 1/${count} of a physical GPU"
  else
    warn "Virtual GPU count not updated yet after ${elapsed}s."
    warn "The DaemonSet restart may still be in progress."
    warn "Check in a few minutes:"
    warn "  kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu'"
    warn "Expected value per physical GPU: ${count}"
  fi
}
