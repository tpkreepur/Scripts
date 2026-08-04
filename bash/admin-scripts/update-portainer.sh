#!/usr/bin/env bash

# Script to update the Portainer container and, if present, the Portainer agent.

set -euo pipefail

PORTAINER_CONTAINER_NAME="${PORTAINER_CONTAINER_NAME:-portainer}"
PORTAINER_AGENT_CONTAINER_NAME="${PORTAINER_AGENT_CONTAINER_NAME:-portainer_agent}"
PORTAINER_IMAGE="${PORTAINER_IMAGE:-portainer/portainer-ce:lts}"
PORTAINER_AGENT_IMAGE="${PORTAINER_AGENT_IMAGE:-portainer/agent:latest}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

usage() {
  cat <<EOF
Usage: $0 [--help]

Updates Portainer and, if present, the Portainer agent container.

Environment variables:
  PORTAINER_CONTAINER_NAME        Container name for Portainer (default: portainer)
  PORTAINER_AGENT_CONTAINER_NAME  Container name for agent (default: portainer_agent)
  PORTAINER_IMAGE                 Portainer image tag (default: portainer/portainer-ce:lts)
  PORTAINER_AGENT_IMAGE           Agent image tag (default: portainer/agent:latest)

Optional Edge agent environment variables (only used when set):
  EDGE
  EDGE_ID
  EDGE_KEY
  EDGE_INSECURE_POLL
EOF
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: Required command not found: $cmd"
    exit 1
  fi
}

container_exists() {
  local name="$1"
  [[ -n "$(docker ps -a --filter "name=^/${name}$" --format '{{.Names}}')" ]]
}

remove_container_if_exists() {
  local name="$1"

  if container_exists "$name"; then
    log "Stopping container: $name"
    docker stop "$name" >/dev/null
    log "Removing container: $name"
    docker rm "$name" >/dev/null
  fi
}

update_portainer() {
  log "Pulling Portainer image: $PORTAINER_IMAGE"
  docker pull "$PORTAINER_IMAGE"

  remove_container_if_exists "$PORTAINER_CONTAINER_NAME"

  log "Starting Portainer container: $PORTAINER_CONTAINER_NAME"
  docker run -d \
    -p 9000:9000 \
    --name "$PORTAINER_CONTAINER_NAME" \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    "$PORTAINER_IMAGE" >/dev/null
}

update_portainer_agent() {
  local -a edge_env_args=()

  if [[ "${EDGE:-}" == "1" ]]; then
    if [[ -z "${EDGE_ID:-}" || -z "${EDGE_KEY:-}" ]]; then
      log "ERROR: EDGE=1 requires EDGE_ID and EDGE_KEY"
      exit 1
    fi
  fi

  [[ -n "${EDGE:-}" ]] && edge_env_args+=("-e" "EDGE=${EDGE}")
  [[ -n "${EDGE_ID:-}" ]] && edge_env_args+=("-e" "EDGE_ID=${EDGE_ID}")
  [[ -n "${EDGE_KEY:-}" ]] && edge_env_args+=("-e" "EDGE_KEY=${EDGE_KEY}")
  [[ -n "${EDGE_INSECURE_POLL:-}" ]] && edge_env_args+=("-e" "EDGE_INSECURE_POLL=${EDGE_INSECURE_POLL}")

  log "Pulling Portainer agent image: $PORTAINER_AGENT_IMAGE"
  docker pull "$PORTAINER_AGENT_IMAGE"

  remove_container_if_exists "$PORTAINER_AGENT_CONTAINER_NAME"

  log "Starting Portainer agent container: $PORTAINER_AGENT_CONTAINER_NAME"
  docker run -d \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /var/lib/docker/volumes:/var/lib/docker/volumes \
    -v /:/host \
    -v portainer_agent_data:/data \
    --restart always \
    "${edge_env_args[@]}" \
    --name "$PORTAINER_AGENT_CONTAINER_NAME" \
    "$PORTAINER_AGENT_IMAGE" >/dev/null
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  require_command docker

  if ! docker info >/dev/null 2>&1; then
    log "ERROR: Docker daemon is not reachable"
    exit 1
  fi

  log "Updating Portainer container"
  update_portainer

  if container_exists "$PORTAINER_AGENT_CONTAINER_NAME"; then
    log "Updating Portainer agent container"
    update_portainer_agent
  else
    log "Portainer agent container not found; skipping agent update"
  fi

  log "Portainer update completed successfully"
}

main "$@"