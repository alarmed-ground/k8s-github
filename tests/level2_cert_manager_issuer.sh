#!/usr/bin/env bash
# Level 2 — install_cert_manager applies the correct ClusterIssuer
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="cert_manager"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
export KUBECONFIG=/dev/null

# ── Test 1: selfsigned issuer applies selfSigned CR ──────────────────────────
INSTALL_CERT_MANAGER="true"; CERT_MANAGER_ISSUER="selfsigned"
CERT_MANAGER_EMAIL=""; NS_CERT_MANAGER="cert-manager"
run_step_capture install_cert_manager
assert_subcalled "selfSigned" "selfsigned: selfSigned spec applied"

# ── Test 2: letsencrypt without email exits non-zero ─────────────────────────
CERT_MANAGER_ISSUER="letsencrypt"; CERT_MANAGER_EMAIL=""
run_step_noabort install_cert_manager
assert_neq "$?" "0" "letsencrypt without email exits non-zero"

# ── Test 3: letsencrypt with email uses production ACME URL ──────────────────
CERT_MANAGER_EMAIL="test@example.com"
run_step_capture install_cert_manager
assert_subcalled "acme-v02.api.letsencrypt.org" "letsencrypt: production ACME URL"

# ── Test 4: letsencrypt-staging uses staging URL ─────────────────────────────
CERT_MANAGER_ISSUER="letsencrypt-staging"
run_step_capture install_cert_manager
assert_subcalled "acme-staging-v02" "letsencrypt-staging: staging URL"

summarise_test
