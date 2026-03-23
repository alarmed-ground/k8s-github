#!/usr/bin/env bash
# =============================================================================
# addon_registry.sh — Private Container Registry
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
#
# Deployment strategy (tried in order):
#   1. twuni/docker-registry Helm chart  (original — may be unavailable)
#   2. joxit/docker-registry Helm chart  (active community fork)
#   3. Raw Kubernetes manifests using registry:2 (always works, no Helm needed)
#
# The twuni chart repo at helm.twun.io has been unreliable since the project
# was deprecated. This step tries all known sources and falls back to a
# pure-manifest deploy so the registry always gets installed.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_registry() {
  section "Private Container Registry"

  if [[ "${INSTALL_REGISTRY:-false}" != "true" ]]; then
    info "INSTALL_REGISTRY=false — skipping."
    return
  fi

  kubectl create namespace "$NS_REGISTRY" --dry-run=client -o yaml | kubectl apply -f -

  # ── Resolve StorageClass ──────────────────────────────────────────────────
  local sc=""
  [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_STORAGE_CLASS:-}" ]] && sc="$NFS_STORAGE_CLASS"
  [[ -z "$sc" ]] && sc=$(kubectl get storageclass \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' \
    2>/dev/null | awk '$2=="true"{print $1;exit}')

  # ── Generate htpasswd entry for optional auth ─────────────────────────────
  local htpasswd_entry=""
  if [[ "${REGISTRY_AUTH:-false}" == "true" ]]; then
    # openssl apr1 is universally available on Ubuntu
    local hashed_pw
    hashed_pw=$(openssl passwd -apr1 "${REGISTRY_PASSWORD}" 2>/dev/null || true)
    if [[ -n "$hashed_pw" ]]; then
      htpasswd_entry="${REGISTRY_USER}:${hashed_pw}"
    else
      warn "Could not generate htpasswd entry (openssl not available) — deploying without auth."
    fi

    if [[ -n "$htpasswd_entry" ]]; then
      kubectl create secret generic registry-htpasswd \
        --from-literal=htpasswd="${htpasswd_entry}" \
        -n "$NS_REGISTRY" \
        --dry-run=client -o yaml | kubectl apply -f -
      info "Registry auth secret created."
    fi
  fi

  # ── Try Helm chart deployment (multiple repo sources) ─────────────────────
  local helm_ok=false
  local helm_auth_args=()
  [[ "${REGISTRY_AUTH:-false}" == "true" && -n "$htpasswd_entry" ]] && \
    helm_auth_args+=(--set "secrets.htpasswd=${htpasswd_entry}")

  _try_helm_registry() {
    local repo_name="$1" repo_url="$2" chart_ref="$3"
    info "  Trying Helm chart: ${chart_ref} from ${repo_url}..."
    if helm repo add "$repo_name" "$repo_url" 2>/dev/null; then
      helm repo update 2>/dev/null || true
      if helm upgrade --install docker-registry "$chart_ref" \
          --namespace "$NS_REGISTRY" \
          --set service.type=NodePort \
          --set service.nodePort="${REGISTRY_NODEPORT}" \
          --set persistence.enabled=true \
          --set persistence.size="${REGISTRY_STORAGE_SIZE}" \
          ${sc:+--set persistence.storageClass="$sc"} \
          "${helm_auth_args[@]}" \
          --wait --timeout=5m 2>/dev/null; then
        return 0
      fi
    fi
    return 1
  }

  # Source 1: twuni (original — may work on older installs with cached repo)
  if _try_helm_registry \
      "twuni" "https://helm.twun.io" "twuni/docker-registry"; then
    helm_ok=true
    info "  Installed via twuni chart."
  fi

  # Source 2: joxit (active community maintained fork)
  if ! $helm_ok; then
    if _try_helm_registry \
        "joxit" "https://helm.joxit.dev" "joxit/docker-registry"; then
      helm_ok=true
      info "  Installed via joxit chart."
    fi
  fi

  # Source 3: phntom mirror
  if ! $helm_ok; then
    if _try_helm_registry \
        "phntom" "https://charts.phntom.io" "phntom/docker-registry"; then
      helm_ok=true
      info "  Installed via phntom chart."
    fi
  fi

  # ── Fallback: deploy directly via Kubernetes manifests ───────────────────
  # Uses the official registry:2 image — no Helm dependency at all.
  if ! $helm_ok; then
    warn "No Helm chart source succeeded — deploying registry via Kubernetes manifests."

    # PVC for registry storage
    kubectl apply -f - <<REGPVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-storage
  namespace: ${NS_REGISTRY}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: ${REGISTRY_STORAGE_SIZE}
$(  [[ -n "$sc" ]] && echo "  storageClassName: ${sc}" || true)
REGPVC

    # Build auth env/volume blocks for the Deployment
    local auth_env_block="" auth_vol_block="" auth_volmount_block=""
    if [[ "${REGISTRY_AUTH:-false}" == "true" && -n "$htpasswd_entry" ]]; then
      kubectl create configmap registry-htpasswd-cm \
        --from-literal=htpasswd="${htpasswd_entry}" \
        -n "$NS_REGISTRY" \
        --dry-run=client -o yaml | kubectl apply -f -

      auth_env_block="
          - name: REGISTRY_AUTH
            value: htpasswd
          - name: REGISTRY_AUTH_HTPASSWD_REALM
            value: Registry Realm
          - name: REGISTRY_AUTH_HTPASSWD_PATH
            value: /auth/htpasswd"
      auth_vol_block="
        - name: auth-vol
          configMap:
            name: registry-htpasswd-cm
            items:
              - key: htpasswd
                path: htpasswd"
      auth_volmount_block="
            - name: auth-vol
              mountPath: /auth
              readOnly: true"
    fi

    kubectl apply -f - <<REGDEPLOY
apiVersion: apps/v1
kind: Deployment
metadata:
  name: docker-registry
  namespace: ${NS_REGISTRY}
  labels:
    app: docker-registry
    app.kubernetes.io/managed-by: k8s-install
spec:
  replicas: 1
  selector:
    matchLabels:
      app: docker-registry
  template:
    metadata:
      labels:
        app: docker-registry
    spec:
      enableServiceLinks: false
      containers:
        - name: registry
          image: registry:2
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5000
              name: registry
          env:
            - name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY
              value: /var/lib/registry${auth_env_block}
          volumeMounts:
            - name: storage
              mountPath: /var/lib/registry${auth_volmount_block}
          readinessProbe:
            httpGet:
              path: /
              port: 5000
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /
              port: 5000
            initialDelaySeconds: 10
            periodSeconds: 30
            failureThreshold: 3
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
      volumes:
        - name: storage
          persistentVolumeClaim:
            claimName: registry-storage${auth_vol_block}
---
apiVersion: v1
kind: Service
metadata:
  name: docker-registry
  namespace: ${NS_REGISTRY}
  labels:
    app: docker-registry
spec:
  type: NodePort
  selector:
    app: docker-registry
  ports:
    - port: 5000
      targetPort: 5000
      nodePort: ${REGISTRY_NODEPORT}
      protocol: TCP
      name: registry
REGDEPLOY

    # Wait for rollout
    info "Waiting for registry pod to be Running (up to 3 min)..."
    kubectl rollout status deployment/docker-registry \
      -n "$NS_REGISTRY" --timeout=3m \
      && log "Registry pod is Running." \
      || warn "Registry not ready after 3 min — check: kubectl get pods -n ${NS_REGISTRY}"
  fi

  # ── Summary ───────────────────────────────────────────────────────────────
  log "Private registry deployed in namespace ${NS_REGISTRY}."
  info "Push:  docker push ${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}/image:tag"
  info "Pull:  docker pull ${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}/image:tag"
  if [[ "${REGISTRY_AUTH:-false}" == "true" && -n "$htpasswd_entry" ]]; then
    info "Login: docker login ${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT} -u ${REGISTRY_USER}"
  fi
  warn "Registry uses HTTP (no TLS). Configure insecure registry on each node:"
  warn ""
  warn "  Docker (/etc/docker/daemon.json):"
  warn '  {"insecure-registries": ["'"${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}"'"]}'
  warn ""
  warn "  containerd (/etc/containerd/config.toml):"
  warn "  [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}\"]"
  warn "    endpoint = [\"http://${CONTROL_PLANE_IP}:${REGISTRY_NODEPORT}\"]"
  warn "  Then: systemctl restart containerd"
}
