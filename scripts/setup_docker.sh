#!/usr/bin/env bash
# Install Docker Engine + Compose if missing, start the daemon, add this user
# to the docker group. Used by the main installer (including tar.gz extracts).
# Asks sudo; does not silent-sudo in --non-interactive unless --yes.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

install_packages() {
  have_cmd sudo || die "sudo is required to install Docker Engine"
  log_info "Installing docker.io and docker-compose-v2 (sudo password if prompted)"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin \
      || log_warn "docker compose plugin package not found; try: sudo apt-get install -y docker-compose-v2"
  fi
}

start_daemon() {
  if have_cmd systemctl; then
    sudo systemctl enable --now docker
    return 0
  fi
  if have_cmd service; then
    sudo service docker start
    return 0
  fi
  log_warn "Could not start the Docker daemon (no systemctl/service)"
  return 1
}

docker_ready() {
  medlock_docker info >/dev/null 2>&1
}

compose_ready() {
  medlock_docker compose version >/dev/null 2>&1
}

log_step "Docker"

if docker_ready && compose_ready; then
  log_ok "Docker Engine is running ($(docker --version 2>/dev/null | head -n 1))"
  exit 0
fi

if [[ "${MEDLOCK_OFFLINE:-0}" == "1" ]] && ! have_cmd docker; then
  log_warn "--offline: Docker CLI is missing and packages cannot be downloaded."
  exit 0
fi

if [[ "${MEDLOCK_NONINTERACTIVE:-0}" == "1" && "${MEDLOCK_YES:-0}" != "1" ]]; then
  log_warn "Docker is not ready. Re-run with --yes to install/start it with sudo."
  exit 0
fi

if ! have_cmd docker; then
  if [[ "${MEDLOCK_OFFLINE:-0}" == "1" ]]; then
    log_warn "--offline: not installing Docker packages."
    exit 0
  fi
  install_packages
fi

if ! docker_ready; then
  have_cmd sudo || die "sudo is required to start the Docker daemon"
  start_daemon || true
fi

if getent group docker >/dev/null 2>&1; then
  if ! in_docker_group && ! id -nG 2>/dev/null | grep -qw docker; then
    sudo usermod -aG docker "${USER}"
    log_info "Added ${USER} to the docker group (new terminals use it without sudo)"
  fi
fi

if ! compose_ready && [[ "${MEDLOCK_OFFLINE:-0}" != "1" ]]; then
  log_info "Installing Docker Compose plugin"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2 \
    || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin \
    || true
fi

if docker_ready; then
  if compose_ready; then
    log_ok "Docker Engine and Compose are ready"
  else
    log_warn "Docker is running but 'docker compose' is missing. Postgres may not start."
  fi
  exit 0
fi

log_warn "Docker daemon is not reachable yet. Postgres can still use a local server."
log_info "After a reboot, or: sudo systemctl enable --now docker"
exit 0
