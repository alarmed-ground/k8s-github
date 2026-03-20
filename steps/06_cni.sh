#!/usr/bin/env bash
# =============================================================================
# 06_cni.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_cni() {
  section "Step — Installing CNI Plugin (${CNI_PLUGIN})"
  # KUBECONFIG exported globally after init_control_plane

  # Helper: apply a manifest URL with up to 3 retries and 10s backoff
  _kubectl_apply_url() {
    local url="$1" attempt=1
    while (( attempt <= 3 )); do
      if kubectl apply -f "$url"; then return 0; fi
      warn "kubectl apply attempt ${attempt}/3 failed — retrying in 10s..."
      sleep 10
      attempt=$(( attempt + 1 ))
    done
    error "kubectl apply failed after 3 attempts: ${url}"
    return 1
  }

  local FLANNEL_VERSION="v0.26.2"   # pinned — update deliberately

  if [[ "$CNI_PLUGIN" == "flannel" ]]; then
    _kubectl_apply_url       "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"

  elif [[ "$CNI_PLUGIN" == "calico" ]]; then
    # Apply the Calico manifest
    _kubectl_apply_url       "https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml"

    # ── Switch Calico from IPIP to VXLAN ──────────────────────────────────────
    # Calico defaults to IPIP (IP protocol 4) for cross-node pod traffic.
    # IPIP is frequently dropped by hypervisors and cloud firewalls because it
    # uses raw IP encapsulation rather than a standard UDP/TCP port.
    # VXLAN (UDP 4789) works universally — through VMs, Proxmox, cloud NAT, etc.
    # We patch both the IPPool and FelixConfiguration immediately after apply
    # before any pods start routing traffic through the tunnel.

    # Wait for Calico CRDs to be established before patching
    info "Waiting for Calico CRDs to be ready..."
    local crd_wait=0
    until kubectl get ippool default-ipv4-ippool &>/dev/null 2>&1; do
      sleep 5; crd_wait=$(( crd_wait + 5 ))
      (( crd_wait > 300 )) && { error "Calico IPPool CRD not ready after 300s"; exit 1; }
    done
    log "Calico CRDs ready after ${crd_wait}s."

    info "Switching Calico tunnel mode from IPIP to VXLAN..."
    kubectl patch felixconfiguration default \
      --type=merge \
      --patch '{"spec":{"ipipEnabled":false,"vxlanEnabled":true}}' \
      2>/dev/null || \
    kubectl create -f - <<EOF
apiVersion: projectcalico.org/v3
kind: FelixConfiguration
metadata:
  name: default
spec:
  ipipEnabled: false
  vxlanEnabled: true
EOF

    kubectl patch ippool default-ipv4-ippool \
      --type=merge \
      --patch '{"spec":{"ipipMode":"Never","vxlanMode":"Always"}}' || \
      warn "IPPool patch failed — Calico may still be initialising; VXLAN may need manual enable."

    # Restart calico-node pods to pick up the tunnel mode change
    kubectl rollout restart daemonset/calico-node -n calico-system 2>/dev/null || \
    kubectl rollout restart daemonset/calico-node -n kube-system  2>/dev/null || true

    log "Calico configured in VXLAN mode."

  else
    error "Unknown CNI plugin: ${CNI_PLUGIN}. Choose flannel or calico."
    exit 1
  fi

  log "CNI plugin ${CNI_PLUGIN} applied."

  # ── Wait for CNI pods to reach Running ───────────────────────────────────
  # The CNI DaemonSet must be Running on every node before the next step
  # (worker join) attempts to schedule pods — otherwise worker nodes join
  # but remain NotReady because their CNI is not initialised yet.
  local cni_ns cni_label
  case "$CNI_PLUGIN" in
    flannel) cni_ns="kube-flannel";  cni_label="app=flannel" ;;
    calico)  cni_ns="calico-system"; cni_label="app.kubernetes.io/name=calico-node" ;;
    *)       cni_ns="kube-system";   cni_label="" ;;
  esac

  local cni_wait_max="${CNI_WAIT_TIMEOUT:-300}" cni_interval=10 cni_elapsed=0
  info "Waiting up to ${cni_wait_max}s for ${CNI_PLUGIN} pods to be Running..."

  while (( cni_elapsed < cni_wait_max )); do
    local total_pods running_pods
    if [[ -n "$cni_label" ]]; then
      total_pods=$(kubectl get pods -n "$cni_ns" -l "$cni_label"         --no-headers 2>/dev/null | wc -l)
      running_pods=$(kubectl get pods -n "$cni_ns" -l "$cni_label"         --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')
    else
      total_pods=$(kubectl get pods -n "$cni_ns"         --no-headers 2>/dev/null | wc -l)
      running_pods=$(kubectl get pods -n "$cni_ns"         --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')
    fi

    if (( total_pods > 0 && running_pods >= total_pods )); then
      log "${CNI_PLUGIN} pods Running (${running_pods}/${total_pods}) after ${cni_elapsed}s."
      break
    fi

    # Detect hard failures early
    local failed_pods
    failed_pods=$(kubectl get pods -n "$cni_ns" ${cni_label:+-l "$cni_label"}       --no-headers 2>/dev/null |       awk '$3=="CrashLoopBackOff"||$3=="ErrImagePull"||$3=="ImagePullBackOff"{print $1}')
    if [[ -n "$failed_pods" ]]; then
      error "${CNI_PLUGIN} pod(s) in failed state: ${failed_pods}"
      kubectl describe pods -n "$cni_ns" ${cni_label:+-l "$cni_label"}         2>/dev/null | tail -20 | tee -a "$LOG_FILE" || true
      exit 1
    fi

    info "  [${cni_elapsed}s] ${CNI_PLUGIN} pods: ${running_pods:-0}/${total_pods:-0} Running"
    sleep $cni_interval
    cni_elapsed=$(( cni_elapsed + cni_interval ))
  done

  if (( cni_elapsed >= cni_wait_max )); then
    warn "${CNI_PLUGIN} pods did not all reach Running within ${cni_wait_max}s."
    warn "Current pod status:"
    kubectl get pods -n "$cni_ns" ${cni_label:+-l "$cni_label"}       --no-headers 2>/dev/null | tee -a "$LOG_FILE" || true
    warn "Continuing — worker join may fail if CNI is not ready."
  fi
}

