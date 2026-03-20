#!/usr/bin/env bash
# =============================================================================
# lib/logging.sh — Colour constants and logging functions
# Sourced early by k8s_cluster_setup.sh before any other module.
# LOG_FILE must already be set by the entry point.
# =============================================================================
# shellcheck shell=bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔  $*${NC}" | tee -a "$LOG_FILE" || true; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠  $*${NC}" | tee -a "$LOG_FILE" || true; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ✖  $*${NC}" | tee -a "$LOG_FILE" >&2 || true; }
info()    { echo -e "${CYAN}[$(date '+%H:%M:%S')] ℹ  $*${NC}" | tee -a "$LOG_FILE" || true; }
section() {
  {
    local _snum=""
    [[ -n "${_step:-}" && "${_step}" != "0" ]] && _snum=" [${_step}/${_step_total:-?}]"
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $*${_snum}${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════${NC}\n"
  } | tee -a "$LOG_FILE" || true
}
