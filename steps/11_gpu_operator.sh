#!/usr/bin/env bash
# =============================================================================
# 11_gpu_operator.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_gpu_operator() {
  section "Step — NVIDIA GPU Operator"
  # KUBECONFIG exported globally after init_control_plane

  if [[ "${INSTALL_NVIDIA}" != "true" ]]; then
    warn "INSTALL_NVIDIA=false — skipping GPU Operator."
    return
  fi
  local has_gpu=false
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]}")
  for node in "${all_nodes[@]}"; do
    if run_on "$node" "lspci 2>/dev/null | grep -qi nvidia" 2>/dev/null; then
      has_gpu=true; break
    fi
  done

  if [[ "$has_gpu" == "false" ]]; then
    warn "No NVIDIA GPU detected on any node — skipping GPU Operator."
    return
  fi

  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
  helm repo update

  kubectl create namespace "$NS_GPU_OPERATOR" --dry-run=client -o yaml | kubectl apply -f -

  # ── Label GPU nodes ───────────────────────────────────────────────────────────
  # Do NOT use 'hostname -s' — Kubernetes registers nodes under whatever name
  # kubelet reports, which may differ from the shell hostname (FQDN vs short,
  # or a custom --node-name passed to kubeadm).  The only reliable source of
  # truth is kubectl itself: match the node's InternalIP to the IP we know.
  for node in "${WORKER_IPS[@]:-}"; do
    [[ -z "$node" ]] && continue
    if run_on "$node" "lspci 2>/dev/null | grep -qi nvidia" 2>/dev/null; then
      # Ask Kubernetes for the node name whose InternalIP matches this worker IP
      local node_name
      node_name=$(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}{end}' \
        2>/dev/null \
        | awk -v ip="$node" '$2=="InternalIP" && $3==ip {print $1; exit}')

      if [[ -z "$node_name" ]]; then
        warn "Could not find Kubernetes node name for IP ${node} — skipping GPU label."
        warn "Run: kubectl get nodes -o wide   to verify the node registered correctly."
        continue
      fi

      kubectl label node "$node_name" nvidia.com/gpu.present=true --overwrite
      info "Labeled GPU node: ${node_name} (${node})"
    fi
  done

  # ── Detect CPU ISA level for toolkit compatibility ───────────────────────
  # The NVIDIA Container Toolkit ships binaries compiled for x86-64-v3 (AVX2)
  # by default since v1.17.  Older server CPUs (Sandy/Ivy Bridge, Haswell-EP,
  # older Xeon E5 v2/v3) only support x86-64-v2 and will hit:
  #   "nvidia-toolkit: CPU ISA level is lower than required"
  # The -ubi8 image tag ships x86-64-v2 compatible binaries.
  #
  # Detection: check for avx2 in /proc/cpuinfo on the first GPU node.
  # We run this locally on the control plane if it has a GPU, otherwise
  # on the first worker with a GPU.
  local toolkit_tag=""
  local toolkit_version="${NVIDIA_TOOLKIT_VERSION:-auto}"

  if [[ "$toolkit_version" == "auto" ]]; then
    info "Detecting CPU ISA level for toolkit compatibility..."
    local isa_check_node=""
    # Prefer control plane (already running this script), then first GPU worker
    for n in "$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}"; do
      [[ -z "$n" ]] && continue
      if run_on "$n" "lspci 2>/dev/null | grep -qi nvidia" 2>/dev/null; then
        isa_check_node="$n"; break
      fi
    done

    if [[ -n "$isa_check_node" ]]; then
      if run_on "$isa_check_node"           "grep -q avx2 /proc/cpuinfo" 2>/dev/null; then
        info "  CPU supports AVX2 (x86-64-v3) — using default toolkit image."
        toolkit_tag=""   # use operator chart default
      else
        warn "  CPU does NOT support AVX2 — selecting x86-64-v2 compatible toolkit image."
        warn "  This is normal for older server CPUs (Sandy/Ivy Bridge, Haswell-EP, older Xeon E5)."
        # The -ubi8 tagged toolkit image is built without AVX2 instructions.
        # We pin to a known-good version that ships the ubi8 variant.
        # The GPU Operator chart accepts toolkit.version to override the tag.
        toolkit_tag="v1.17.3-ubi8"
        info "  Toolkit image tag: ${toolkit_tag}"
      fi
    else
      warn "No GPU node found for ISA detection — using default toolkit image."
      warn "If you see 'CPU ISA level is lower than required', set:"
      warn "  NVIDIA_TOOLKIT_VERSION=v1.17.3-ubi8  in k8s_cluster.conf"
      warn "and re-run:  sudo bash k8s_cluster_setup.sh --step gpu-op"
      toolkit_tag=""
    fi
  elif [[ "$toolkit_version" != "default" ]]; then
    # User explicitly set a version — use it directly
    toolkit_tag="$toolkit_version"
    info "Using user-specified toolkit tag: ${toolkit_tag}"
  fi

  # ── Build toolkit helm args ────────────────────────────────────────────────
  local toolkit_helm_args=""
  if [[ -n "$toolkit_tag" ]]; then
    toolkit_helm_args="--set toolkit.version=${toolkit_tag}"
    info "Overriding toolkit image tag: ${toolkit_tag}"
  fi

  helm upgrade --install gpu-operator \
    nvidia/gpu-operator \
    --namespace "$NS_GPU_OPERATOR" \
    --set driver.enabled=false \
    --set toolkit.enabled=true \
    --set devicePlugin.enabled=true \
    --set dcgmExporter.enabled=true \
    --set dcgmExporter.serviceMonitor.enabled=true \
    --set dcgmExporter.serviceMonitor.additionalLabels.release=kube-prometheus-stack \
    ${toolkit_helm_args:+${toolkit_helm_args}} \
    --wait --timeout=15m

  log "NVIDIA GPU Operator deployed in namespace ${NS_GPU_OPERATOR}."
  if [[ -n "$toolkit_tag" ]]; then
    info "Toolkit image tag used: ${toolkit_tag}"
    info "If a future toolkit version has x86-64-v2 builds, update NVIDIA_TOOLKIT_VERSION in k8s_cluster.conf."
  fi
}

