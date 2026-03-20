#!/usr/bin/env bash
# =============================================================================
# wizard/sections/06_nfs.sh
# Part of the k8s-install wizard.
# Sourced by k8s_configure.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../../k8s_configure.sh

collect_nfs() {
  section_header "NFS Storage Provisioner" "6/10"
  hint "Sets up dynamic PVC provisioning via an NFS server."
  echo ""

  prompt_yes_no INSTALL_NFS "Install NFS external provisioner?" "y"
  echo ""

  if [[ "$INSTALL_NFS" == "true" ]]; then
    prompt_ip_optional NFS_SERVER_IP "NFS server IP" "${CONTROL_PLANE_IP:-}"
    ok "NFS server: ${NFS_SERVER_IP:-<none>}"
    echo ""

    while true; do
      prompt_input NFS_PATH "NFS export path on server" "/srv/nfs/k8s"
      validate_abs_path "$NFS_PATH" && ok "NFS path: ${NFS_PATH}" && break
    done
    echo ""

    while true; do
      prompt_input NS_NFS "NFS provisioner namespace" "nfs-provisioner"
      validate_namespace "$NS_NFS" && ok "Namespace: ${NS_NFS}" && break
    done
    echo ""

    prompt_input NFS_STORAGE_CLASS "StorageClass name" "nfs-client"
    ok "StorageClass: ${NFS_STORAGE_CLASS}"
    prompt_yes_no NFS_DEFAULT_SC "Make this the default StorageClass?" "y"
    ok "Default SC: ${NFS_DEFAULT_SC}"

  else
    NFS_SERVER_IP=""
    NFS_PATH="/srv/nfs/k8s"
    NS_NFS="nfs-provisioner"
    NFS_STORAGE_CLASS="nfs-client"
    NFS_DEFAULT_SC="false"
    warn_msg "NFS provisioner will be skipped."
  fi

  show_progress
}

