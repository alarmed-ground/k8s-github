#!/usr/bin/env bash
# =============================================================================
# addon_pss.sh — Pod Security Standards enforcement
# Applies cluster-wide PSS via namespace labels and admission webhook config.
# PSS_LEVEL: privileged | baseline | restricted
# =============================================================================
# shellcheck shell=bash

configure_pod_security() {
  section "Pod Security Standards"
  if [[ "${INSTALL_PSS:-false}" != "true" ]]; then
    info "INSTALL_PSS=false — skipping Pod Security Standards."
    return
  fi

  local level="${PSS_LEVEL:-baseline}"
  local version="${PSS_VERSION:-latest}"
  info "Applying Pod Security Standards: level=${level}, version=${version}"

  # ── Exempt namespaces (system components that need elevated privileges) ────
  local exempt_namespaces=(
    kube-system kube-public kube-node-lease
    "${NS_GPU_OPERATOR:-gpu-operator}"
    "${NS_MONITORING:-monitoring}"
    "${NS_CEPH:-rook-ceph}"
    "${NS_ARGOCD:-argocd}"
  )

  # ── Configure admission controller via AdmissionConfiguration ────────────
  info "Writing AdmissionConfiguration to /etc/kubernetes/pss-config.yaml on control plane..."
  local exempt_ns_yaml=""
  for ns in "${exempt_namespaces[@]}"; do
    exempt_ns_yaml+="    - ${ns}"$'\n'
  done

  run_on "$CONTROL_PLANE_IP" "cat > /etc/kubernetes/pss-config.yaml << 'PSSEOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: \"${level}\"
        enforce-version: \"${version}\"
        audit: \"${level}\"
        audit-version: \"${version}\"
        warn: \"${level}\"
        warn-version: \"${version}\"
      exemptions:
        namespaces:
${exempt_ns_yaml}        usernames: []
        runtimeClasses: []
PSSEOF
" 2>/dev/null || {
    warn "Could not write PSS config to control plane — applying via namespace labels only."
  }

  # ── Apply PSS labels to all non-exempt namespaces ────────────────────────
  info "Labelling namespaces with PSS level '${level}'..."
  local labelled=0
  while IFS= read -r ns; do
    local exempt=false
    for ex in "${exempt_namespaces[@]}"; do
      [[ "$ns" == "$ex" ]] && exempt=true && break
    done
    $exempt && continue

    kubectl label namespace "$ns" \
      "pod-security.kubernetes.io/enforce=${level}" \
      "pod-security.kubernetes.io/enforce-version=${version}" \
      "pod-security.kubernetes.io/audit=${level}" \
      "pod-security.kubernetes.io/warn=${level}" \
      --overwrite 2>/dev/null && \
    info "  Labelled namespace: ${ns}" && \
    labelled=$(( labelled + 1 ))
  done < <(kubectl get namespaces --no-headers \
    -o custom-columns='NAME:.metadata.name' 2>/dev/null)

  log "Pod Security Standards applied: ${level} on ${labelled} namespace(s)."
  info "Exempt namespaces (privileged): ${exempt_namespaces[*]}"
  info ""
  info "Check PSS violations:"
  info "  kubectl get events -A --field-selector reason=FailedCreate | grep PodSecurity"
}
