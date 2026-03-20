#!/usr/bin/env bash
# =============================================================================
# ops_nodes.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

add_node() {
  section "Add Worker Node"

  local new_ip="${ADD_NODE_IP:-}"
  if [[ -z "$new_ip" ]]; then
    echo -ne "  New worker node IP: "
    read -r new_ip </dev/tty
  fi
  [[ -z "$new_ip" ]] && { error "No IP provided."; exit 1; }

  info "Preparing new node ${new_ip}..."

  # SSH key copy
  ssh-copy-id -i "${SSH_KEY_PATH}.pub" \
    -o StrictHostKeyChecking=no \
    "${SSH_USER}@${new_ip}" 2>&1 | tee -a "$LOG_FILE" || {
      warn "ssh-copy-id returned non-zero — key may already be present."
  }

  # Node prep
  local prep_script="/tmp/node_prep_addnode_$$.sh"
  generate_node_prep_script > "$prep_script"
  chmod 600 "$prep_script"
  run_script_on "$new_ip" "$prep_script" || {
    error "Node prep failed on ${new_ip}."
    rm -f "$prep_script"
    exit 1
  }
  rm -f "$prep_script"

  # k8s binaries
  local bin_script="/tmp/k8s_binaries_addnode_$$.sh"
  generate_k8s_binaries_script "$K8S_VERSION" > "$bin_script"
  chmod 600 "$bin_script"
  run_script_on "$new_ip" "$bin_script" || {
    error "k8s binary install failed on ${new_ip}."
    rm -f "$bin_script"
    exit 1
  }
  rm -f "$bin_script"

  # Generate a fresh join token (24h TTL) and join
  info "Generating fresh join token..."
  local join_cmd
  join_cmd=$(run_on "$CONTROL_PLANE_IP" "kubeadm token create --print-join-command 2>/dev/null")

  local join_script="/tmp/k8s_addnode_join_$$.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "${join_cmd}" > "$join_script"
  chmod 600 "$join_script"
  run_script_on "$new_ip" "$join_script" || {
    error "kubeadm join failed on ${new_ip}."
    rm -f "$join_script"
    exit 1
  }
  rm -f "$join_script"

  # Wait for new node to be Ready
  info "Waiting for ${new_ip} to become Ready..."
  local attempts=0
  local node_name=""
  while (( attempts < 30 )); do
    node_name=$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}{end}' \
      2>/dev/null | awk -v ip="$new_ip" '$2=="InternalIP" && $3==ip {print $1; exit}')
    [[ -n "$node_name" ]] && break
    sleep 5; attempts=$(( attempts + 1 ))
  done

  if [[ -z "$node_name" ]]; then
    warn "Node ${new_ip} joined but not yet visible via kubectl — check manually."
  else
    kubectl wait node "$node_name" --for=condition=Ready --timeout=120s && \
      log "Node ${new_ip} (${node_name}) is Ready." || \
      warn "Node not Ready after 120s — check with: kubectl describe node ${node_name}"
  fi

  info "Remember to add ${new_ip} to WORKER_IPS in k8s_cluster.conf."
}

remove_node() {
  section "Remove Worker Node"

  local target_ip="${REMOVE_NODE_IP:-}"
  if [[ -z "$target_ip" ]]; then
    info "Current worker nodes:"
    kubectl get nodes --no-headers | grep -v control-plane || true
    echo -ne "  Worker IP to remove: "
    read -r target_ip </dev/tty
  fi
  [[ -z "$target_ip" ]] && { error "No IP provided."; exit 1; }

  local node_name
  node_name=$(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}{end}' \
    2>/dev/null | awk -v ip="$target_ip" '$2=="InternalIP" && $3==ip {print $1; exit}')

  if [[ -z "$node_name" ]]; then
    warn "Could not find node for IP ${target_ip} in the cluster."
    echo -ne "  Enter the node name manually (or Enter to abort): "
    read -r node_name </dev/tty
    [[ -z "$node_name" ]] && { info "Aborted."; exit 0; }
  fi

  warn "Will drain and delete node ${node_name} (${target_ip})."
  echo -ne "  Type 'yes' to confirm: "
  local confirm; read -r confirm </dev/tty
  [[ "$confirm" != "yes" ]] && { info "Cancelled."; exit 0; }

  info "Draining ${node_name}..."
  kubectl drain "$node_name" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --timeout=180s || warn "Drain returned non-zero — proceeding."

  info "Deleting ${node_name} from the cluster..."
  kubectl delete node "$node_name"

  info "Running kubeadm reset on ${target_ip}..."
  local reset_script="/tmp/k8s_removenode_$$.sh"
  cat > "$reset_script" <<'RESETEOF'
#!/usr/bin/env bash
set -uo pipefail
kubeadm reset --force 2>&1 || true
iptables -F && iptables -X && iptables -t nat -F && iptables -t nat -X || true
rm -rf /etc/cni /opt/cni /var/lib/cni /run/flannel 2>/dev/null || true
rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd 2>/dev/null || true
echo "[remove-node] Node reset complete."
RESETEOF
  chmod 600 "$reset_script"
  run_script_on "$target_ip" "$reset_script" || \
    warn "Reset returned non-zero on ${target_ip} — may already be partially reset."
  rm -f "$reset_script"

  log "Node ${node_name} (${target_ip}) removed."
  info "Remove ${target_ip} from WORKER_IPS in k8s_cluster.conf."
}

