#!/usr/bin/env bash
# Level 2 — Wizard modules source cleanly and expose expected functions
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="wizard_module_sourcing"
source "${ROOT}/tests/test_helpers.sh"

EXPECTED_WIZARD_FNS=(
  # lib
  print_header section_header hint ok err warn_msg show_progress
  prompt_input prompt_optional prompt_choice prompt_yes_no
  prompt_ip prompt_ip_optional prompt_ip_list
  validate_ip validate_cidr validate_namespace validate_nodeport
  validate_password_strength run_preflight check_existing_config
  # sections
  collect_ssh collect_nodes collect_k8s collect_nvidia
  collect_monitoring collect_nfs collect_dashboard collect_vllm
  collect_namespaces collect_addons
  # summary + config + launch
  print_summary confirm_summary write_config patch_installer
  offer_launch run_section_menu parse_args
)

# Source wizard lib + all sections in a clean subshell
DECLARED=$(bash << SUBEOF 2>/dev/null
set -uo pipefail
LOG_FILE=/dev/null
CONFIG_FILE=/tmp/k8s_wiz_test_no_conf_$$
SCRIPT_DIR='${ROOT}'
WIZARD_DIR='${ROOT}/wizard'
# Stub tty-interactive functions so sourcing doesn't block
read()  { true; }
tput()  { true; }
source "\${WIZARD_DIR}/lib.sh" 2>/dev/null || true
for sec in 01_ssh 02_nodes 03_k8s 04_nvidia 05_monitoring \
           06_nfs 07_dashboard 08_vllm 09_namespaces 10_addons \
           summary config launch; do
  f="\${WIZARD_DIR}/sections/\${sec}.sh"
  [[ -f "\$f" ]] && source "\$f" 2>/dev/null || true
done
declare -F | awk '{print \$3}'
SUBEOF
)

PASS=0; FAIL=0
for fn in "${EXPECTED_WIZARD_FNS[@]}"; do
  count=$(echo "$DECLARED" | grep -c "^${fn}$" || true)
  if (( count == 1 )); then
    _pass "$fn declared"
  elif (( count == 0 )); then
    _fail "$fn — NOT DECLARED"
    FAIL=$(( FAIL + 1 ))
  else
    _fail "$fn — DECLARED ${count}x (duplicate!)"
    FAIL=$(( FAIL + 1 ))
  fi
done

summarise_test
