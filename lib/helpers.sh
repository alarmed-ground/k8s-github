#!/usr/bin/env bash
# =============================================================================
# helpers.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

# Populated by _build_local_ip_cache() — declared here so set -u
# never fires on an unset reference in is_local_node().
_LOCAL_IPS=""

ensure_sudo_pass() {
  # Already have it — nothing to do
  [[ -n "${SUDO_PASS:-}" ]] && return 0

  # Check if ALL nodes already accept passwordless sudo
  local all_nodes=("$CONTROL_PLANE_IP" "${WORKER_IPS[@]:-}")
  local needs_pass=false
  for node in "${all_nodes[@]:-}"; do
    [[ -z "$node" ]] && continue
    # Local node — we already have root via sudo; no SSH probe needed
    if is_local_node "$node"; then continue; fi
    if ! ssh -i "$SSH_KEY_PATH" \
             -o StrictHostKeyChecking=no \
             -o ConnectTimeout=10 \
             -o BatchMode=yes \
             "${SSH_USER}@${node}" \
             "sudo -n true" 2>/dev/null; then
      needs_pass=true
      break
    fi
  done

  if $needs_pass; then
    info "One or more nodes require a sudo password for user '${SSH_USER}'."
    info "Enter it once — it will be reused for all nodes this session."
    # Read from the local terminal (/dev/tty) even when stdin is redirected
    local pw=""
    if [[ -t 0 ]]; then
      read -r -s -p "  [sudo] Password for ${SSH_USER}: " pw; echo ""
    else
      read -r -s pw < /dev/tty; echo ""
    fi
    export SUDO_PASS="$pw"
    info "sudo password cached for this session."
  else
    info "All nodes accept passwordless sudo — no password needed."
    export SUDO_PASS=""
  fi
}

ssh_exec() {
  local host="$1"; shift
  ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o BatchMode=yes \
      -o ServerAliveInterval=30 \
      -o ServerAliveCountMax=60 \
      "${SSH_USER}@${host}" "$@"
}

_sudo_prefix() {
  if [[ -z "${SUDO_PASS:-}" ]]; then
    # Try non-interactive first; caller wraps the command with this prefix
    echo "sudo -n"
  else
    # Pipe password via stdin; -S reads one line from stdin as the password.
    # printf is used instead of echo to avoid a trailing newline issue on some shells.
    printf "printf '%%s\\n' %q | sudo -S" "$SUDO_PASS"
  fi
}

ssh_sudo() {
  local host="$1"; shift
  local cmd="$*"

  # ── Try 1: NOPASSWD sudo ──────────────────────────────────────────────────
  if ssh_exec "$host" "sudo -n bash -c $(printf '%q' "$cmd")" 2>/dev/null; then
    return 0
  fi

  # ── Try 2: password via stdin (-S) ────────────────────────────────────────
  if [[ -n "${SUDO_PASS:-}" ]]; then
    # printf writes "<password>\n" to sudo's stdin; -S reads exactly one line
    if ssh_exec "$host" \
         "printf '%s\n' $(printf '%q' "$SUDO_PASS") | sudo -S bash -c $(printf '%q' "$cmd")" \
         2>&1 | grep -v "^\[sudo\]"; then
      return 0
    fi
  fi

  # ── Try 3: prompt interactively (only works if local tty is a terminal) ───
  warn "[${host}] Falling back to interactive sudo — you may be prompted."
  ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -t \
      "${SSH_USER}@${host}" "sudo bash -c $(printf '%q' "$cmd")"
}

scp_and_run() {
  local host="$1"
  local local_script="$2"

  # Unique IDs — PID + epoch avoids collisions on concurrent runs
  local uid="$$_$(date +%s)"
  local remote_payload="/tmp/k8s_payload_${uid}.sh"
  local remote_wrapper="/tmp/k8s_wrapper_${uid}.sh"
  local local_wrapper="/tmp/k8s_wrapper_local_${uid}.sh"

  # ── 1. Ensure payload is mode 600 before upload ───────────────────────────
  # root can always read 600 files via sudo; SSH_USER owns the file after SCP.
  chmod 600 "$local_script"

  info "[${host}] Uploading $(basename "$local_script")..."
  if ! scp -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=15 \
            "$local_script" \
            "${SSH_USER}@${host}:${remote_payload}" 2>&1 | tee -a "$LOG_FILE"; then
    error "[${host}] SCP upload failed for $(basename "$local_script")"
    return 1
  fi

  # ── 2. Write wrapper script locally ───────────────────────────────────────
  if [[ -z "${SUDO_PASS:-}" ]]; then
    cat > "$local_wrapper" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
chmod 600 ${remote_payload}
sudo -n bash ${remote_payload}
_RC=\$?
rm -f ${remote_payload} ${remote_wrapper}
exit \$_RC
WRAPPER
  else
    local escaped_pw
    escaped_pw=$(printf '%q' "$SUDO_PASS")
    cat > "$local_wrapper" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
chmod 600 ${remote_payload}
printf '%s\n' ${escaped_pw} | sudo -S bash ${remote_payload} 2>/dev/null
_RC=\${PIPESTATUS[1]}
rm -f ${remote_payload} ${remote_wrapper}
exit \$_RC
WRAPPER
  fi
  # Mode 700: SSH_USER can execute the wrapper without sudo
  chmod 700 "$local_wrapper"

  # ── 3. Upload wrapper ──────────────────────────────────────────────────────
  if ! scp -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=15 \
            "$local_wrapper" \
            "${SSH_USER}@${host}:${remote_wrapper}" 2>&1 | tee -a "$LOG_FILE"; then
    error "[${host}] SCP upload failed for wrapper"
    ssh_exec "$host" "rm -f ${remote_payload}" 2>/dev/null || true
    rm -f "$local_wrapper"
    return 1
  fi
  rm -f "$local_wrapper"

  # ── 4. Execute — single clean one-liner, zero quoting issues ──────────────
  info "[${host}] Executing $(basename "$local_script") as root..."
  if ! ssh_exec "$host" "bash ${remote_wrapper}" 2>&1 | tee -a "$LOG_FILE"; then
    error "[${host}] Remote execution failed: $(basename "$local_script")"
    ssh_exec "$host" "rm -f ${remote_payload} ${remote_wrapper}" 2>/dev/null || true
    return 1
  fi

  log "[${host}] $(basename "$local_script") completed successfully."
}

_build_local_ip_cache() {
  [[ -n "${_LOCAL_IPS:-}" ]] && return 0   # already built
  _LOCAL_IPS="127.0.0.1 localhost"
  # ip addr — primary source
  while IFS= read -r addr; do
    if [[ -n "$addr" ]]; then
      _LOCAL_IPS="$_LOCAL_IPS $addr"
    fi
  done < <(ip -4 addr show 2>/dev/null \
    | awk '/inet / {split($2,a,"/"); print a[1]}')
  # hostname -I — fallback / additional addresses
  while IFS= read -r addr; do
    if [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      _LOCAL_IPS="$_LOCAL_IPS $addr"
    fi
  done < <(hostname -I 2>/dev/null | tr ' ' '\n')
  return 0  # always succeed — never let set -e kill the script here
}

# Build the cache immediately at source time so _LOCAL_IPS is always populated
# before any code can reference it. The || true prevents set -e from aborting
# if something unexpected happens (e.g. ip/hostname not available).
_build_local_ip_cache || true

is_local_node() {
  local host="${1// /}"   # strip any accidental whitespace from the argument

  # Resolve hostname → IP if not already a dotted-quad
  local resolved="$host"
  if ! [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}' || echo "$host")
  fi

  # Walk every local IP token — word-split is intentional here
  local lip
  for lip in $_LOCAL_IPS; do
    if [[ "$resolved" == "$lip" || "$host" == "$lip" ]]; then
      return 0   # this host is the local machine
    fi
  done
  return 1
}

run_on() {
  local host="$1"; shift
  local cmd="$*"

  if is_local_node "$host"; then
    # ── Local: elevate with sudo ─────────────────────────────────────────────
    if [[ -z "${SUDO_PASS:-}" ]]; then
      sudo -n bash -c "$cmd"
    else
      printf '%s\n' "$SUDO_PASS" | sudo -S bash -c "$cmd" 2>/dev/null
    fi
  else
    # ── Remote: run as root via sudo over SSH — never opens a tty ────────────
    # kubeadm join, hostname changes, and similar commands all require root.
    # Use the same NOPASSWD / printf|sudo -S pattern as scp_and_run's wrapper.
    if [[ -z "${SUDO_PASS:-}" ]]; then
      ssh_exec "$host" "sudo -n bash -c $(printf '%q' "$cmd")"
    else
      local escaped_pw
      escaped_pw=$(printf '%q' "$SUDO_PASS")
      ssh_exec "$host" \
        "printf '%s\n' ${escaped_pw} | sudo -S bash -c $(printf '%q' "$cmd") 2>/dev/null"
    fi
  fi
}

run_script_on() {
  local host="$1"
  local script="$2"

  if is_local_node "$host"; then
    info "[${host}] Running $(basename "$script") locally as root..."
    chmod 600 "$script"
    local rc=0
    if [[ -z "${SUDO_PASS:-}" ]]; then
      # NOPASSWD path — full output to terminal and log file
      sudo -n bash "$script" 2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
    else
      # Password path — feed password to sudo via stdin, let script output flow
      # grep -v filters only sudo's own "[sudo] password" prompt from stderr;
      # all actual script stdout/stderr is preserved and logged.
      printf '%s\n' "$SUDO_PASS" \
        | sudo -S bash "$script" 2>&1 \
        | grep -v '^\[sudo\]' \
        | tee -a "$LOG_FILE"
      rc=${PIPESTATUS[1]}   # exit code of sudo, not grep or tee
    fi
    if (( rc != 0 )); then
      error "[${host}] Local script $(basename "$script") failed (exit ${rc}). See ${LOG_FILE} for details."
      return $rc
    fi
    log "[${host}] $(basename "$script") completed successfully (local)."
  else
    scp_and_run "$host" "$script"
  fi
}

fetch_file_from() {
  local host="$1"
  local remote_path="$2"
  local local_path="$3"

  if is_local_node "$host"; then
    cp -f "$remote_path" "$local_path"
  else
    scp -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        "${SSH_USER}@${host}:${remote_path}" \
        "$local_path"
  fi
}

reboot_and_wait() {
  local host="$1"
  local timeout="${2:-300}"   # seconds to wait for node to come back (default 5 min)
  local poll_interval=10

  info "[${host}] Issuing reboot..."

  # Issue reboot via sudo; use '|| true' because the SSH connection will be
  # forcibly closed by the OS as it shuts down — that's expected, not an error.
  if [[ -z "${SUDO_PASS:-}" ]]; then
    ssh_exec "$host" "sudo -n shutdown -r now" 2>/dev/null || true
  else
    local escaped_pw
    escaped_pw=$(printf '%q' "$SUDO_PASS")
    ssh_exec "$host" \
      "printf '%s\n' ${escaped_pw} | sudo -S shutdown -r now 2>/dev/null" \
      2>/dev/null || true
  fi

  # ── Phase A: wait for SSH to go DOWN (node is rebooting) ─────────────────
  info "[${host}] Waiting for node to go offline..."
  local elapsed=0
  local went_down=false
  while (( elapsed < 60 )); do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
    # If SSH connection is refused or times out, the node is rebooting
    if ! ssh -i "$SSH_KEY_PATH" \
             -o StrictHostKeyChecking=no \
             -o ConnectTimeout=5 \
             -o BatchMode=yes \
             "${SSH_USER}@${host}" "true" &>/dev/null; then
      went_down=true
      info "[${host}] Node is down (offline after ${elapsed}s). Waiting for it to come back..."
      break
    fi
  done

  if ! $went_down; then
    warn "[${host}] Node did not go offline within 60s — it may have rebooted too quickly. Continuing..."
  fi

  # ── Phase B: wait for SSH to come back UP ────────────────────────────────
  info "[${host}] Polling for SSH availability (timeout: ${timeout}s)..."
  elapsed=0
  while (( elapsed < timeout )); do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
    if ssh -i "$SSH_KEY_PATH" \
           -o StrictHostKeyChecking=no \
           -o ConnectTimeout=8 \
           -o BatchMode=yes \
           "${SSH_USER}@${host}" "true" &>/dev/null; then
      info "[${host}] SSH is back (${elapsed}s after reboot command) — confirming stability..."
      sleep 5  # Brief pause: sshd can briefly accept then drop during early boot
      break
    fi
    info "[${host}] Still waiting... (${elapsed}s / ${timeout}s)"
    if (( elapsed >= timeout )); then
      error "[${host}] Timed out waiting for node to come back after ${timeout}s."
      return 1
    fi
  done

  # ── Phase C: wait for systemd to reach multi-user target ─────────────────
  info "[${host}] Waiting for OS to reach multi-user.target..."
  elapsed=0
  while (( elapsed < 120 )); do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    local state
    state=$(ssh -i "$SSH_KEY_PATH" \
                -o StrictHostKeyChecking=no \
                -o ConnectTimeout=8 \
                -o BatchMode=yes \
                "${SSH_USER}@${host}" \
                "systemctl is-system-running 2>/dev/null || echo starting" 2>/dev/null || echo "unavailable")
    case "$state" in
      running|degraded)
        log "[${host}] OS is ready (systemd state: ${state})."
        return 0
        ;;
      starting|initializing|unavailable)
        info "[${host}] OS still starting (${elapsed}s)..."
        ;;
      *)
        info "[${host}] systemd state: ${state} (${elapsed}s)..."
        ;;
    esac
  done

  warn "[${host}] systemd did not reach running state within 120s — proceeding anyway."
  return 0
}

