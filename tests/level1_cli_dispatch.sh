#!/usr/bin/env bash
# Level 1 — Every --step key is present in the CLI dispatch block
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STEPS=(
  ssh prep nvidia k8s-bins init cni workers helm nfs monitoring
  gpu-op gpu-timeslice dashboard vllm verify
  backup restore cert-renew upgrade add-node remove-node vllm-swap
  ceph minio ingress metallb cert-manager harden registry argocd loki
  uninstall
)

DISPATCH=$(grep -E '^\s+(ssh|prep|nvidia|k8s-bins|init|cni|workers|helm|nfs|monitoring|gpu-op|gpu-timeslice|dashboard|vllm|vllm-swap|backup|restore|cert-renew|upgrade|add-node|remove-node|ceph|minio|ingress|metallb|cert-manager|harden|registry|argocd|loki|verify|uninstall)' \
  "${ROOT}/k8s_cluster_setup.sh" 2>/dev/null || true)

FAIL=0
for step in "${STEPS[@]}"; do
  if echo "$DISPATCH" | grep -q "${step}"; then
    echo "  PASS  --step ${step}"
  else
    echo "  FAIL  --step ${step} — not found in dispatch"
    FAIL=$(( FAIL + 1 ))
  fi
done

(( FAIL == 0 )) || { echo "FAIL: ${FAIL} step(s) missing from dispatch"; exit 1; }
