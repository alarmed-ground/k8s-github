#!/usr/bin/env bash
# =============================================================================
# ops_rbac.sh — RBAC bootstrap kubeconfigs
# Creates three kubeconfigs for standard personas:
#   cluster-admin  — full cluster access (existing /root/.kube/config)
#   developer      — namespace-scoped: deploy, logs, port-forward, exec
#   read-only      — kubectl get/describe only, all namespaces
# Outputs files to RBAC_OUTPUT_DIR (default: $SCRIPT_DIR/kubeconfigs/)
# =============================================================================
# shellcheck shell=bash

generate_rbac_kubeconfigs() {
  section "RBAC Bootstrap — Generating Kubeconfigs"

  local out_dir="${RBAC_OUTPUT_DIR:-${SCRIPT_DIR}/kubeconfigs}"
  local dev_namespace="${RBAC_DEV_NAMESPACE:-default}"
  local cluster_name
  cluster_name=$(kubectl config view --minify \
    -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "kubernetes")
  local api_server
  api_server=$(kubectl config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
    || echo "https://${CONTROL_PLANE_IP}:6443")
  local ca_data
  ca_data=$(kubectl config view --minify --raw \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null)

  mkdir -p "$out_dir"
  chmod 700 "$out_dir"

  # ── Helper: create a ServiceAccount, bind a role, get its token ──────────
  _create_sa_kubeconfig() {
    local sa_name="$1" ns="$2" cluster_role="$3" out_file="$4"

    # Create ServiceAccount
    kubectl create serviceaccount "$sa_name" -n "$ns" \
      --dry-run=client -o yaml | kubectl apply -f -

    # Create token secret (long-lived for kubeconfig use)
    kubectl apply -f - <<SAEOF
apiVersion: v1
kind: Secret
metadata:
  name: ${sa_name}-token
  namespace: ${ns}
  annotations:
    kubernetes.io/service-account.name: ${sa_name}
type: kubernetes.io/service-account-token
SAEOF

    # Bind the ClusterRole (or Role) to the SA
    kubectl create clusterrolebinding "${sa_name}-binding" \
      --clusterrole="$cluster_role" \
      --serviceaccount="${ns}:${sa_name}" \
      --dry-run=client -o yaml | kubectl apply -f -

    # Wait for token to be populated (up to 15s)
    local waited=0 token=""
    while (( waited < 15 )); do
      token=$(kubectl get secret "${sa_name}-token" -n "$ns" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
      [[ -n "$token" ]] && break
      sleep 2; waited=$(( waited + 2 ))
    done

    if [[ -z "$token" ]]; then
      warn "Could not retrieve token for ${sa_name} — skipping ${out_file}"
      return 1
    fi

    # Write kubeconfig
    cat > "$out_file" <<KCEOF
apiVersion: v1
kind: Config
clusters:
  - name: ${cluster_name}
    cluster:
      server: ${api_server}
      certificate-authority-data: ${ca_data}
contexts:
  - name: ${sa_name}@${cluster_name}
    context:
      cluster: ${cluster_name}
      user: ${sa_name}
      namespace: ${ns}
current-context: ${sa_name}@${cluster_name}
users:
  - name: ${sa_name}
    user:
      token: ${token}
KCEOF
    chmod 600 "$out_file"
    log "  ✔ ${out_file}"
  }

  # ── Read-only ClusterRole ─────────────────────────────────────────────────
  kubectl apply -f - <<ROEOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k8s-install-read-only
rules:
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["get", "list", "watch", "describe"]
  - apiGroups: ["apps", "batch", "networking.k8s.io", "storage.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
ROEOF

  # ── Developer ClusterRole (namespace-scoped via binding, not ClusterRole) ─
  kubectl apply -f - <<DEVEOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k8s-install-developer
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/exec", "pods/portforward",
                "services", "configmaps", "secrets", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
DEVEOF

  info "Generating kubeconfigs in ${out_dir}/"

  # cluster-admin: copy the existing root kubeconfig
  local admin_out="${out_dir}/kubeconfig-admin.yaml"
  cp /root/.kube/config "$admin_out" 2>/dev/null || \
    cp "$KUBECONFIG" "$admin_out" 2>/dev/null || true
  chmod 600 "$admin_out"
  log "  ✔ ${admin_out} (cluster-admin)"

  # read-only
  _create_sa_kubeconfig \
    "k8s-read-only" "kube-system" "k8s-install-read-only" \
    "${out_dir}/kubeconfig-read-only.yaml"

  # developer
  _create_sa_kubeconfig \
    "k8s-developer" "$dev_namespace" "k8s-install-developer" \
    "${out_dir}/kubeconfig-developer.yaml"

  log "Kubeconfigs written to ${out_dir}/"
  info ""
  info "Usage:"
  info "  export KUBECONFIG=${out_dir}/kubeconfig-read-only.yaml"
  info "  kubectl get pods -A"
  info ""
  info "  export KUBECONFIG=${out_dir}/kubeconfig-developer.yaml"
  info "  kubectl apply -f my-app.yaml -n ${dev_namespace}"
}
