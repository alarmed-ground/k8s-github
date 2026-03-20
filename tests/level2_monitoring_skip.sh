#!/usr/bin/env bash
# Level 2 — Unit test: install_monitoring skips and masks password in logs
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="monitoring"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: skips when INSTALL_MONITORING=false ──────────────────────────────
INSTALL_MONITORING="false"
reset_calls
run_step_noabort install_monitoring
assert_not_called "helm upgrade" "monitoring: no helm when disabled"

# ── Test 2: password NOT in log output ───────────────────────────────────────
# The real password must never appear verbatim in any info/log output
INSTALL_MONITORING="true"
GRAFANA_ADMIN_PASSWORD="SuperSecret123!"

real_log=""
info() { real_log+="$*"; }
log()  { real_log+="$*"; }

# Stub helm to avoid actual deployment
helm() { _TEST_CALLS+=("helm $*"); return 0; }
kubectl() { _TEST_CALLS+=("kubectl $*"); return 0; }

reset_calls
run_step_noabort install_monitoring

# Password must not appear in anything logged
if [[ "$real_log" == *"SuperSecret123!"* ]]; then
  _fail "password must not appear in log output"
else
  _pass "password masked in log output"
fi

summarise_test
