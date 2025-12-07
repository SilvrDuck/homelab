#!/usr/bin/env bash
set -euo pipefail

# We pin containerd.io because newer 2.x versions fail inside unprivileged Proxmox LXC
# (they try to set net.ipv4.ip_unprivileged_port_start and hit permission denied),
# which prevents all containers from starting. 1.7.28-1 is known to work.
TARGET_CONTAINERD_VERSION="1.7.28-1~ubuntu.22.04~jammy"

# Re-exec as root if needed
if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

echo "[setup_docker] Ensuring docker group and user membership"

# 1. Ensure docker group exists
if ! getent group docker >/dev/null 2>&1; then
  groupadd docker
fi

# 2. Ensure invoking user is in docker group (if any)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  if ! id -nG "${SUDO_USER}" | grep -qw docker; then
    usermod -aG docker "${SUDO_USER}"
    echo "[setup_docker] Added ${SUDO_USER} to docker group (log out/in to take effect)"
  fi
fi

echo "[setup_docker] Installing prerequisites and Docker APT repo"

# 3. Basic deps
apt-get update
apt-get install -y ca-certificates curl

# 4. Docker APT keyring (idempotent)
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

# 5. Docker APT source (idempotent overwrite)
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF

apt-get update

echo "[setup_docker] Installing Docker + pinned containerd.io (${TARGET_CONTAINERD_VERSION})"

# 6. Install docker packages and specific containerd.io version
apt-get install -y --allow-downgrades \
  docker-ce \
  docker-ce-cli \
  docker-buildx-plugin \
  docker-compose-plugin \
  "containerd.io=${TARGET_CONTAINERD_VERSION}"

# 7. Hold containerd.io so it doesn’t get upgraded back to 2.x
apt-mark hold containerd.io

echo "[setup_docker] Configuring Docker daemon DNS"

# 8. Configure Docker DNS (idempotent overwrite)
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "dns": ["1.1.1.1", "8.8.8.8"]
}
EOF

echo "[setup_docker] Restarting containerd and docker"

# 9. Restart services to apply everything
systemctl restart containerd
systemctl restart docker

echo "[setup_docker] Docker setup complete"
