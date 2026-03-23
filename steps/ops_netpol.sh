#!/usr/bin/env bash
# =============================================================================
# ops_netpol.sh — Network Policy baseline
# Applies deny-all ingress/egress per namespace with explicit allows for:
#   • DNS (UDP/TCP 53 to kube-dns)
#   • Monitoring scrape (Prometheus → pods on /metrics)
#   • Intra-namespace traffic
#   • Kubernetes API server egress
# =============================================================================
# shellcheck shell=bash

apply_network_policies() {
  section "Network Policy Baseline"

  # Namespaces to protect (skip kube-system and kube-public — too risky to lock)
  local target_namespaces=()
  while IFS= read -r ns; do
    [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease|default)$ ]] && continue
    target_namespaces+=("$ns")
  done < <(kubectl get namespaces --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null)

  if [[ ${#target_namespaces[@]} -eq 0 ]]; then
    warn "No non-system namespaces found — nothing to protect."
    return
  fi

  info "Applying network policies to ${#target_namespaces[@]} namespace(s):"
  for ns in "${target_namespaces[@]}"; do info "  • ${ns}"; done

  local applied=0 failed=0

  for ns in "${target_namespaces[@]}"; do
    info "  Applying policies to namespace: ${ns}"

    kubectl apply -f - <<NETPOL
---
# Deny all ingress by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: ${ns}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
# Deny all egress by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: ${ns}
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
# Allow DNS resolution (UDP+TCP 53 to kube-dns)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: ${ns}
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Allow intra-namespace traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: ${ns}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
---
# Allow Prometheus scrape ingress (port 9090, 8080, 9100 common metric ports)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: ${ns}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NS_MONITORING:-monitoring}
      ports:
        - port: 9090
        - port: 8080
        - port: 9100
        - port: 8265
NETPOL
    if (( $? == 0 )); then
      log "  ✔ Network policies applied to ${ns}"
      applied=$(( applied + 1 ))
    else
      warn "  ✖ Failed to apply policies to ${ns}"
      failed=$(( failed + 1 ))
    fi
  done

  log "Network policies applied to ${applied} namespace(s)${failed:+, ${failed} failed}."
  info ""
  info "To allow specific traffic, add NetworkPolicy objects to each namespace."
  info "Example — allow HTTP ingress to a service:"
  info "  kubectl apply -f - <<EOF"
  info "  apiVersion: networking.k8s.io/v1"
  info "  kind: NetworkPolicy"
  info "  metadata: {name: allow-http, namespace: <ns>}"
  info "  spec:"
  info "    podSelector: {matchLabels: {app: <app>}}"
  info "    ingress: [{ports: [{port: 80}]}]"
  info "  EOF"
}
