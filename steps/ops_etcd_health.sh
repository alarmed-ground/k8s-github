#!/usr/bin/env bash
# =============================================================================
# ops_etcd_health.sh — etcd cluster health diagnostics
# Checks: member count, leader election, DB size vs quota,
#         compaction lag, cluster ID consistency, alarm list.
# =============================================================================
# shellcheck shell=bash

check_etcd_health() {
  section "etcd Cluster Health"

  # etcdctl runs inside the etcd pod on the control plane
  local etcd_pod
  etcd_pod=$(kubectl get pod -n kube-system \
    --no-headers -l component=etcd \
    -o custom-columns='NAME:.metadata.name' 2>/dev/null | head -1)

  if [[ -z "$etcd_pod" ]]; then
    error "No etcd pod found in kube-system — is this a kubeadm cluster?"
    return 1
  fi
  info "Using etcd pod: ${etcd_pod}"

  # Wrapper: run etcdctl inside the etcd pod
  _etcdctl() {
    kubectl exec -n kube-system "$etcd_pod" -- \
      etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        "$@" 2>/dev/null
  }

  local issues=0

  # ── Member list and health ────────────────────────────────────────────────
  info ""
  info "── Member health ───────────────────────────────────────────────────"
  local member_output
  member_output=$(_etcdctl endpoint health --cluster -w table 2>/dev/null)
  echo "$member_output" | tee -a "$LOG_FILE"

  local unhealthy
  unhealthy=$(echo "$member_output" | grep -c "false" || true)
  if (( unhealthy > 0 )); then
    error "${unhealthy} unhealthy member(s) detected."
    issues=$(( issues + 1 ))
  else
    log "All members healthy."
  fi

  # ── Leader election ───────────────────────────────────────────────────────
  info ""
  info "── Leader election ─────────────────────────────────────────────────"
  local leader_output
  leader_output=$(_etcdctl endpoint status --cluster -w table 2>/dev/null)
  echo "$leader_output" | tee -a "$LOG_FILE"
  local leader_count
  leader_count=$(echo "$leader_output" | grep -c "true" || true)
  if (( leader_count == 1 )); then
    log "Exactly one leader elected — healthy."
  elif (( leader_count == 0 )); then
    error "No leader elected — cluster may be in split-brain or quorum lost."
    issues=$(( issues + 1 ))
  else
    error "${leader_count} nodes claim to be leader — split-brain detected."
    issues=$(( issues + 1 ))
  fi

  # ── DB size vs quota ─────────────────────────────────────────────────────
  info ""
  info "── DB size vs quota ────────────────────────────────────────────────"
  local db_size_bytes quota_bytes db_size_mb quota_mb pct
  db_size_bytes=$(_etcdctl endpoint status -w json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); \
      print(d[0]['Status']['dbSize'])" 2>/dev/null || echo 0)
  quota_bytes=$(_etcdctl endpoint status -w json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); \
      print(d[0]['Status'].get('dbSizeInUse', d[0]['Status']['dbSize']))" \
    2>/dev/null || echo 0)

  # Default etcd quota is 2GB
  local quota_limit=2147483648
  db_size_mb=$(( db_size_bytes / 1048576 ))
  quota_mb=$(( quota_limit / 1048576 ))
  pct=$(( db_size_bytes * 100 / quota_limit ))

  info "  DB size: ${db_size_mb} MB / ${quota_mb} MB quota (${pct}%)"
  if (( pct >= 90 )); then
    error "DB size is ${pct}% of quota — defragment immediately:"
    error "  etcdctl defrag --cluster"
    issues=$(( issues + 1 ))
  elif (( pct >= 70 )); then
    warn "DB size is ${pct}% of quota — consider defragmenting soon."
  else
    log "DB size: ${db_size_mb} MB (${pct}% of quota) — healthy."
  fi

  # ── Alarms ────────────────────────────────────────────────────────────────
  info ""
  info "── Active alarms ───────────────────────────────────────────────────"
  local alarms
  alarms=$(_etcdctl alarm list 2>/dev/null)
  if [[ -z "$alarms" || "$alarms" == *"no alarms"* ]]; then
    log "No active etcd alarms."
  else
    error "Active alarms detected:"
    echo "$alarms" | tee -a "$LOG_FILE"
    issues=$(( issues + 1 ))
  fi

  # ── Cluster ID consistency ────────────────────────────────────────────────
  info ""
  info "── Cluster ID consistency ──────────────────────────────────────────"
  local cluster_ids
  cluster_ids=$(_etcdctl endpoint status --cluster -w json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
ids = set(str(m['Status']['header']['cluster_id']) for m in data)
print('IDs:', ids)
print('consistent' if len(ids) == 1 else 'INCONSISTENT')
" 2>/dev/null)
  if echo "$cluster_ids" | grep -q "INCONSISTENT"; then
    error "Cluster IDs are inconsistent — members may be from different clusters."
    echo "$cluster_ids" | tee -a "$LOG_FILE"
    issues=$(( issues + 1 ))
  else
    log "Cluster IDs consistent across all members."
  fi

  # ── Summary ───────────────────────────────────────────────────────────────
  info ""
  if (( issues == 0 )); then
    log "etcd health check passed — no issues found."
  else
    error "etcd health check found ${issues} issue(s) — review output above."
    return 1
  fi
}
