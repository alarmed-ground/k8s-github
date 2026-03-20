#!/usr/bin/env bash
# =============================================================================
# node_scripts.sh
# Part of the k8s-install modular installer.
# Sourced by k8s_cluster_setup.sh — do not run directly.
# =============================================================================
# shellcheck shell=bash
# shellcheck source=../k8s_cluster_setup.sh

generate_node_prep_script() {
  # Note: single-quoted heredoc (<<'NODEPREP') — no local variable expansion.
  # $(dpkg --print-architecture) and $(lsb_release -cs) expand on the REMOTE node.
  cat <<'NODEPREP'
#!/usr/bin/env bash
# =============================================================================
# node_prep.sh — Kubernetes node preparation for Ubuntu 24.04
# Runs as root on each cluster node via scp_and_run
# =============================================================================
set -euo pipefail

# ── Error trap: print the failing line number before exiting ─────────────────
trap 'echo "[node-prep] ERROR on line ${LINENO} — exit code ${?}" >&2' ERR

# ── Fully non-interactive apt — prevents ALL interactive prompts ──────────────
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
APT_OPTS=(
  -y -qq
  -o Dpkg::Options::="--force-confdef"
  -o Dpkg::Options::="--force-confold"
  -o APT::Get::Assume-Yes=true
  -o APT::Get::Show-Upgraded=false
)

step() { echo ""; echo "[node-prep] ── ${*} ──────────────────────────────"; }

# ── Robust apt-get update with clock-skew and transient failure handling ──────
# "Release file is not valid yet" = system clock is behind the mirror.
# We fix the clock with chrony/ntp, then retry with Acquire::Check-Valid-Until=false
# as a fallback so a minor skew never blocks the install.
apt_update_safe() {
  local attempts=3
  local delay=15

  # Sync clock first — eliminates the "not valid yet" error in most cases
  if command -v chronyc &>/dev/null; then
    chronyc makestep 2>/dev/null || true
  elif command -v ntpdate &>/dev/null; then
    ntpdate -u pool.ntp.org 2>/dev/null || true
  else
    # Install and run chrony if nothing is available
    apt-get install -y -qq chrony 2>/dev/null || true
    chronyc makestep 2>/dev/null || true
  fi

  local i=1
  while (( i <= attempts )); do
    echo "[node-prep] apt-get update (attempt ${i}/${attempts})..."
    # Acquire::Check-Valid-Until=false tolerates mirrors whose Release file
    # timestamp is ahead of our system clock by a small amount
    if apt-get update -qq \
        -o Acquire::Check-Valid-Until=false \
        -o Acquire::Retries=3 \
        2>&1 | grep -v "^$"; then
      echo "[node-prep] apt cache updated successfully."
      return 0
    fi
    warn_apt=$?
    echo "[node-prep] apt-get update attempt ${i} failed (exit ${warn_apt}), retrying in ${delay}s..."
    sleep $delay
    delay=$(( delay * 2 ))   # exponential back-off: 15s, 30s, 60s
    i=$(( i + 1 ))
  done

  echo "[node-prep] WARNING: apt-get update failed after ${attempts} attempts — continuing anyway." >&2
  return 0   # never block the install over an apt cache issue
}

# ── 1. Package updates ────────────────────────────────────────────────────────
step "Updating apt cache"
apt_update_safe

step "Upgrading installed packages"
apt-get upgrade "${APT_OPTS[@]}" \
  -o Acquire::Check-Valid-Until=false || true

step "Installing prerequisites"
apt-get install "${APT_OPTS[@]}" \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  nfs-common \
  open-iscsi \
  jq \
  htop \
  vim \
  net-tools \
  unzip \
  socat \
  conntrack \
  ipvsadm \
  ipset

# ── 2. Disable swap ───────────────────────────────────────────────────────────
step "Disabling swap"
swapoff -a
# Remove any swap entries from /etc/fstab (idempotent)
sed -i.bak '/[[:space:]]swap[[:space:]]/d' /etc/fstab
echo "[node-prep] Swap disabled."

# ── 2b. Fix systemd-resolved stub DNS ────────────────────────────────────────
# Ubuntu 24.04 defaults /etc/resolv.conf to the systemd-resolved stub at
# 127.0.0.53.  That address is only reachable on the node's loopback interface
# and is unreachable from inside pod network namespaces, causing DNS failures
# like "Temporary failure in name resolution" inside containers (e.g. vLLM
# trying to reach huggingface.co).
# Fix: point /etc/resolv.conf at the real upstream resolv.conf that
# systemd-resolved maintains, which contains actual nameserver IPs.
step "Fixing /etc/resolv.conf for pod DNS (systemd-resolved stub workaround)"
if grep -q '127.0.0.53' /etc/resolv.conf 2>/dev/null; then
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  echo "[node-prep] /etc/resolv.conf re-linked to /run/systemd/resolve/resolv.conf"
  # Verify the result has a real nameserver
  if grep -q '127.0.0.53' /etc/resolv.conf 2>/dev/null; then
    echo "[node-prep] WARNING: /run/systemd/resolve/resolv.conf still shows stub — trying fallback"
    # Fallback: extract real nameservers from resolvectl and write a static file
    resolvectl status 2>/dev/null \
      | awk '/DNS Servers/{for(i=3;i<=NF;i++) print "nameserver " $i}' \
      | head -3 > /etc/resolv.conf.real
    echo "search cluster.local" >> /etc/resolv.conf.real
    if [[ -s /etc/resolv.conf.real ]]; then
      cp /etc/resolv.conf.real /etc/resolv.conf
      echo "[node-prep] Wrote static /etc/resolv.conf from resolvectl output."
    else
      # Last resort: use well-known public DNS
      printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\nsearch cluster.local\n' \
        > /etc/resolv.conf
      echo "[node-prep] WARNING: fell back to 8.8.8.8 — set a proper nameserver later."
    fi
  fi
else
  echo "[node-prep] /etc/resolv.conf already has a real nameserver — no change needed."
fi

# ── 3. Kernel modules ─────────────────────────────────────────────────────────
step "Loading required kernel modules"
modprobe overlay
modprobe br_netfilter

# Persist across reboots
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
echo "[node-prep] Kernel modules loaded and persisted."

# ── 4. Sysctl — networking parameters for Kubernetes ─────────────────────────
step "Applying sysctl settings"
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
# Required for iptables-based k8s networking
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# Increase inotify limits for kubelet file watchers
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
# Required for Elasticsearch / OpenSearch workloads
vm.max_map_count                    = 262144
# Connection tracking table size
net.netfilter.nf_conntrack_max      = 1048576
# Disable strict reverse-path filtering.
# Ubuntu 24.04 defaults to rp_filter=2 (strict mode), which drops packets
# whose return path differs from the incoming interface — exactly what happens
# with Calico VXLAN and asymmetric pod routing.  Setting to 0 (off) is
# required for Calico; setting to 1 (loose) is the minimum for Flannel.
# Calico's own install docs require rp_filter=0 on all nodes.
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl --system -q
echo "[node-prep] Sysctl applied."

# ── 4b. IP masquerade for pod CIDR ────────────────────────────────────────────
# Without this, pods (including CoreDNS) send UDP/TCP with source IPs from the
# pod CIDR (e.g. 10.244.0.0/16).  The upstream router does not know this range
# and drops the packets — causing CoreDNS "i/o timeout" errors when forwarding
# queries to the upstream nameserver, which manifests as DNS failures inside
# every pod ("Temporary failure in name resolution").
#
# The MASQUERADE rule SNAT's outbound pod traffic to the node's own IP before
# it leaves the NIC, so the router sees packets from a known host IP and replies
# correctly.  Flannel normally adds this rule itself, but only after kubeadm
# init — this ensures it is present before any pods start.
step "Adding pod CIDR masquerade rule (pod → external SNAT)"
# Derive the pod CIDR — use the configured value if available, else default
_POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
# Idempotent: only add if not already present
if ! iptables -t nat -C POSTROUTING -s "${_POD_CIDR}" ! -d "${_POD_CIDR}" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "${_POD_CIDR}" ! -d "${_POD_CIDR}" -j MASQUERADE
  echo "[node-prep] Masquerade rule added for ${_POD_CIDR}."
else
  echo "[node-prep] Masquerade rule for ${_POD_CIDR} already present — skipping."
fi

# Persist the rule so it survives reboots
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save 2>/dev/null || true
elif command -v iptables-save &>/dev/null; then
  # Install iptables-persistent non-interactively if not present
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>/dev/null || true
  netfilter-persistent save 2>/dev/null || true
fi
echo "[node-prep] Masquerade rule persisted."


step "Installing containerd"

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker apt repository
# Note: uses $(...) which expands correctly on the remote at runtime
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install "${APT_OPTS[@]}" containerd.io

# ── 5a. Configure containerd ──────────────────────────────────────────────────
step "Configuring containerd"

# Generate default config (overwrites any existing one)
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup — required when kubelet uses systemd cgroup driver
if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  echo "[node-prep] containerd: SystemdCgroup set to true."
else
  echo "[node-prep] containerd: SystemdCgroup already true or not found — skipping."
fi

# Ensure sandbox image is set (prevents pull errors on air-gapped setups)
# Uses the default pause image — override if using a private registry
if ! grep -q 'sandbox_image' /etc/containerd/config.toml; then
  sed -i '/\[plugins."io.containerd.grpc.v1.cri"\]/a\  sandbox_image = "registry.k8s.io/pause:3.9"' \
    /etc/containerd/config.toml
fi

systemctl restart containerd
systemctl enable containerd

# Verify containerd is running before proceeding
sleep 2
if ! systemctl is-active --quiet containerd; then
  echo "[node-prep] ERROR: containerd failed to start." >&2
  journalctl -u containerd --no-pager -n 30 >&2
  exit 1
fi
echo "[node-prep] containerd is running."

# ── 6. Verify critical tools are available ────────────────────────────────────
step "Verifying installation"
for cmd in curl gpg modprobe sysctl containerd; do
  if command -v "$cmd" &>/dev/null; then
    echo "[node-prep]   ✔  ${cmd}"
  else
    echo "[node-prep]   ✖  ${cmd} NOT FOUND" >&2
    exit 1
  fi
done

echo ""
echo "[node-prep] ══════════════════════════════════════════════"
echo "[node-prep]   Node preparation complete on $(hostname)"
echo "[node-prep] ══════════════════════════════════════════════"
NODEPREP
}

generate_nvidia_install_script() {
  local driver_ver="$1"
  local open_kernel="${2:-false}"
  local install_fabric_mgr="${3:-auto}"
  local pkg_suffix=""
  [[ "$open_kernel" == "true" ]] && pkg_suffix="-open"

  cat <<NVIDIAINSTALL
#!/usr/bin/env bash
# NVIDIA Phase 1 — driver install (pre-reboot)
# Branch: ${driver_ver}${pkg_suffix:+ (open kernel)}
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── 1. GPU presence re-check (defensive — caller already verified) ────────────
echo "[nvidia-install] Verifying NVIDIA GPU presence..."
if ! command -v lspci &>/dev/null; then
  apt-get install -y -qq pciutils
fi
if ! lspci | grep -qi nvidia; then
  echo "[nvidia-install] WARNING: No NVIDIA GPU found — nothing to install."
  exit 0
fi
GPU_NAME=\$(lspci | grep -i nvidia | head -1)
echo "[nvidia-install] Confirmed: \${GPU_NAME}"

# ── 2. Blacklist nouveau ───────────────────────────────────────────────────────
echo "[nvidia-install] Blacklisting nouveau driver..."
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'BEOF'
blacklist nouveau
options nouveau modeset=0
BEOF
update-initramfs -u -k all 2>/dev/null || true

# ── 3. Add graphics-drivers PPA ───────────────────────────────────────────────
echo "[nvidia-install] Adding graphics-drivers PPA..."
apt-get install -y -qq software-properties-common
add-apt-repository -y ppa:graphics-drivers/ppa
apt-get update -qq

# ── 4. Install driver package ─────────────────────────────────────────────────
DRIVER_PKG="nvidia-driver-${driver_ver}${pkg_suffix}"
UTILS_PKG="nvidia-utils-${driver_ver}"
echo "[nvidia-install] Installing \${DRIVER_PKG} and \${UTILS_PKG}..."
apt-get install -y -qq "\${DRIVER_PKG}" "\${UTILS_PKG}"

# ── 5. Fabric Manager (NVLink / NVSwitch systems) ─────────────────────────────
INSTALL_FM="${install_fabric_mgr}"
if [[ "\${INSTALL_FM}" == "auto" ]]; then
  if lspci | grep -qiE 'NVSwitch|NVLink|SXM'; then
    INSTALL_FM="true"
    echo "[nvidia-install] NVSwitch/SXM detected — will install Fabric Manager."
  else
    INSTALL_FM="false"
  fi
fi

if [[ "\${INSTALL_FM}" == "true" ]]; then
  echo "[nvidia-install] Installing nvidia-fabricmanager-${driver_ver}..."
  apt-get install -y -qq nvidia-fabricmanager-${driver_ver}
  # Enable but do NOT start yet — GPU module not loaded until after reboot
  systemctl enable nvidia-fabricmanager
  echo "[nvidia-install] Fabric Manager enabled (will start after reboot)."
fi

echo "[nvidia-install] Driver packages installed. Node will now be rebooted by the installer."
NVIDIAINSTALL
}

generate_nvidia_postboot_script() {
  local driver_ver="$1"

  cat <<'NVIDIAPOST'
#!/usr/bin/env bash
# NVIDIA Phase 2 — post-reboot verification and container toolkit setup
# Phase 2 only runs on nodes where GPU was detected and Phase 1 succeeded.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── 1. Wait for dkms to finish building the kernel module ─────────────────────
# Ubuntu 24.04 installs drivers via dkms. After reboot, dkms may still be
# compiling the .ko — nvidia-smi will fail with "No devices found" until done.
echo "[nvidia-post] Checking dkms build status..."
DKMS_WAITED=0
DKMS_MAX=300
while (( DKMS_WAITED < DKMS_MAX )); do
  if pgrep -x dkms &>/dev/null; then
    echo "[nvidia-post] dkms still building (${DKMS_WAITED}s elapsed)..."
    sleep 10; DKMS_WAITED=$(( DKMS_WAITED + 10 ))
  else
    break
  fi
done
echo "[nvidia-post] dkms status:"
dkms status 2>/dev/null || true

# ── 2. Load the nvidia kernel module ─────────────────────────────────────────
# The module may not auto-load on first boot after install; force it here.
echo "[nvidia-post] Loading nvidia kernel modules..."
modprobe nvidia       || true
modprobe nvidia_uvm   || true
modprobe nvidia_drm   || true
modprobe nvidia_modeset || true
echo "[nvidia-post] Loaded modules: $(lsmod | grep -o '^nvidia[^ ]*' | tr '\n' ' ' || echo none)"

# ── 3. Verify nvidia-smi (up to 3 min) ───────────────────────────────────────
echo "[nvidia-post] Verifying nvidia-smi..."
SMI_OK=false
for i in $(seq 1 12); do
  if /usr/bin/nvidia-smi &>/dev/null; then
    SMI_OK=true
    echo "[nvidia-post] nvidia-smi succeeded on attempt ${i}."
    /usr/bin/nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    break
  fi
  echo "[nvidia-post] nvidia-smi not ready (attempt ${i}/12) — retrying in 15s..."
  sleep 15
  modprobe nvidia 2>/dev/null || true
done

if [[ "$SMI_OK" != "true" ]]; then
  echo "[nvidia-post] ─────────────── DIAGNOSTICS ───────────────" >&2
  echo "--- lsmod | nvidia ---" >&2
  lsmod | grep -i nvidia >&2 || echo "(no nvidia modules loaded)" >&2
  echo "--- dkms status ---" >&2
  dkms status 2>/dev/null >&2 || true
  echo "--- dmesg (nvidia/nvrm) ---" >&2
  dmesg | grep -iE "nvrm|nvidia|modprobe" | tail -40 >&2
  echo "--- /proc/driver/nvidia/version ---" >&2
  cat /proc/driver/nvidia/version 2>/dev/null || echo "(not present)" >&2
  echo "[nvidia-post] ────────────────────────────────────────────" >&2
  echo "[nvidia-post] ERROR: nvidia-smi failed after 3 min. See diagnostics above." >&2
  exit 1
fi

# ── 4. Start Fabric Manager if installed ──────────────────────────────────────
if systemctl list-unit-files | grep -q nvidia-fabricmanager; then
  echo "[nvidia-post] Starting Fabric Manager..."
  systemctl enable --now nvidia-fabricmanager
  if systemctl is-active --quiet nvidia-fabricmanager; then
    echo "[nvidia-post] Fabric Manager is running."
  else
    echo "[nvidia-post] WARNING: Fabric Manager failed to start." >&2
    journalctl -u nvidia-fabricmanager --no-pager -n 20 >&2
  fi
fi

# ── 5. Install NVIDIA Container Toolkit ───────────────────────────────────────
echo "[nvidia-post] Installing NVIDIA Container Toolkit..."
install -m 0755 -d /etc/apt/keyrings
# --batch --yes makes this idempotent if the keyring file already exists
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --batch --yes --dearmor \
      -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
chmod 644 /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit

# ── 6. Configure container runtimes ───────────────────────────────────────────
echo "[nvidia-post] Configuring containerd for NVIDIA runtime..."
nvidia-ctk runtime configure --runtime=containerd
systemctl restart containerd
sleep 3
if ! systemctl is-active --quiet containerd; then
  echo "[nvidia-post] ERROR: containerd failed to restart." >&2
  journalctl -u containerd --no-pager -n 20 >&2
  exit 1
fi

if command -v docker &>/dev/null; then
  echo "[nvidia-post] Configuring Docker for NVIDIA runtime..."
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker 2>/dev/null || true
fi

# ── 7. Enable persistence daemon ──────────────────────────────────────────────
if systemctl list-unit-files | grep -q nvidia-persistenced; then
  systemctl enable --now nvidia-persistenced 2>/dev/null || true
  echo "[nvidia-post] Persistence daemon enabled."
fi

# ── 8. MIG informational report ───────────────────────────────────────────────
if /usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null \
    | grep -q "Enabled\|Disabled"; then
  MIG_STATE=$(/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader | head -1)
  echo "[nvidia-post] MIG-capable GPU detected. Current MIG mode: ${MIG_STATE}"
  echo "[nvidia-post] To enable MIG: nvidia-smi -mig 1  (requires another reboot)"
fi

echo ""
echo "[nvidia-post] ╔══════════════════════════════════════════════════╗"
echo "[nvidia-post] ║  NVIDIA driver fully activated.                  ║"
echo "[nvidia-post] ║  Container toolkit configured.                   ║"
echo "[nvidia-post] ║  Verify with: nvidia-smi                         ║"
echo "[nvidia-post] ╚══════════════════════════════════════════════════╝"
NVIDIAPOST
}

generate_k8s_binaries_script() {
  local k8s_ver="$1"
  # Quoted heredoc (<<'K8SBINEOF') — no variable expansion by the outer shell.
  # K8S_VER_PLACEHOLDER is replaced by sed below so the generated script gets
  # the correct version baked in as a literal string (no variables needed).
  sed "s|K8S_VER_PLACEHOLDER|${k8s_ver}|g" <<'K8SBINEOF'
#!/usr/bin/env bash
set -euo pipefail
echo "[k8s-bin] Adding Kubernetes apt repository (vK8S_VER_PLACEHOLDER)..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/vK8S_VER_PLACEHOLDER/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/vK8S_VER_PLACEHOLDER/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl kubernetes-cni
apt-mark hold kubelet kubeadm kubectl

# Ensure CNI plugin binaries exist in /opt/cni/bin.
# kubernetes-cni normally installs them, but after a kubeadm reset the
# directory can be absent even if the package is already marked installed.
# The loopback plugin is required for every pod sandbox — without it every
# pod fails with "failed to find plugin loopback in path [/opt/cni/bin]".
if [[ ! -f /opt/cni/bin/loopback ]]; then
  echo "[k8s-bin] /opt/cni/bin/loopback missing — installing CNI plugins from upstream..."
  CNI_VER=v1.4.0
  mkdir -p /opt/cni/bin
  curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VER}/cni-plugins-linux-amd64-${CNI_VER}.tgz" \
    | tar -xz -C /opt/cni/bin
  echo "[k8s-bin] CNI plugins installed: $(ls /opt/cni/bin | tr '\n' ' ')"
else
  echo "[k8s-bin] CNI plugins already present at /opt/cni/bin."
fi

systemctl enable --now kubelet
echo "[k8s-bin] Kubernetes binaries installed and held."
K8SBINEOF
}

