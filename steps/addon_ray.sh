#!/usr/bin/env bash
# =============================================================================
# addon_ray.sh — KubeRay Operator + RayCluster
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
#
# Deploys:
#   1. KubeRay operator (manages RayCluster / RayJob / RayService CRDs)
#   2. RayCluster CR  — one head pod + N worker pods
#
# The Ray head exposes:
#   • Dashboard   → NodePort RAY_DASHBOARD_NODEPORT  (default 32800)
#   • Client      → ClusterIP on port 10001  (for ray.init(address=...))
#   • GCS         → ClusterIP on port 6379
#   • Serve       → ClusterIP on port 8000  (Ray Serve HTTP)
#
# GPU workers:
#   When INSTALL_NVIDIA=true and RAY_WORKER_GPU > 0 workers request GPUs
#   and are scheduled only on nodes labelled nvidia.com/gpu.present=true.
#   Set RAY_WORKER_GPU=0 for CPU-only workers.
#
# Autoscaling:
#   When RAY_ENABLE_AUTOSCALING=true the cluster scales worker replicas
#   between RAY_MIN_WORKERS and RAY_MAX_WORKERS based on pending tasks.
#   Requires the KubeRay autoscaler sidecar (enabled automatically).
#
# vLLM integration:
#   vLLM can use Ray as its distributed execution backend.  Point vLLM at
#   the Ray cluster by adding --ray-address to VLLM_EXTRA_ARGS:
#     --ray-address=ray://ray-cluster-head-svc.<NS>:10001
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_ray() {
  section "KubeRay Operator + RayCluster"

  if [[ "${INSTALL_RAY:-false}" != "true" ]]; then
    info "INSTALL_RAY=false — skipping."
    return
  fi

  local ns="${NS_RAY:-ray}"
  local ray_ver="${RAY_VERSION:-2.9.3}"
  local ray_image="${RAY_IMAGE:-rayproject/ray:${ray_ver}-gpu}"
  local head_cpu="${RAY_HEAD_CPU:-4}"
  local head_mem="${RAY_HEAD_MEM:-8Gi}"
  local worker_replicas="${RAY_WORKER_REPLICAS:-1}"
  local worker_cpu="${RAY_WORKER_CPU:-4}"
  local worker_mem="${RAY_WORKER_MEM:-16Gi}"
  local worker_gpu="${RAY_WORKER_GPU:-0}"
  local dashboard_port="${RAY_DASHBOARD_NODEPORT:-32800}"
  local autoscaling="${RAY_ENABLE_AUTOSCALING:-false}"
  local min_workers="${RAY_MIN_WORKERS:-0}"
  local max_workers="${RAY_MAX_WORKERS:-${worker_replicas}}"

  # If GPU workers requested but NVIDIA not installed, warn and fall back to 0
  if (( worker_gpu > 0 )) && [[ "${INSTALL_NVIDIA:-false}" != "true" ]]; then
    warn "RAY_WORKER_GPU=${worker_gpu} but INSTALL_NVIDIA=false — setting GPU requests to 0."
    worker_gpu=0
  fi

  # Use CPU-only Ray image when no GPUs requested
  if (( worker_gpu == 0 )) && [[ "$ray_image" == *"-gpu"* ]]; then
    ray_image="${ray_image%-gpu}"
    info "No GPU workers configured — using CPU image: ${ray_image}"
  fi

  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  # ── Step 1: KubeRay operator via Helm ────────────────────────────────────
  info "Installing KubeRay operator (manages RayCluster CRDs)..."
  helm repo add kuberay https://ray-project.github.io/kuberay-helm/ 2>/dev/null || true
  helm repo update

  helm upgrade --install kuberay-operator kuberay/kuberay-operator \
    --namespace "$ns" \
    --set image.repository=quay.io/kuberay/operator \
    --set image.tag=v"${RAY_OPERATOR_VERSION:-1.1.1}" \
    --wait --timeout=5m || {
      error "KubeRay operator install failed."
      exit 1
    }
  log "KubeRay operator installed."

  # ── Step 2: RayCluster CR ─────────────────────────────────────────────────
  info "Deploying RayCluster (head + ${worker_replicas} worker(s), Ray ${ray_ver})..."

  # Build worker GPU resource block — only emitted when worker_gpu > 0
  local gpu_limit_block=""
  local gpu_node_selector=""
  if (( worker_gpu > 0 )); then
    gpu_limit_block="
              nvidia.com/gpu: ${worker_gpu}"
    gpu_node_selector="
          nodeSelector:
            nvidia.com/gpu.present: \"true\""
    info "  Worker GPU: ${worker_gpu} GPU(s) per pod — scheduling on GPU nodes only."
  fi

  # Build autoscaling block
  local autoscaling_block=""
  if [[ "$autoscaling" == "true" ]]; then
    autoscaling_block="
  enableInTreeAutoscaling: true
  autoscalerOptions:
    upscalingMode: Default
    idleTimeoutSeconds: 60
    imagePullPolicy: IfNotPresent
    resources:
      limits:
        cpu: \"500m\"
        memory: \"512Mi\"
      requests:
        cpu: \"500m\"
        memory: \"512Mi\""
    info "  Autoscaling: enabled (${min_workers}–${max_workers} workers)"
  fi

  kubectl apply -f - <<RAYCR
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: ray-cluster
  namespace: ${ns}
  labels:
    app.kubernetes.io/name: ray-cluster
    app.kubernetes.io/managed-by: k8s-install
spec:${autoscaling_block}

  # ── Head node ──────────────────────────────────────────────────────────────
  headGroupSpec:
    serviceType: ClusterIP
    rayStartParams:
      dashboard-host: "0.0.0.0"
      num-cpus: "${head_cpu}"
    template:
      spec:
        enableServiceLinks: false
        containers:
          - name: ray-head
            image: ${ray_image}
            imagePullPolicy: IfNotPresent
            ports:
              - containerPort: 6379   # GCS (Redis)
                name: gcs
              - containerPort: 8265   # Dashboard
                name: dashboard
              - containerPort: 10001  # Client
                name: client
              - containerPort: 8000   # Ray Serve HTTP
                name: serve
            resources:
              requests:
                cpu: "${head_cpu}"
                memory: "${head_mem}"
              limits:
                cpu: "${head_cpu}"
                memory: "${head_mem}"
            env:
              - name: RAY_DISABLE_IMPORT_WARNING
                value: "1"

  # ── Worker nodes ───────────────────────────────────────────────────────────
  workerGroupSpecs:
    - groupName: default-worker
      replicas: ${worker_replicas}
      minReplicas: ${min_workers}
      maxReplicas: ${max_workers}
      rayStartParams:
        num-cpus: "${worker_cpu}"
        num-gpus: "${worker_gpu}"
      template:
        spec:
          enableServiceLinks: false${gpu_node_selector}
          containers:
            - name: ray-worker
              image: ${ray_image}
              imagePullPolicy: IfNotPresent
              resources:
                requests:
                  cpu: "${worker_cpu}"
                  memory: "${worker_mem}"${gpu_limit_block}
                limits:
                  cpu: "${worker_cpu}"
                  memory: "${worker_mem}"${gpu_limit_block}
              env:
                - name: RAY_DISABLE_IMPORT_WARNING
                  value: "1"
RAYCR

  log "RayCluster CR applied."

  # ── Step 3: Expose dashboard via NodePort ─────────────────────────────────
  info "Patching Ray dashboard service to NodePort ${dashboard_port}..."

  # Wait for the head service to exist (operator creates it after the CR)
  local svc_wait=0
  while (( svc_wait < 60 )); do
    if kubectl get svc -n "$ns" --no-headers 2>/dev/null \
        | awk '/ray-cluster-head-svc/{found=1} END{exit !found}'; then
      break
    fi
    sleep 3; svc_wait=$(( svc_wait + 3 ))
  done

  local head_svc="ray-cluster-head-svc"
  if kubectl get svc "$head_svc" -n "$ns" &>/dev/null 2>&1; then
    # Patch the dashboard port (8265) to NodePort
    kubectl patch svc "$head_svc" -n "$ns" \
      --type=json \
      -p="[
        {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
        {\"op\":\"add\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${dashboard_port}}
      ]" 2>/dev/null || \
    kubectl patch svc "$head_svc" -n "$ns" \
      -p "{\"spec\":{\"type\":\"NodePort\"}}" 2>/dev/null || \
      warn "Dashboard NodePort patch failed — patch manually."
    log "Ray dashboard → NodePort ${dashboard_port}"
  else
    warn "Head service '${head_svc}' not found after 60s — NodePort patch skipped."
    warn "Patch manually: kubectl patch svc ${head_svc} -n ${ns} -p '{\"spec\":{\"type\":\"NodePort\"}}'"
  fi

  # ── Step 4: Wait for cluster to be ready ─────────────────────────────────
  local poll_max=300 poll_interval=10 elapsed=0
  info "Waiting for Ray cluster head pod to be Running (up to $((poll_max/60)) min)..."
  while (( elapsed < poll_max )); do
    local head_status
    head_status=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | awk '/ray-cluster-head/{print $3; exit}')
    case "${head_status:-Pending}" in
      Running)
        log "Ray head pod Running after ${elapsed}s."
        break ;;
      CrashLoopBackOff|Error|OOMKilled|ImagePullBackOff|ErrImagePull)
        error "Ray head pod entered failed state: ${head_status}"
        kubectl describe pod -n "$ns" -l ray.io/node-type=head 2>/dev/null \
          | tail -20 | tee -a "$LOG_FILE" || true
        return 1 ;;
    esac
    info "  [${elapsed}s] head=${head_status:-Pending}"
    sleep $poll_interval
    elapsed=$(( elapsed + poll_interval ))
  done

  # ── Summary ───────────────────────────────────────────────────────────────
  log "KubeRay deployed in namespace ${ns}."
  info ""
  info "Ray Dashboard:   http://${CONTROL_PLANE_IP}:${dashboard_port}"
  info "Ray Client:      ray://$(kubectl get svc "${head_svc}" -n "${ns}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<head-svc-ip>"):10001"
  info "Ray Serve HTTP:  http://$(kubectl get svc "${head_svc}" -n "${ns}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<head-svc-ip>"):8000"
  info ""
  info "Python client:"
  info "  import ray"
  info "  ray.init(address='ray://$(kubectl get svc "${head_svc}" -n "${ns}" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "<head-clusterip>"):10001')"
  info ""
  info "kubectl exec into head:"
  info "  kubectl exec -it -n ${ns} \$(kubectl get pod -n ${ns} -l ray.io/node-type=head -o name) -- bash"
  info ""
  if (( worker_gpu > 0 )); then
    info "vLLM + Ray (add to VLLM_EXTRA_ARGS in k8s_cluster.conf):"
    info "  --ray-address=ray://ray-cluster-head-svc.${ns}.svc.cluster.local:10001"
  fi
}
