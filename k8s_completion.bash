#!/usr/bin/env bash
# =============================================================================
# k8s_completion.bash — Shell completion for k8s_cluster_setup.sh
# Source this file or add to ~/.bashrc:
#   source /path/to/k8s-install/k8s_completion.bash
#
# Also works for zsh with bashcompinit:
#   autoload bashcompinit && bashcompinit
#   source /path/to/k8s-install/k8s_completion.bash
# =============================================================================

_k8s_cluster_setup_complete() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
  }

  local top_flags="--step --uninstall --validate --preflight --backup --help -h"

  local all_steps="
    ssh prep nvidia k8s-bins init cni workers helm nfs
    monitoring gpu-op gpu-timeslice dashboard vllm verify
    backup restore cert-renew upgrade add-node remove-node vllm-swap
    ceph minio ingress metallb cert-manager harden registry argocd loki
    ray mig pss dcgm alerts cert-monitor
    preflight etcd-health os-patch netpol rbac
    pvc-snapshot pvc-restore vllm-health benchmark
  "

  case "$prev" in
    --step)
      # Complete step names
      COMPREPLY=( $(compgen -W "$all_steps" -- "$cur") )
      return ;;
    --backup)
      # Complete with snapshot files from backup dir
      local backup_dir
      backup_dir=$(grep -s 'BACKUP_DIR=' k8s_cluster.conf 2>/dev/null \
        | head -1 | cut -d= -f2 | tr -d '"' || echo "./backups")
      COMPREPLY=( $(compgen -f -- "${backup_dir}/${cur}") )
      return ;;
  esac

  case "$cur" in
    -*)
      COMPREPLY=( $(compgen -W "$top_flags" -- "$cur") )
      return ;;
  esac

  COMPREPLY=( $(compgen -W "$top_flags" -- "$cur") )
}

_k8s_configure_complete() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local sections="ssh nodes k8s nvidia monitoring nfs dashboard vllm namespaces addons"
  local flags="--section --preflight --show --help -h"

  case "$prev" in
    --section)
      COMPREPLY=( $(compgen -W "$sections" -- "$cur") )
      return ;;
  esac

  COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
}

# Register completions
complete -F _k8s_cluster_setup_complete k8s_cluster_setup.sh
complete -F _k8s_cluster_setup_complete bash\ k8s_cluster_setup.sh
complete -F _k8s_configure_complete k8s_configure.sh
complete -F _k8s_configure_complete bash\ k8s_configure.sh

# Print activation message when sourced interactively
[[ "$-" == *i* ]] && echo "[k8s-install] Tab completion enabled for k8s_cluster_setup.sh and k8s_configure.sh"
