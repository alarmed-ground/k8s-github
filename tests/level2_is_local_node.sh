#!/usr/bin/env bash
# Level 2 — Unit test: is_local_node detection
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_TEST_NAME="is_local_node"
source "${ROOT}/tests/test_helpers.sh"
bootstrap_installer "$ROOT"
# Re-set local IP cache after bootstrap so is_local_node works predictably
_LOCAL_IPS="127.0.0.1 localhost"
_build_local_ip_cache() { return 0; }  # prevent cache rebuild from real ip addr

_test_local() {
  local _ip="$1" _expect="$2" _label="is_local_node(${1}) == ${2}"
  local _result
  if is_local_node "$_ip" 2>/dev/null; then _result="local"; else _result="remote"; fi
  assert_eq "$_result" "$_expect" "$_label"
}

_test_local "127.0.0.1"   "local"
_test_local "localhost"   "local"
_test_local "::1"         "remote"
_test_local "203.0.113.1" "remote"
_test_local "192.0.2.1"   "remote"

summarise_test
