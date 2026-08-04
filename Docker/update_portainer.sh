#!/bin/bash

# ==============================================================================
# Script Name: update_portainer.sh
# Description: Updates Portainer CE to the latest LTS version following 
#              official Portainer documentation and best practices.
# ==============================================================================

# 1. Variables - Change these if you use custom naming or ports
CONTAINER_NAME="portainer"
IMAGE_TAG="portainer/portainer-ce:lts"
HTTPS_PORT="9443"
HTTP_PORT="9000"
EDGE_PORT="8000"
DATA_VOLUME="portainer_data"

# Check for root/sudo privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo."
   exit 1
fi

echo "--- Starting Portainer Update Process ---"

# 2. Pre-update: Pull the latest image
echo "[1/4] Pulling the latest Portainer image ($IMAGE_TAG)..."
docker pull $IMAGE_TAG

# 3. Stop and Remove the existing container
if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
    echo "[2/4] Stopping and removing current $CONTAINER_NAME container..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
else
    echo "[!] No existing container named $CONTAINER_NAME found. Skipping removal."
fi

# 4. Deploy the updated container
echo "[3/4] Deploying updated Portainer container..."
# Best Practice: Using 'unless-stopped' and mounting the Docker socket
docker run -d \
  -p "$EDGE_PORT:8000" \
  -p "$HTTPS_PORT:9443" \
  -p "$HTTP_PORT:9000" \
  --name "$CONTAINER_NAME" \
  --restart always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$DATA_VOLUME":/data \
  $IMAGE_TAG

# 5. Cleanup
echo "[4/4] Cleaning up old images..."
docker image prune -f

echo "--- Update Complete! ---"
echo "Access Portainer at: https://localhost:$HTTPS_PORT or http://localhost:$HTTP_PORT"
