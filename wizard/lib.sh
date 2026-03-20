#!/usr/bin/env bash
# =============================================================================
# wizard/lib.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

# ──────────────────────────────────────────────────────────────────────────────
# STATE VARIABLES initialised here so any sourcer has them from the start.
# k8s_configure.sh sets TOTAL_SECTIONS and CONF_VERSION before sourcing.
# ──────────────────────────────────────────────────────────────────────────────
CURRENT_SECTION="${CURRENT_SECTION:-0}"
TOTAL_SECTIONS="${TOTAL_SECTIONS:-11}"
CONF_VERSION="${CONF_VERSION:-2}"

# ──────────────────────────────────────────────────────────────────────────────
# COLORS & UI PRIMITIVES
# ──────────────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m';    GREEN=$'\033[0;32m';  YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m';   CYAN=$'\033[0;36m';  MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m';      DIM=$'\033[2m';      NC=$'\033[0m'

# readline prompt wrappers — must be actual SOH/STX bytes (not \001/\002).
# $'\001' and $'\002' are ANSI-C quoting: bash expands them to bytes 0x01/0x02
# before passing the string to readline, which uses them to measure prompt width
# without counting the non-printing escape sequences inside.
RL_S=$'\001'   # RL_PROMPT_START_IGNORE  (SOH, 0x01)
RL_E=$'\002'   # RL_PROMPT_END_IGNORE    (STX, 0x02)

SYM_OK="✔";  SYM_ERR="✖";  SYM_WARN="⚠";  SYM_ARROW="▶";  SYM_DOT="•"

print_header() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ╔══════════════════════════════════════════════════════════════╗"
  echo "  ║       Kubernetes Cluster Installer — Configuration Wizard    ║"
  echo "  ║                      Ubuntu 24.04                            ║"
  echo "  ╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

section_header() {
  local title="$1"
  local step="${2:-}"
  echo ""
  echo -e "${BOLD}${CYAN}  ┌─────────────────────────────────────────────────────────┐${NC}"
  if [[ -n "$step" ]]; then
    printf "${BOLD}${CYAN}  │  %-3s  %-52s│${NC}\n" "${step}" "${title}"
  else
    printf "${BOLD}${CYAN}  │  %-57s│${NC}\n" "${title}"
  fi
  echo -e "${BOLD}${CYAN}  └─────────────────────────────────────────────────────────┘${NC}"
  echo ""
}

hint()    { echo -e "  ${DIM}${CYAN}${SYM_DOT} $*${NC}"; }
ok()      { echo -e "  ${GREEN}${SYM_OK}  $*${NC}"; }

err()     { echo -e "  ${RED}${SYM_ERR}  $*${NC}"; }

warn_msg(){ echo -e "  ${YELLOW}${SYM_WARN}  $*${NC}"; }

label()   { echo -e "  ${BOLD}${SYM_ARROW} $*${NC}"; }

info_msg(){ echo -e "  ${BLUE}${SYM_DOT} $*${NC}"; }

show_progress() {
  CURRENT_SECTION=$((CURRENT_SECTION + 1))
  local filled=$((CURRENT_SECTION * 40 / TOTAL_SECTIONS))
  local empty=$((40 - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++));  do bar+="░"; done
  echo -e "\n  ${DIM}Progress: [${CYAN}${bar}${NC}${DIM}] ${CURRENT_SECTION}/${TOTAL_SECTIONS}${NC}\n"
}

prompt_input() {
  local var_name="$1" question="$2" default="${3:-}" secret="${4:-}" input=""
  while true; do
    if [[ "$secret" == "secret" ]]; then
      # Secret fields: no echo, no readline pre-fill (would expose value)
      echo -ne "  ${BOLD}${question}${NC}: "
      read -r -s input
      echo ""
    else
      # -e  enables readline line editing — backspace stays within the input
      #     field; arrow keys, Ctrl-A/E, history all work correctly.
      # -i  pre-fills the field with the default so users can edit in place
      #     rather than having to retype the whole value from scratch.
      local _prompt
      if [[ -n "$default" ]]; then
        _prompt="  ${RL_S}${BOLD}${RL_E}${question}${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}[${default}]${RL_S}${NC}${RL_E}: "
      else
        _prompt="  ${RL_S}${BOLD}${RL_E}${question}${RL_S}${NC}${RL_E}: "
      fi
      read -e -i "$default" -p "$_prompt" input
    fi
    input="${input:-$default}"
    if [[ -z "$input" ]]; then
      err "This field is required."
    else
      # Use printf %q-safe assignment to handle special characters in input
      eval "${var_name}=$(printf '%q' "$input")"
      return 0
    fi
  done
}

prompt_optional() {
  local var_name="$1" question="$2" default="${3:-}" input=""
  local _prompt
  if [[ -n "$default" ]]; then
    _prompt="  ${RL_S}${BOLD}${RL_E}${question}${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}[${default}]${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}(optional)${RL_S}${NC}${RL_E}: "
  else
    _prompt="  ${RL_S}${BOLD}${RL_E}${question}${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}(optional)${RL_S}${NC}${RL_E}: "
  fi
  read -e -i "$default" -p "$_prompt" input
  eval "${var_name}=$(printf '%q' "${input:-$default}")"
}

prompt_choice() {
  local var_name="$1" question="$2"; shift 2
  local options=("$@") choice="" valid=false
  echo -e "  ${BOLD}${question}${NC}"
  for i in "${!options[@]}"; do echo -e "    ${CYAN}$((i+1))${NC}) ${options[$i]}"; done
  while ! $valid; do
        read -e -p "  ${RL_S}${BOLD}${RL_E}Enter choice [1-${#options[@]}]${RL_S}${NC}${RL_E}: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      eval "${var_name}='${options[$((choice-1))]}'"
      valid=true
    else
      err "Invalid choice. Enter a number between 1 and ${#options[@]}."
    fi
  done
}

prompt_yes_no() {
  local var_name="$1" question="$2" default="${3:-n}" input="" display="y/N"
  [[ "$default" == "y" ]] && display="Y/n"
  local _prompt="  ${RL_S}${BOLD}${RL_E}${question}${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}[${display}]${RL_S}${NC}${RL_E}: "
  while true; do
    read -e -p "$_prompt" input
    input="${input:-$default}"; input="${input,,}"
    case "$input" in
      y|yes) eval "${var_name}=true";  return ;;
      n|no)  eval "${var_name}=false"; return ;;
      *)     err "Please enter y or n." ;;
    esac
  done
}

prompt_ip() {
  local var_name="$1" question="$2" default="${3:-}" input=""
  while true; do
    prompt_input "$var_name" "$question" "$default"
    eval "input=\${${var_name}}"
    if validate_ip "$input"; then return 0; else err "'${input}' is not a valid IPv4 address."; fi
  done
}

prompt_ip_optional() {
  local var_name="$1" question="$2" default="${3:-}" input=""
  while true; do
    prompt_optional "$var_name" "$question" "$default"
    eval "input=\${${var_name}}"
    if [[ -z "$input" ]]; then return 0
    elif validate_ip "$input"; then return 0
    else err "'${input}' is not a valid IPv4 address."; fi
  done
}

prompt_ip_list() {
  local var_name="$1" question="$2"
  local ips=() ip="" more=true index=1
  echo -e "  ${BOLD}${question}${NC}"
  hint "Enter one IP per line. Press Enter on a blank line when done."
  echo ""
  while $more; do
    while true; do
      read -e -p "  ${RL_S}${BOLD}${RL_E}Worker ${index} IP${RL_S}${NC}${RL_E} ${RL_S}${DIM}${RL_E}(blank to finish)${RL_S}${NC}${RL_E}: " ip
      if [[ -z "$ip" ]]; then more=false; break
      elif validate_ip "$ip"; then ips+=("$ip"); ok "Added worker: ${ip}"; index=$((index+1)); break
      else err "'${ip}' is not a valid IPv4 address."; fi
    done
  done
  local arr_str="("
  for i in "${ips[@]:-}"; do [[ -n "$i" ]] && arr_str+="\"$i\" "; done
  arr_str="${arr_str% })"
  eval "${var_name}='${arr_str}'"
}

validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do (( octet <= 255 )) || return 1; done
  return 0
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  validate_ip "${cidr%/*}" || return 1
  (( ${cidr#*/} <= 32 )) || return 1
  return 0
}

validate_semver()   { [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; }
validate_abs_path() { [[ "$1" == /* ]] || { err "Path must be absolute (start with /)."; return 1; }; return 0; }

validate_k8s_version() { [[ "$1" =~ ^1\.[2-9][0-9]$ ]] || { err "K8s version must be in format 1.XX (e.g. 1.31)."; return 1; }; return 0; }

validate_helm_version() { validate_semver "$1" || { err "Helm version must be semver (e.g. 3.16.2)."; return 1; }; return 0; }

validate_namespace() {

  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || {
    err "Namespace must be lowercase alphanumeric with hyphens, no leading/trailing hyphens."
    return 1
  }; return 0
}

validate_password_strength() {
  local pw="$1"
  [[ ${#pw} -ge 12 ]]          || { err "Password must be at least 12 characters.";             return 1; }
  [[ "$pw" =~ [A-Z] ]]         || { err "Password must contain at least one uppercase letter."; return 1; }
  [[ "$pw" =~ [a-z] ]]         || { err "Password must contain at least one lowercase letter."; return 1; }
  [[ "$pw" =~ [0-9] ]]         || { err "Password must contain at least one digit.";            return 1; }
  [[ "$pw" =~ [^a-zA-Z0-9] ]] || { err "Password must contain at least one special character."; return 1; }
  return 0
}

validate_nodeport() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 30000 && $1 <= 32767 )) || {
    err "NodePort must be between 30000 and 32767."
    return 1
  }; return 0
}

run_preflight() {
  local mode="${1:-full}"   # full | ssh-only | nfs-only | nodeport-only
  local all_pass=true

  section_header "Pre-flight Checks" "✈"

  # ── 1. Collect all nodes ───────────────────────────────────────────────────
  local all_nodes=("$CONTROL_PLANE_IP")
  if [[ "$WORKER_IPS_STR" != "()" && -n "${WORKER_IPS_STR:-}" ]]; then
    while IFS= read -r -d '"' part; do
      [[ "$part" =~ ^[0-9] ]] && all_nodes+=("$part")
    done <<< "$WORKER_IPS_STR"
  fi

  # ── 2. Ping reachability ──────────────────────────────────────────────────
  info_msg "Checking node reachability (ping)..."
  for node in "${all_nodes[@]}"; do
    if ping -c1 -W2 "$node" &>/dev/null 2>&1; then
      ok "  ${node} — reachable"
    else
      err "  ${node} — NOT reachable (ping failed)"
      warn_msg "  → Check that the node is powered on and the IP is correct."
      all_pass=false
    fi
  done
  echo ""

  # ── 3. SSH port open ─────────────────────────────────────────────────────
  info_msg "Checking SSH port 22..."
  for node in "${all_nodes[@]}"; do
    if command -v nc &>/dev/null; then
      if nc -z -w3 "$node" 22 &>/dev/null 2>&1; then
        ok "  ${node}:22 — open"
      else
        err "  ${node}:22 — port closed or filtered"
        warn_msg "  → Ensure sshd is running: sudo systemctl start ssh"
        all_pass=false
      fi
    else
      # fallback: bash /dev/tcp
      if (echo >/dev/tcp/"$node"/22) &>/dev/null 2>&1; then
        ok "  ${node}:22 — open"
      else
        warn_msg "  ${node}:22 — could not check (nc not available)"
      fi
    fi
  done
  echo ""

  # ── 4. SSH key authentication ─────────────────────────────────────────────
  if [[ -f "$SSH_KEY_PATH" ]]; then
    info_msg "Testing SSH key authentication..."
    for node in "${all_nodes[@]}"; do
      if ssh -i "$SSH_KEY_PATH" \
             -o StrictHostKeyChecking=no \
             -o BatchMode=yes \
             -o ConnectTimeout=5 \
             "${SSH_USER}@${node}" "echo ok" &>/dev/null 2>&1; then
        ok "  ${SSH_USER}@${node} — SSH key auth works"
      else
        warn_msg "  ${SSH_USER}@${node} — SSH key auth not yet available"
        hint "    This is OK before first install — the wizard will copy the key."
      fi
    done
  else
    info_msg "SSH key ${SSH_KEY_PATH} not yet generated — will be created during install."
  fi
  echo ""

  # ── 5. Local disk space ──────────────────────────────────────────────────
  info_msg "Checking local disk space..."
  local free_mb
  free_mb=$(df -m "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ -n "$free_mb" ]]; then
    if (( free_mb >= 500 )); then
      ok "  Local free space: ${free_mb} MB — sufficient"
    else
      warn_msg "  Local free space: ${free_mb} MB — low (recommend >= 500 MB)"
    fi
  fi
  echo ""

  # ── 6. NFS reachability ──────────────────────────────────────────────────
  if [[ "${INSTALL_NFS:-false}" == "true" && -n "${NFS_SERVER_IP:-}" ]]; then
    info_msg "Checking NFS server reachability (${NFS_SERVER_IP})..."
    # Try showmount first, then nc fallback for port 2049
    if command -v showmount &>/dev/null; then
      local exports
      exports=$(showmount -e "$NFS_SERVER_IP" 2>&1)
      if echo "$exports" | grep -q "${NFS_PATH:-}"; then
        ok "  NFS export ${NFS_PATH} found on ${NFS_SERVER_IP}"
      elif echo "$exports" | grep -qE "Export list|/"; then
        warn_msg "  NFS server responds but ${NFS_PATH} not in export list"
        warn_msg "  → Exports found: $(echo "$exports" | grep '/' | head -3)"
      else
        err "  Cannot reach NFS server ${NFS_SERVER_IP} via showmount"
        warn_msg "  → Check that nfs-kernel-server is running and ports 2049/111 are open"
        all_pass=false
      fi
    elif command -v nc &>/dev/null; then
      if nc -z -w3 "$NFS_SERVER_IP" 2049 &>/dev/null 2>&1; then
        ok "  NFS port 2049 open on ${NFS_SERVER_IP}"
      else
        err "  NFS port 2049 closed on ${NFS_SERVER_IP}"
        all_pass=false
      fi
    else
      warn_msg "  Cannot check NFS (no showmount or nc available) — skipping"
    fi
    echo ""
  fi

  # ── 7. NodePort conflict detection ───────────────────────────────────────
  info_msg "Checking for NodePort conflicts..."
  declare -A port_map
  local conflicts=false
  _register_port() {
    local port="$1" name="$2"
    [[ -z "$port" ]] && return
    if [[ -n "${port_map[$port]:-}" ]]; then
      err "  NodePort ${port} is used by both '${port_map[$port]}' and '${name}'"
      conflicts=true; all_pass=false
    else
      port_map[$port]="$name"
      ok "  Port ${port} → ${name}"
    fi
  }
  [[ "${INSTALL_MONITORING:-false}" == "true" ]] && {
    _register_port "${GRAFANA_NODEPORT:-32000}"      "Grafana"
    _register_port "${PROMETHEUS_NODEPORT:-32001}"   "Prometheus"
    _register_port "${ALERTMANAGER_NODEPORT:-32002}"  "Alertmanager"
  }
  [[ "${INSTALL_DASHBOARD:-false}" == "true" ]] && \
    _register_port "${DASHBOARD_NODEPORT:-32443}"    "Dashboard"
  [[ "${INSTALL_VLLM:-false}" == "true" ]] && \
    _register_port "${VLLM_NODEPORT:-32080}"         "vLLM Router"
  $conflicts || ok "  No NodePort conflicts detected"
  echo ""

  # ── Result ────────────────────────────────────────────────────────────────
  if $all_pass; then
    ok "All pre-flight checks passed."
  else
    warn_msg "Some pre-flight checks failed — review the warnings above."
    if [[ "$mode" == "full" ]]; then
      echo ""
      prompt_yes_no _PF_CONTINUE "Continue anyway?" "y"
      [[ "${_PF_CONTINUE}" != "true" ]] && { echo ""; warn_msg "Aborted."; exit 1; }
    fi
  fi
  echo ""
}

check_existing_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    print_header
    echo -e "  ${YELLOW}${SYM_WARN}  An existing configuration was found:${NC}"
    echo -e "  ${DIM}${CONFIG_FILE}${NC}"
    echo ""
    source "$CONFIG_FILE" 2>/dev/null || true

    # Version migration
    local file_ver="${CONF_VERSION_FILE:-1}"
    if grep -q "CONF_VERSION=" "$CONFIG_FILE" 2>/dev/null; then
      file_ver=$(grep "CONF_VERSION=" "$CONFIG_FILE" | head -1 | cut -d= -f2)
    fi
    if (( file_ver < CONF_VERSION )); then
      warn_msg "Config file is version ${file_ver} — current wizard is version ${CONF_VERSION}."
      hint "New fields will be added with defaults when you reconfigure."
    fi

    echo -e "  ${DIM}Control plane : ${CONTROL_PLANE_IP:-<not set>}${NC}"
    echo -e "  ${DIM}Workers       : $(echo "${WORKER_IPS[@]:-}" | tr ' ' ',' | sed 's/,$//') ${NC}"
    echo -e "  ${DIM}SSH user      : ${SSH_USER:-<not set>}${NC}"
    echo -e "  ${DIM}K8s version   : ${K8S_VERSION:-<not set>}${NC}"
    echo -e "  ${DIM}CNI           : ${CNI_PLUGIN:-<not set>}${NC}"
    echo ""

    echo -e "  ${BOLD}Options:${NC}"
    echo -e "    ${CYAN}r${NC}) Reconfigure (full wizard)"
    echo -e "    ${CYAN}e${NC}) Edit a single section"
    echo -e "    ${CYAN}p${NC}) Run pre-flight checks against current config"
    echo -e "    ${CYAN}s${NC}) Show config and launch installer"
    echo -e "    ${CYAN}q${NC}) Quit"
    echo ""
    local choice; read -e -p "  ${RL_S}${BOLD}${RL_E}Choice [r/e/p/s/q]${RL_S}${NC}${RL_E}: " choice
    case "${choice,,}" in
      r) echo ""; return ;;   # fall through to full wizard
      e) run_section_menu ;;
      p)
        WORKER_IPS_STR="($(echo "${WORKER_IPS[@]:-}" | tr ' ' '\n' | grep '\.' | sed 's/^/"/' | sed 's/$/" /' | tr -d '\n'))"
        run_preflight preflight-only
        offer_launch; exit 0 ;;
      s)
        print_header
        section_header "Current Configuration"
        WORKER_IPS_STR="($(echo "${WORKER_IPS[@]:-}" | tr ' ' '\n' | grep '\.' | sed 's/^/"/' | sed 's/$/" /' | tr -d '\n'))"
        print_summary
        offer_launch; exit 0 ;;
      q|"") echo ""; ok "Keeping existing configuration."; offer_launch; exit 0 ;;
      *)    echo ""; return ;;
    esac
  fi
}

