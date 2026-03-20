#!/usr/bin/env bash
# =============================================================================
# wizard/sections/01_ssh.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_ssh() {
  section_header "SSH & Node Access" "1/10"
  hint "These credentials are used to connect to all cluster nodes."
  echo ""

  prompt_input SSH_USER "Remote username" "ubuntu"
  ok "SSH user: ${SSH_USER}"

  prompt_input SSH_KEY_PATH \
    "SSH private key path (will be generated if missing)" \
    "${HOME}/.ssh/k8s_cluster_rsa"
  ok "Key path: ${SSH_KEY_PATH}"

  show_progress
}

