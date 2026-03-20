#!/usr/bin/env bash
# =============================================================================
# 07_workers.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

join_workers() {
  section "Step — Joining Worker Nodes"
  if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
    warn "No worker nodes defined — skipping join step."
    return
  fi

  local join_cmd
  join_cmd=$(cat /tmp/k8s_join_command.txt)

  for worker in "${WORKER_IPS[@]}"; do
    info "Joining worker ${worker}..."
    # Write join command to a script file and run via run_script_on.
    # run_on passes the command as a single shell argument — the join command
    # contains --token and --discovery-token-ca-cert-hash which risk being
    # word-split or misinterpreted by remote sudo bash -c.
    local join_script="/tmp/k8s_worker_join_$$.sh"
    printf '#!/usr/bin/env bash
set -euo pipefail
%s
' "${join_cmd}" > "$join_script"
    chmod 600 "$join_script"
    run_script_on "$worker" "$join_script" || {
      error "Worker join failed on ${worker}."
      rm -f "$join_script"
      exit 1
    }
    rm -f "$join_script"
    log "Worker ${worker} joined the cluster."
  done

  # ── Wait for all nodes (control-plane + workers) to reach Ready ──────────────
  # Expected total = 1 control plane + number of workers
  local expected_nodes=$(( 1 + ${#WORKER_IPS[@]} ))
  local wait_timeout=300   # 5 min — allows time for CNI pod scheduling
  info "Waiting for all ${expected_nodes} nodes to be Ready (timeout: ${wait_timeout}s)..."

  # kubectl wait is the correct tool — it watches the API directly.
  # --for=condition=Ready covers both control-plane and worker nodes.
  if kubectl wait node \
       --all \
       --for=condition=Ready \
       --timeout="${wait_timeout}s" \
       2>/dev/null; then
    log "All nodes are Ready."
  else
    # kubectl wait timed out or failed — fall back to a manual poll that
    # correctly distinguishes Ready from NotReady using exact field matching.
    warn "kubectl wait timed out — checking node status manually..."
    local elapsed=0
    local poll=10
    local all_ready=false
    while (( elapsed < wait_timeout )); do
      # Count nodes whose STATUS column is exactly "Ready" (not "NotReady")
      # awk field $2 is the STATUS column in 'kubectl get nodes --no-headers'
      local ready_count not_ready_count
      ready_count=$(kubectl get nodes --no-headers 2>/dev/null \
        | awk '$2 == "Ready" {count++} END {print count+0}')
      not_ready_count=$(kubectl get nodes --no-headers 2>/dev/null \
        | awk '$2 != "Ready" {count++} END {print count+0}')

      info "Nodes ready: ${ready_count}/${expected_nodes} | Not ready: ${not_ready_count}"

      if (( ready_count >= expected_nodes && not_ready_count == 0 )); then
        all_ready=true
        break
      fi
      sleep $poll
      elapsed=$(( elapsed + poll ))
    done

    if $all_ready; then
      log "All ${expected_nodes} nodes are Ready."
    else
      warn "Timed out after ${wait_timeout}s — ${ready_count}/${expected_nodes} nodes Ready. Proceeding anyway."
      warn "Run 'kubectl get nodes' to check cluster state."
    fi
  fi

  kubectl get nodes
}

