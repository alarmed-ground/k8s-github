#!/usr/bin/env bash
# =============================================================================
# 15_verify.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

_verify_check_port() {
  local name="$1" port="$2" enabled="${3:-true}"
  [[ "$enabled" != "true" ]] && return
  local ok=false
  if command -v nc &>/dev/null; then
    nc -z -w3 "$CONTROL_PLANE_IP" "$port" &>/dev/null 2>&1 && ok=true || true
  else
    (echo >/dev/tcp/"$CONTROL_PLANE_IP"/"$port") &>/dev/null 2>&1 && ok=true || true
  fi
  if $ok; then
    log "  ${name} :${port} -- reachable"
  else
    warn "  ${name} :${port} -- NOT reachable (service may still be starting)"
    _verify_failed=$(( _verify_failed + 1 ))
  fi
}

verify_cluster() {
  section "Post-install Verification"
  # KUBECONFIG exported globally after init_control_plane

  _verify_failed=0

  # ── Nodes ─────────────────────────────────────────────────────────────────
  info "── Nodes ──────────────────────────────────────────────────────────────"
  kubectl get nodes -o wide | tee -a "$LOG_FILE"
  local not_ready
  not_ready=$(kubectl get nodes --no-headers 2>/dev/null     | awk '$2 != "Ready" {print $1}')
  if [[ -n "$not_ready" ]]; then
    warn "Nodes NOT Ready: ${not_ready}"
    _verify_failed=$(( _verify_failed + 1 ))
  else
    log "All nodes are Ready."
  fi

  # ── Pods ──────────────────────────────────────────────────────────────────
  info "── Pods ───────────────────────────────────────────────────────────────"
  kubectl get pods --all-namespaces | tee -a "$LOG_FILE"

  local bad_pods
  bad_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null     | awk '$4~/CrashLoopBackOff|Error|OOMKilled|ImagePullBackOff|Evicted/ {print $1"/"$2" "$4}')
  if [[ -n "$bad_pods" ]]; then
    warn "Pods in failed state:"
    while IFS= read -r p; do warn "  ${p}"; done <<< "$bad_pods"
    _verify_failed=$(( _verify_failed + 1 ))
  else
    log "No pods in failed state."
  fi

  local pending_pods
  pending_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null     | awk '$4=="Pending" {print $1"/"$2}')
  if [[ -n "$pending_pods" ]]; then
    warn "Pods still Pending (may still be starting):"
    while IFS= read -r p; do warn "  ${p}"; done <<< "$pending_pods"
  fi

  # ── CoreDNS resolution ────────────────────────────────────────────────────
  info "── DNS Resolution Test ─────────────────────────────────────────────────"
  local dns_pod="dns-verify-$$"
  if kubectl run "$dns_pod"        --image=busybox:1.36 --rm --restart=Never        --timeout=60s -i --quiet        -- nslookup kubernetes.default.svc.cluster.local        &>/dev/null 2>&1; then
    log "CoreDNS: kubernetes.default.svc.cluster.local resolves OK."
  else
    warn "CoreDNS resolution test failed or timed out."
    warn "Run: kubectl get pods -n kube-system -l k8s-app=kube-dns"
    _verify_failed=$(( _verify_failed + 1 ))
  fi
  kubectl delete pod "$dns_pod" --ignore-not-found &>/dev/null 2>&1 || true

  # ── Storage ───────────────────────────────────────────────────────────────
  info "── Storage Classes ─────────────────────────────────────────────────────"
  kubectl get storageclasses | tee -a "$LOG_FILE"

  # ── Services & NodePorts ──────────────────────────────────────────────────
  info "── NodePort / LoadBalancer Services ───────────────────────────────────"
  kubectl get svc --all-namespaces     | grep -E 'NodePort|LoadBalancer' | tee -a "$LOG_FILE"     || info "No NodePort/LoadBalancer services found."

  # ── NodePort reachability spot-checks ────────────────────────────────────
  info "── NodePort Reachability Checks ───────────────────────────────────────"
  _verify_check_port "Grafana"     "${GRAFANA_NODEPORT}"    "${INSTALL_MONITORING:-false}"
  _verify_check_port "Prometheus"  "${PROMETHEUS_NODEPORT}" "${INSTALL_MONITORING:-false}"
  _verify_check_port "Dashboard"   "${DASHBOARD_NODEPORT}"  "${INSTALL_DASHBOARD:-false}"
  _verify_check_port "vLLM Router" "${VLLM_NODEPORT}"       "${INSTALL_VLLM:-false}"

  # ── Summary ───────────────────────────────────────────────────────────────
  echo ""
  if (( _verify_failed == 0 )); then
    log "Verification passed — cluster looks healthy."
  else
    warn "Verification completed with ${_verify_failed} issue(s). Review warnings above."
    warn "Re-run a step:  sudo bash $(basename "$0") --step <step>"
  fi
}

