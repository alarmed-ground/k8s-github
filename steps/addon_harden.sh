#!/usr/bin/env bash
# =============================================================================
# addon_harden.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

harden_cluster() {
  section "CIS Hardening"

  if [[ "${INSTALL_HARDEN:-false}" != "true" ]]; then
    info "INSTALL_HARDEN=false — skipping."
    return
  fi

  info "Applying CIS Kubernetes Benchmark hardening..."

  # ── 1. Disable anonymous auth on API server ────────────────────────────────
  info "Patching kube-apiserver manifest to disable anonymous auth..."
  local harden_script="/tmp/harden_$$.sh"
  cat > "$harden_script" <<'HARDENEOF'
#!/usr/bin/env bash
set -uo pipefail
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml

# Disable anonymous auth
if ! grep -q 'anonymous-auth=false' "$MANIFEST" 2>/dev/null; then
  sed -i '/- kube-apiserver/a\    - --anonymous-auth=false' "$MANIFEST" 2>/dev/null || true
  echo "[harden] anonymous-auth=false added to kube-apiserver."
fi

# Enable audit logging
AUDIT_LOG=/var/log/kubernetes/audit.log
mkdir -p /var/log/kubernetes
if ! grep -q 'audit-log-path' "$MANIFEST" 2>/dev/null; then
  sed -i "/- kube-apiserver/a\\    - --audit-log-path=${AUDIT_LOG}\n    - --audit-log-maxage=30\n    - --audit-log-maxbackup=10\n    - --audit-log-maxsize=100" \
    "$MANIFEST" 2>/dev/null || true
  echo "[harden] Audit logging enabled at ${AUDIT_LOG}."
fi

# Restrict default ServiceAccount (prevent auto-mount in default namespace)
kubectl --kubeconfig=/root/.kube/config patch serviceaccount default \
  -n default \
  -p '{"automountServiceAccountToken": false}' 2>/dev/null || true

echo "[harden] API server hardening applied."
HARDENEOF
  chmod 600 "$harden_script"
  run_script_on "$CONTROL_PLANE_IP" "$harden_script" || \
    warn "Hardening script returned non-zero — check manually."
  rm -f "$harden_script"

  # ── 2. Apply Pod Security Standards ────────────────────────────────────────
  info "Applying Pod Security Standards (warn=restricted) to default namespace..."
  kubectl label namespace default \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=latest \
    --overwrite 2>/dev/null || true

  # ── 3. Run kube-bench ──────────────────────────────────────────────────────
  if [[ "${HARDEN_RUN_KUBEBENCH:-true}" == "true" ]]; then
    info "Running kube-bench CIS benchmark (Job-based)..."
    kubectl apply -f - <<KUBEBENCH
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
  namespace: default
spec:
  template:
    spec:
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:latest
          command: ["kube-bench", "run", "--targets", "master,node", "--json"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
KUBEBENCH

    info "Waiting for kube-bench Job to complete (up to 5 min)..."
    kubectl wait job/kube-bench --for=condition=complete --timeout=300s 2>/dev/null && {
      info "kube-bench results:"
      kubectl logs job/kube-bench 2>/dev/null | \
        python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  for test in data.get('Controls',[]):
    fail = sum(r.get('status','')=='FAIL' for g in test.get('tests',[]) for r in g.get('results',[]))
    warn = sum(r.get('status','')=='WARN' for g in test.get('tests',[]) for r in g.get('results',[]))
    print(f'  {test[\"text\"]}: FAIL={fail} WARN={warn}')
except Exception:
  pass
" 2>/dev/null || kubectl logs job/kube-bench 2>/dev/null | tail -20
      kubectl delete job kube-bench 2>/dev/null || true
    } || warn "kube-bench did not complete in 5 min — check: kubectl logs job/kube-bench"
  fi

  log "CIS hardening applied."
}

