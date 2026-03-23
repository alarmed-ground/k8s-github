#!/usr/bin/env bash
# Level 1 — All required module files exist on disk
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

REQUIRED=(
  # Installer lib
  lib/logging.sh lib/config.sh lib/helpers.sh lib/checks.sh lib/node_scripts.sh
  # Install steps
  steps/01_ssh.sh steps/02_prep.sh steps/03_nvidia.sh steps/04_k8s_bins.sh
  steps/05_init.sh steps/06_cni.sh steps/07_workers.sh steps/08_helm.sh
  steps/09_nfs.sh steps/10_monitoring.sh steps/11_gpu_operator.sh
  steps/12_gpu_timeslice.sh steps/13_dashboard.sh steps/14_vllm.sh
  steps/15_verify.sh
  # Add-ons and ops
  steps/addon_ceph.sh steps/addon_minio.sh steps/addon_ingress.sh
  steps/addon_metallb.sh steps/addon_cert_manager.sh steps/addon_harden.sh
  steps/addon_registry.sh steps/addon_argocd.sh steps/addon_loki.sh
  steps/addon_ray.sh steps/addon_mig.sh steps/addon_pss.sh
  steps/addon_dcgm_dashboard.sh steps/addon_alerting_rules.sh
  steps/preflight_nodes.sh
  steps/ops_etcd_health.sh steps/ops_os_patch.sh steps/ops_cert_monitor.sh
  steps/ops_netpol.sh steps/ops_rbac.sh steps/ops_vllm_health.sh
  steps/ops_benchmark.sh steps/ops_pvc_snapshot.sh
  steps/ops_backup.sh steps/ops_certs.sh steps/ops_upgrade.sh
  steps/ops_nodes.sh steps/ops_vllm_swap.sh steps/uninstall.sh
  # Wizard modules
  wizard/lib.sh
  wizard/sections/01_ssh.sh wizard/sections/02_nodes.sh
  wizard/sections/03_k8s.sh wizard/sections/04_nvidia.sh
  wizard/sections/05_monitoring.sh wizard/sections/06_nfs.sh
  wizard/sections/07_dashboard.sh wizard/sections/08_vllm.sh
  wizard/sections/09_namespaces.sh wizard/sections/10_addons.sh
  wizard/sections/summary.sh wizard/sections/config.sh
  wizard/sections/launch.sh
)

for f in "${REQUIRED[@]}"; do
  if [[ -f "${ROOT}/${f}" ]]; then
    echo "  PASS  ${f}"
  else
    echo "  FAIL  ${f} — MISSING"
    FAIL=$(( FAIL + 1 ))
  fi
done

(( FAIL == 0 )) || { echo "FAIL: ${FAIL} module(s) missing"; exit 1; }
