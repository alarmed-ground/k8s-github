#!/usr/bin/env bash
# =============================================================================
# 08_helm.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

install_helm() {
  section "Step — Installing Helm ${HELM_VERSION}"

  if command -v helm &>/dev/null; then
    local installed_ver
    installed_ver=$(helm version --short 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ "$installed_ver" == "$HELM_VERSION" ]]; then
      log "Helm ${HELM_VERSION} already installed — skipping."
      return
    fi
    warn "Helm ${installed_ver} installed but ${HELM_VERSION} requested — upgrading..."
  fi

  local helm_tar="/tmp/helm-v${HELM_VERSION}.tar.gz"
  local arch
  arch=$(dpkg --print-architecture)
  curl -fsSL \
    "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" \
    -o "$helm_tar"
  tar -zxf "$helm_tar" -C /tmp
  install -o root -g root -m 0755 "/tmp/linux-${arch}/helm" /usr/local/bin/helm
  rm -rf "$helm_tar" "/tmp/linux-${arch}"
  log "Helm $(helm version --short) installed."
}

