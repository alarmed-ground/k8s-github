#!/usr/bin/env bash
# =============================================================================
# lib/config.sh — All configuration variable defaults
# Sourced by k8s_cluster_setup.sh after the external config file is loaded.
# Variables set in k8s_cluster.conf take precedence via ${VAR:-default}.
# =============================================================================
# shellcheck shell=bash

# ── Cluster topology ──────────────────────────────────────────────────────────
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
if ! declare -p WORKER_IPS &>/dev/null 2>&1; then WORKER_IPS=(); fi

# ── SSH ───────────────────────────────────────────────────────────────────────
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/k8s_cluster_rsa}"

# ── Kubernetes ────────────────────────────────────────────────────────────────
K8S_VERSION="${K8S_VERSION:-1.31}"
CNI_PLUGIN="${CNI_PLUGIN:-flannel}"
# Auto-select pod CIDR default based on CNI plugin
if [[ "${CNI_PLUGIN}" == "calico" ]]; then
  POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
else
  POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
fi
HELM_VERSION="${HELM_VERSION:-3.16.2}"

# ── NVIDIA drivers ────────────────────────────────────────────────────────────
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-590}"
NVIDIA_OPEN_KERNEL="${NVIDIA_OPEN_KERNEL:-false}"
NVIDIA_FABRIC_MANAGER="${NVIDIA_FABRIC_MANAGER:-auto}"
NVIDIA_REBOOT_TIMEOUT="${NVIDIA_REBOOT_TIMEOUT:-300}"
# Toolkit image tag — override when the default binary is incompatible with
# the node CPU ISA level (e.g. "v1.17.3-ubi8" for x86-64-v2 CPUs without AVX2).
# "auto" detects the CPU ISA at install time and selects the right tag.
NVIDIA_TOOLKIT_VERSION="${NVIDIA_TOOLKIT_VERSION:-auto}"

# ── GPU time-slicing ──────────────────────────────────────────────────────────
GPU_TIMESLICING_ENABLED="${GPU_TIMESLICING_ENABLED:-false}"
GPU_TIMESLICE_COUNT="${GPU_TIMESLICE_COUNT:-4}"
# How long to wait for CUDA validation before applying time-slicing (seconds).
# Toolkit install + CUDA workload typically takes 5-10 min on a fresh node.
GPU_OP_READY_TIMEOUT="${GPU_OP_READY_TIMEOUT:-900}"
# Max seconds per command for preflight node checks.
# Keeps a slow or wedged node from hanging the whole preflight.
PREFLIGHT_TIMEOUT="${PREFLIGHT_TIMEOUT:-15}"

# ── Feature flags ─────────────────────────────────────────────────────────────
INSTALL_NVIDIA="${INSTALL_NVIDIA:-true}"
INSTALL_MONITORING="${INSTALL_MONITORING:-true}"
INSTALL_NFS="${INSTALL_NFS:-true}"
INSTALL_DASHBOARD="${INSTALL_DASHBOARD:-false}"
INSTALL_VLLM="${INSTALL_VLLM:-false}"
INSTALL_CEPH="${INSTALL_CEPH:-false}"
INSTALL_MINIO="${INSTALL_MINIO:-false}"
INSTALL_INGRESS="${INSTALL_INGRESS:-false}"
INSTALL_METALLB="${INSTALL_METALLB:-false}"
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-false}"
INSTALL_HARDEN="${INSTALL_HARDEN:-false}"
INSTALL_REGISTRY="${INSTALL_REGISTRY:-false}"
INSTALL_ARGOCD="${INSTALL_ARGOCD:-false}"
INSTALL_LOKI="${INSTALL_LOKI:-false}"

# ── Namespaces ────────────────────────────────────────────────────────────────
NS_MONITORING="${NS_MONITORING:-monitoring}"
NS_GPU_OPERATOR="${NS_GPU_OPERATOR:-gpu-operator}"
NS_NFS="${NS_NFS:-nfs-provisioner}"
NS_DASHBOARD="${NS_DASHBOARD:-kubernetes-dashboard}"
NS_CEPH="${NS_CEPH:-rook-ceph}"
NS_MINIO="${NS_MINIO:-minio}"
NS_INGRESS="${NS_INGRESS:-ingress-nginx}"
NS_METALLB="${NS_METALLB:-metallb-system}"
NS_CERT_MANAGER="${NS_CERT_MANAGER:-cert-manager}"
NS_REGISTRY="${NS_REGISTRY:-registry}"
NS_ARGOCD="${NS_ARGOCD:-argocd}"
NS_LOKI="${NS_LOKI:-loki}"

# ── NFS storage ───────────────────────────────────────────────────────────────
NFS_SERVER_IP="${NFS_SERVER_IP:-}"
NFS_PATH="${NFS_PATH:-/srv/nfs/k8s}"
NFS_STORAGE_CLASS="${NFS_STORAGE_CLASS:-nfs-client}"
NFS_DEFAULT_SC="${NFS_DEFAULT_SC:-true}"

# ── Monitoring (kube-prometheus-stack) ────────────────────────────────────────
PROM_STACK_VERSION="${PROM_STACK_VERSION:-65.1.0}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ChangeMe123!}"
GRAFANA_NODEPORT="${GRAFANA_NODEPORT:-32000}"
PROMETHEUS_NODEPORT="${PROMETHEUS_NODEPORT:-32001}"
ALERTMANAGER_NODEPORT="${ALERTMANAGER_NODEPORT:-32002}"
PROM_RETENTION="${PROM_RETENTION:-30d}"
PROM_STORAGE_SIZE="${PROM_STORAGE_SIZE:-20Gi}"

# ── Kubernetes Dashboard ──────────────────────────────────────────────────────
DASHBOARD_VERSION="${DASHBOARD_VERSION:-2.7.0}"
DASHBOARD_NODEPORT="${DASHBOARD_NODEPORT:-32443}"

# ── Rook-Ceph ─────────────────────────────────────────────────────────────────
CEPH_REPLICA_COUNT="${CEPH_REPLICA_COUNT:-3}"
CEPH_USE_ALL_NODES="${CEPH_USE_ALL_NODES:-true}"
CEPH_USE_ALL_DEVICES="${CEPH_USE_ALL_DEVICES:-true}"
CEPH_DEVICE_FILTER="${CEPH_DEVICE_FILTER:-}"
CEPH_DASHBOARD_NODEPORT="${CEPH_DASHBOARD_NODEPORT:-32101}"
CEPH_DEFAULT_SC="${CEPH_DEFAULT_SC:-false}"

# ── MinIO ─────────────────────────────────────────────────────────────────────
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-MinioPass123!}"
MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-50Gi}"
MINIO_NODEPORT_API="${MINIO_NODEPORT_API:-32200}"
MINIO_NODEPORT_CONSOLE="${MINIO_NODEPORT_CONSOLE:-32201}"

# ── ingress-nginx ─────────────────────────────────────────────────────────────
INGRESS_NODEPORT_HTTP="${INGRESS_NODEPORT_HTTP:-30080}"
INGRESS_NODEPORT_HTTPS="${INGRESS_NODEPORT_HTTPS:-30443}"

# ── MetalLB ───────────────────────────────────────────────────────────────────
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"

# ── cert-manager ─────────────────────────────────────────────────────────────
CERT_MANAGER_EMAIL="${CERT_MANAGER_EMAIL:-}"
CERT_MANAGER_ISSUER="${CERT_MANAGER_ISSUER:-selfsigned}"

# ── CIS hardening ─────────────────────────────────────────────────────────────
HARDEN_RUN_KUBEBENCH="${HARDEN_RUN_KUBEBENCH:-true}"

# ── Private registry ──────────────────────────────────────────────────────────
REGISTRY_NODEPORT="${REGISTRY_NODEPORT:-32500}"
REGISTRY_STORAGE_SIZE="${REGISTRY_STORAGE_SIZE:-50Gi}"
REGISTRY_AUTH="${REGISTRY_AUTH:-false}"
REGISTRY_USER="${REGISTRY_USER:-reguser}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-RegPass123!}"

# ── ArgoCD ────────────────────────────────────────────────────────────────────
ARGOCD_NODEPORT="${ARGOCD_NODEPORT:-32600}"

# ── Loki ──────────────────────────────────────────────────────────────────────
LOKI_STORAGE_SIZE="${LOKI_STORAGE_SIZE:-20Gi}"
LOKI_NODEPORT="${LOKI_NODEPORT:-32700}"

# ── Backup / restore ──────────────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR:-$(pwd)}/backups}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
BACKUP_KEEP="${BACKUP_KEEP:-5}"

# ── Certificate renewal ───────────────────────────────────────────────────────
CERT_RENEW_RESTART="${CERT_RENEW_RESTART:-true}"

# ── Cluster upgrade ───────────────────────────────────────────────────────────
K8S_UPGRADE_TO="${K8S_UPGRADE_TO:-}"

# ── Node scaling ──────────────────────────────────────────────────────────────
ADD_NODE_IP="${ADD_NODE_IP:-}"
REMOVE_NODE_IP="${REMOVE_NODE_IP:-}"

# ── vLLM ─────────────────────────────────────────────────────────────────────
VLLM_QUANTIZATION="${VLLM_QUANTIZATION:-none}"
# VLLM_MODELS: bash array of pipe-delimited model spec strings (multi-model mode).
# Format: model_id|gpu_count|dtype|max_model_len|cpu_req|cpu_lim|mem_req|mem_lim|
#         extra_args|storage_size|reuse_pvc|pvc_name|quantization|hf_token
# When empty the installer falls back to the legacy VLLM_MODEL/* single-model vars.
if ! declare -p VLLM_MODELS &>/dev/null 2>&1; then VLLM_MODELS=(); fi
VLLM_NAMESPACE="${VLLM_NAMESPACE:-vllm}"
VLLM_NODEPORT="${VLLM_NODEPORT:-32080}"
VLLM_MODEL="${VLLM_MODEL:-meta-llama/Llama-3.2-1B-Instruct}"
VLLM_HF_TOKEN="${VLLM_HF_TOKEN:-}"
VLLM_DTYPE="${VLLM_DTYPE:-auto}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-4096}"
VLLM_GPU_COUNT="${VLLM_GPU_COUNT:-1}"
VLLM_CPU_REQUEST="${VLLM_CPU_REQUEST:-4}"
VLLM_CPU_LIMIT="${VLLM_CPU_LIMIT:-8}"
VLLM_MEM_REQUEST="${VLLM_MEM_REQUEST:-16Gi}"
VLLM_MEM_LIMIT="${VLLM_MEM_LIMIT:-32Gi}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"
VLLM_STORAGE_SIZE="${VLLM_STORAGE_SIZE:-50Gi}"
VLLM_REUSE_PVC="${VLLM_REUSE_PVC:-false}"
VLLM_PVC_NAME="${VLLM_PVC_NAME:-vllm-model-cache}"
# Legacy single-model node selector (empty = any GPU node)
VLLM_NODE_SELECTOR="${VLLM_NODE_SELECTOR:-}"
# Use the KubeRay cluster as vLLM distributed execution backend.
# When true, --ray-address is injected into every model engine.
VLLM_USE_RAY="${VLLM_USE_RAY:-false}"

# ── KubeRay ───────────────────────────────────────────────────────────────────
INSTALL_RAY="${INSTALL_RAY:-false}"
NS_RAY="${NS_RAY:-ray}"
RAY_VERSION="${RAY_VERSION:-2.9.3}"
RAY_OPERATOR_VERSION="${RAY_OPERATOR_VERSION:-1.1.1}"
RAY_IMAGE="${RAY_IMAGE:-}"                 # empty = auto-select cpu/gpu image
RAY_HEAD_CPU="${RAY_HEAD_CPU:-4}"
RAY_HEAD_MEM="${RAY_HEAD_MEM:-8Gi}"
RAY_WORKER_REPLICAS="${RAY_WORKER_REPLICAS:-1}"
RAY_WORKER_CPU="${RAY_WORKER_CPU:-4}"
RAY_WORKER_MEM="${RAY_WORKER_MEM:-16Gi}"
RAY_WORKER_GPU="${RAY_WORKER_GPU:-0}"
RAY_DASHBOARD_NODEPORT="${RAY_DASHBOARD_NODEPORT:-32800}"
RAY_ENABLE_AUTOSCALING="${RAY_ENABLE_AUTOSCALING:-false}"
RAY_MIN_WORKERS="${RAY_MIN_WORKERS:-0}"
RAY_MAX_WORKERS="${RAY_MAX_WORKERS:-4}"

# ── MIG (Multi-Instance GPU) ──────────────────────────────────────────────────
INSTALL_MIG="${INSTALL_MIG:-false}"
MIG_STRATEGY="${MIG_STRATEGY:-none}"
MIG_PROFILE="${MIG_PROFILE:-1g.5gb}"

# ── Pod Security Standards ────────────────────────────────────────────────────
INSTALL_PSS="${INSTALL_PSS:-false}"
PSS_LEVEL="${PSS_LEVEL:-baseline}"
PSS_VERSION="${PSS_VERSION:-latest}"

# ── RBAC kubeconfigs ──────────────────────────────────────────────────────────
RBAC_OUTPUT_DIR="${RBAC_OUTPUT_DIR:-${SCRIPT_DIR:-$(pwd)}/kubeconfigs}"
RBAC_DEV_NAMESPACE="${RBAC_DEV_NAMESPACE:-default}"

# ── Alerting rules ────────────────────────────────────────────────────────────
INSTALL_ALERTING_RULES="${INSTALL_ALERTING_RULES:-true}"

# ── DCGM dashboard ────────────────────────────────────────────────────────────
INSTALL_DCGM_DASHBOARD="${INSTALL_DCGM_DASHBOARD:-true}"

# ── vLLM health check ─────────────────────────────────────────────────────────
VLLM_HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT:-600}"

# ── Benchmark ─────────────────────────────────────────────────────────────────
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-4}"
BENCH_REQUESTS="${BENCH_REQUESTS:-20}"
BENCH_MAX_TOKENS="${BENCH_MAX_TOKENS:-100}"

# ── PVC snapshots ─────────────────────────────────────────────────────────────
SNAPSHOT_PVC_NAME="${SNAPSHOT_PVC_NAME:-}"
SNAPSHOT_PVC_NS="${SNAPSHOT_PVC_NS:-default}"
SNAPSHOT_CLASS="${SNAPSHOT_CLASS:-}"
RESTORE_SNAPSHOT_NAME="${RESTORE_SNAPSHOT_NAME:-}"
RESTORE_PVC_NAME="${RESTORE_PVC_NAME:-}"
RESTORE_PVC_SIZE="${RESTORE_PVC_SIZE:-50Gi}"
