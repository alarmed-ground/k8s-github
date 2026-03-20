#!/usr/bin/env bash
# =============================================================================
# wizard/sections/10_addons.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_addons() {
  section_header "Add-on Components" "10/11"
  hint "Optional components installed after the core cluster is up."
  hint "All can be enabled later with --step <name>."
  echo ""

  # ── Rook-Ceph ─────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Rook-Ceph Distributed Storage${NC}"
  echo -e "  ${DIM}  Production-grade Ceph storage orchestrated by Rook.${NC}"
  echo -e "  ${DIM}  Provides RWO block (rook-ceph-block) and RWX filesystem (rook-cephfs).${NC}"
  echo -e "  ${DIM}  Requires >=3 worker nodes and at least one unformatted block device per node.${NC}"
  echo ""
  prompt_yes_no INSTALL_CEPH "Install Rook-Ceph?" "n"
  if [[ "$INSTALL_CEPH" == "true" ]]; then
    prompt_input CEPH_REPLICA_COUNT "OSD replica / pool size" "3"
    hint "useAllNodes=true: Rook will discover every node automatically."
    prompt_yes_no CEPH_USE_ALL_NODES "Use all cluster nodes for storage?" "y"
    hint "useAllDevices=true: Rook will claim every unformatted block device."
    prompt_yes_no CEPH_USE_ALL_DEVICES "Use all unformatted block devices?" "y"
    prompt_optional CEPH_DEVICE_FILTER       "Device filter regex (e.g. ^sd[b-z], blank=all)" ""
    prompt_input CEPH_DASHBOARD_NODEPORT "Ceph Dashboard NodePort" "32101"
    prompt_yes_no CEPH_DEFAULT_SC "Make rook-ceph-block the default StorageClass?" "n"
    NS_CEPH="rook-ceph"
    ok "Rook-Ceph: ${CEPH_REPLICA_COUNT} replicas, dashboard :${CEPH_DASHBOARD_NODEPORT}"
  else
    CEPH_REPLICA_COUNT="3"; CEPH_USE_ALL_NODES="true"
    CEPH_USE_ALL_DEVICES="true"; CEPH_DEVICE_FILTER=""
    CEPH_DASHBOARD_NODEPORT="32101"; CEPH_DEFAULT_SC="false"; NS_CEPH="rook-ceph"
    warn_msg "Rook-Ceph: skipped."
  fi
  echo ""

  # ── MinIO ─────────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  MinIO Object Storage (S3-compatible)${NC}"
  echo -e "  ${DIM}  Useful for etcd backups, model weight caching, artifact storage.${NC}"
  echo ""
  prompt_yes_no INSTALL_MINIO "Install MinIO?" "n"
  if [[ "$INSTALL_MINIO" == "true" ]]; then
    prompt_input MINIO_ROOT_USER     "MinIO root username"    "minioadmin"
    local pw1="" pw2=""
    while true; do
      echo -ne "  ${BOLD}MinIO root password${NC}: "; read -r -s pw1; echo ""
      echo -ne "  ${BOLD}Confirm password${NC}: ";    read -r -s pw2; echo ""
      [[ "$pw1" == "$pw2" ]] && { MINIO_ROOT_PASSWORD="$pw1"; ok "MinIO password set."; break; }
      err "Passwords do not match."
    done
    prompt_input MINIO_STORAGE_SIZE    "Storage size"           "50Gi"
    prompt_input MINIO_NODEPORT_API    "API NodePort"           "32200"
    prompt_input MINIO_NODEPORT_CONSOLE "Console NodePort"      "32201"
    NS_MINIO="minio"
    ok "MinIO: API :${MINIO_NODEPORT_API}, Console :${MINIO_NODEPORT_CONSOLE}"
  else
    MINIO_ROOT_USER="minioadmin"; MINIO_ROOT_PASSWORD="MinioPass123!"
    MINIO_STORAGE_SIZE="50Gi"; MINIO_NODEPORT_API="32200"
    MINIO_NODEPORT_CONSOLE="32201"; NS_MINIO="minio"
    warn_msg "MinIO: skipped."
  fi
  echo ""

  # ── Ingress ───────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  ingress-nginx (Layer 7 HTTP/HTTPS proxy)${NC}"
  echo -e "  ${DIM}  Routes requests by hostname/path to backend services.${NC}"
  echo ""
  prompt_yes_no INSTALL_INGRESS "Install ingress-nginx?" "n"
  if [[ "$INSTALL_INGRESS" == "true" ]]; then
    prompt_input INGRESS_NODEPORT_HTTP  "HTTP NodePort"   "30080"
    prompt_input INGRESS_NODEPORT_HTTPS "HTTPS NodePort"  "30443"
    NS_INGRESS="ingress-nginx"
    ok "ingress-nginx: HTTP :${INGRESS_NODEPORT_HTTP}, HTTPS :${INGRESS_NODEPORT_HTTPS}"
  else
    INGRESS_NODEPORT_HTTP="30080"; INGRESS_NODEPORT_HTTPS="30443"
    NS_INGRESS="ingress-nginx"
    warn_msg "ingress-nginx: skipped."
  fi
  echo ""

  # ── MetalLB ───────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  MetalLB (bare-metal LoadBalancer)${NC}"
  echo -e "  ${DIM}  Assigns real IPs to LoadBalancer-type services.${NC}"
  echo -e "  ${DIM}  Requires an IP range on your LAN not used by DHCP.${NC}"
  echo ""
  prompt_yes_no INSTALL_METALLB "Install MetalLB?" "n"
  if [[ "$INSTALL_METALLB" == "true" ]]; then
    while true; do
      prompt_input METALLB_IP_RANGE "IP range (e.g. 192.168.1.200-192.168.1.210)" ""
      [[ -n "$METALLB_IP_RANGE" ]] && ok "MetalLB pool: ${METALLB_IP_RANGE}" && break
      err "IP range is required."
    done
    NS_METALLB="metallb-system"
  else
    METALLB_IP_RANGE=""; NS_METALLB="metallb-system"
    warn_msg "MetalLB: skipped."
  fi
  echo ""

  # ── cert-manager ─────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  cert-manager (automatic TLS certificates)${NC}"
  echo -e "  ${DIM}  Integrates with ingress-nginx for automatic HTTPS.${NC}"
  echo ""
  prompt_yes_no INSTALL_CERT_MANAGER "Install cert-manager?" "n"
  if [[ "$INSTALL_CERT_MANAGER" == "true" ]]; then
    prompt_choice CERT_MANAGER_ISSUER "Certificate issuer"       "selfsigned (no email required, browser warning)"       "letsencrypt-staging (test — not trusted by browsers)"       "letsencrypt (production — requires public domain + email)"
    case "$CERT_MANAGER_ISSUER" in
      selfsigned*) CERT_MANAGER_ISSUER="selfsigned" ;;
      letsencrypt-staging*) CERT_MANAGER_ISSUER="letsencrypt-staging" ;;
      letsencrypt*) CERT_MANAGER_ISSUER="letsencrypt" ;;
    esac
    if [[ "$CERT_MANAGER_ISSUER" != "selfsigned" ]]; then
      prompt_input CERT_MANAGER_EMAIL "ACME email address" ""
    else
      CERT_MANAGER_EMAIL=""
    fi
    NS_CERT_MANAGER="cert-manager"
    ok "cert-manager: issuer=${CERT_MANAGER_ISSUER}"
  else
    CERT_MANAGER_ISSUER="selfsigned"; CERT_MANAGER_EMAIL=""
    NS_CERT_MANAGER="cert-manager"
    warn_msg "cert-manager: skipped."
  fi
  echo ""

  # ── CIS Hardening ─────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  CIS Hardening${NC}"
  echo -e "  ${DIM}  Disables anonymous auth, enables audit logging, applies Pod${NC}"
  echo -e "  ${DIM}  Security Standards, runs kube-bench CIS benchmark.${NC}"
  echo ""
  prompt_yes_no INSTALL_HARDEN "Apply CIS hardening?" "n"
  if [[ "$INSTALL_HARDEN" == "true" ]]; then
    prompt_yes_no HARDEN_RUN_KUBEBENCH "Run kube-bench after hardening?" "y"
    ok "CIS hardening enabled"
  else
    HARDEN_RUN_KUBEBENCH="true"
    warn_msg "CIS hardening: skipped."
  fi
  echo ""

  # ── Private Registry ──────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Private Container Registry (Docker Registry v2)${NC}"
  echo -e "  ${DIM}  Hosts private images, avoids Docker Hub pull limits.${NC}"
  echo ""
  prompt_yes_no INSTALL_REGISTRY "Install private registry?" "n"
  if [[ "$INSTALL_REGISTRY" == "true" ]]; then
    prompt_input REGISTRY_NODEPORT      "Registry NodePort"  "32500"
    prompt_input REGISTRY_STORAGE_SIZE  "Storage size"       "50Gi"
    prompt_yes_no REGISTRY_AUTH "Enable authentication?" "n"
    if [[ "$REGISTRY_AUTH" == "true" ]]; then
      prompt_input REGISTRY_USER "Registry username" "reguser"
      local rp1="" rp2=""
      while true; do
        echo -ne "  ${BOLD}Registry password${NC}: "; read -r -s rp1; echo ""
        echo -ne "  ${BOLD}Confirm${NC}: ";           read -r -s rp2; echo ""
        [[ "$rp1" == "$rp2" ]] && { REGISTRY_PASSWORD="$rp1"; ok "Registry password set."; break; }
        err "Passwords do not match."
      done
    else
      REGISTRY_USER="reguser"; REGISTRY_PASSWORD="RegPass123!"
    fi
    NS_REGISTRY="registry"
    ok "Registry: :${REGISTRY_NODEPORT}, auth=${REGISTRY_AUTH}"
  else
    REGISTRY_NODEPORT="32500"; REGISTRY_STORAGE_SIZE="50Gi"
    REGISTRY_AUTH="false"; REGISTRY_USER="reguser"
    REGISTRY_PASSWORD="RegPass123!"; NS_REGISTRY="registry"
    warn_msg "Private registry: skipped."
  fi
  echo ""

  # ── ArgoCD ────────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  ArgoCD GitOps${NC}"
  echo -e "  ${DIM}  Continuous delivery from a Git repository.${NC}"
  echo ""
  prompt_yes_no INSTALL_ARGOCD "Install ArgoCD?" "n"
  if [[ "$INSTALL_ARGOCD" == "true" ]]; then
    prompt_input ARGOCD_NODEPORT "ArgoCD NodePort" "32600"
    NS_ARGOCD="argocd"
    ok "ArgoCD: :${ARGOCD_NODEPORT}"
  else
    ARGOCD_NODEPORT="32600"; NS_ARGOCD="argocd"
    warn_msg "ArgoCD: skipped."
  fi
  echo ""

  # ── Loki ──────────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Loki + Promtail Log Aggregation${NC}"
  echo -e "  ${DIM}  Ships all pod logs to Loki and exposes them in Grafana.${NC}"
  echo ""
  prompt_yes_no INSTALL_LOKI "Install Loki + Promtail?" "n"
  if [[ "$INSTALL_LOKI" == "true" ]]; then
    prompt_input LOKI_STORAGE_SIZE "Log storage size" "20Gi"
    LOKI_NODEPORT="32700"; NS_LOKI="loki"
    ok "Loki: storage=${LOKI_STORAGE_SIZE}"
  else
    LOKI_STORAGE_SIZE="20Gi"; LOKI_NODEPORT="32700"; NS_LOKI="loki"
    warn_msg "Loki: skipped."
  fi
  echo ""

  # ── KubeRay ───────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  KubeRay — Ray Cluster on Kubernetes${NC}"
  echo -e "  ${DIM}  Distributed Python runtime for ML workloads (training, tuning, serving).${NC}"
  echo -e "  ${DIM}  Installs the KubeRay operator + a RayCluster (head + worker pods).${NC}"
  echo -e "  ${DIM}  GPU workers integrate with NVIDIA GPU Operator and vLLM.${NC}"
  echo ""
  prompt_yes_no INSTALL_RAY "Install KubeRay?" "n"
  if [[ "$INSTALL_RAY" == "true" ]]; then
    NS_RAY="ray"

    # Ray versions
    prompt_input RAY_VERSION          "Ray version"            "2.9.3"
    prompt_input RAY_OPERATOR_VERSION "KubeRay operator version" "1.1.1"
    echo ""

    # Head node resources (no GPU — head is control-plane only)
    echo -e "  ${BOLD}${BLUE}  Head Node Resources${NC}"
    hint "The head manages the cluster — it does not run user workloads."
    prompt_input RAY_HEAD_CPU "Head CPU cores"   "4"
    prompt_input RAY_HEAD_MEM "Head memory"      "8Gi"
    echo ""

    # Worker nodes
    echo -e "  ${BOLD}${BLUE}  Worker Configuration${NC}"
    hint "Workers run Ray tasks, actors, and model serving replicas."
    prompt_input RAY_WORKER_REPLICAS "Initial worker replicas" "1"
    prompt_input RAY_WORKER_CPU      "Worker CPU cores"        "4"
    prompt_input RAY_WORKER_MEM      "Worker memory"           "16Gi"
    echo ""

    # GPU workers
    echo -e "  ${BOLD}${BLUE}  Worker GPU Allocation${NC}"
    hint "Set to 0 for CPU-only workers. Requires NVIDIA GPU Operator."
    if [[ "$INSTALL_NVIDIA" != "true" ]]; then
      warn_msg "NVIDIA is disabled — GPU workers will not be available."
      RAY_WORKER_GPU="0"
      ok "Worker GPUs: 0 (CPU-only)"
    else
      local _ray_gpu_default="0"
      (( ${WORKER_COUNT:-0} > 0 )) && _ray_gpu_default="1"
      while true; do
        prompt_input RAY_WORKER_GPU "GPUs per worker (0 = CPU-only)" "$_ray_gpu_default"
        [[ "$RAY_WORKER_GPU" =~ ^[0-9]+$ ]] && ok "Worker GPUs: ${RAY_WORKER_GPU}" && break
        err "Must be a non-negative integer."
      done
    fi
    echo ""

    # Autoscaling
    echo -e "  ${BOLD}${BLUE}  Autoscaling${NC}"
    hint "Scales worker replicas between min and max based on pending Ray tasks."
    prompt_yes_no RAY_ENABLE_AUTOSCALING "Enable worker autoscaling?" "n"
    if [[ "$RAY_ENABLE_AUTOSCALING" == "true" ]]; then
      prompt_input RAY_MIN_WORKERS "Minimum workers" "0"
      prompt_input RAY_MAX_WORKERS "Maximum workers" "4"
      ok "Autoscaling: ${RAY_MIN_WORKERS}–${RAY_MAX_WORKERS} workers"
    else
      RAY_MIN_WORKERS="$RAY_WORKER_REPLICAS"
      RAY_MAX_WORKERS="$RAY_WORKER_REPLICAS"
      ok "Autoscaling: disabled (fixed ${RAY_WORKER_REPLICAS} worker(s))"
    fi
    echo ""

    # Dashboard NodePort
    while true; do
      prompt_input RAY_DASHBOARD_NODEPORT "Ray dashboard NodePort" "32800"
      validate_nodeport "$RAY_DASHBOARD_NODEPORT" && break
    done

    # vLLM integration hint
    if [[ "${INSTALL_VLLM:-false}" == "true" && "${RAY_WORKER_GPU:-0}" -gt 0 ]]; then
      echo ""
      hint "vLLM + Ray: to use Ray as vLLM's distributed backend, add this to"
      hint "VLLM_EXTRA_ARGS in your config after installation:"
      hint "  --ray-address=ray://ray-cluster-head-svc.${NS_RAY}.svc.cluster.local:10001"
    fi

    ok "KubeRay: Ray ${RAY_VERSION}, ${RAY_WORKER_REPLICAS} worker(s), GPU=${RAY_WORKER_GPU}, dashboard :${RAY_DASHBOARD_NODEPORT}"
  else
    NS_RAY="ray"; RAY_VERSION="2.9.3"; RAY_OPERATOR_VERSION="1.1.1"
    RAY_HEAD_CPU="4"; RAY_HEAD_MEM="8Gi"
    RAY_WORKER_REPLICAS="1"; RAY_WORKER_CPU="4"; RAY_WORKER_MEM="16Gi"
    RAY_WORKER_GPU="0"; RAY_DASHBOARD_NODEPORT="32800"
    RAY_ENABLE_AUTOSCALING="false"; RAY_MIN_WORKERS="0"; RAY_MAX_WORKERS="4"
    warn_msg "KubeRay: skipped."
  fi
  echo ""

  # ── Backup settings ───────────────────────────────────────────────────────
  echo -e "  ${BOLD}${BLUE}  Backup Settings${NC}"
  hint "Controls where etcd snapshots are stored."
  echo ""
  prompt_input BACKUP_DIR  "Local backup directory" "${SCRIPT_DIR}/backups"
  prompt_input BACKUP_KEEP "Backups to keep locally" "5"
  prompt_optional BACKUP_S3_BUCKET "S3 bucket (optional, e.g. s3://my-bucket/k8s)" ""
  ok "Backups: ${BACKUP_DIR}, keep ${BACKUP_KEEP}"
  echo ""

  show_progress
}

