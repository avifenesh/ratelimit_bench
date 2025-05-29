#!/bin/bash

# Podman Environment Setup Script
# This script ensures Podman is properly configured and running

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Setting up Podman environment..."

# Ensure Podman socket is running
if ! systemctl --user is-active --quiet podman.socket; then
    log "Starting Podman socket..."
    systemctl --user start podman.socket
fi

# Set environment variables for Docker compatibility
export DOCKER_HOST="unix:///run/user/$UID/podman/podman.sock"
export CONTAINER_HOST="$DOCKER_HOST"

# Add to current session
echo "export DOCKER_HOST=\"unix:///run/user/$UID/podman/podman.sock\"" >> ~/.bashrc
echo "export CONTAINER_HOST=\"\$DOCKER_HOST\"" >> ~/.bashrc
echo "export PATH=\"/usr/local/bin/podman-wrappers:\$PATH\"" >> ~/.bashrc

# Check if Podman is working
if podman version >/dev/null 2>&1; then
    log "Podman is working correctly"
    podman version --format "Podman version: {{.Client.Version}}"
else
    log "ERROR: Podman is not working correctly"
    exit 1
fi

# Check if podman-compose is working
if podman-compose --version >/dev/null 2>&1; then
    log "podman-compose is working correctly"
    podman-compose --version
else
    log "ERROR: podman-compose is not working correctly"
    exit 1
fi

# Verify wrapper scripts
if command -v docker >/dev/null 2>&1; then
    docker_path=$(which docker)
    if [[ "$docker_path" == "/usr/local/bin/podman-wrappers/docker" ]]; then
        log "Docker wrapper is correctly configured"
        docker --version
    else
        log "WARNING: Docker wrapper may not be correctly configured"
        log "Current docker path: $docker_path"
    fi
else
    log "ERROR: Docker wrapper not found"
    exit 1
fi

log "Podman environment setup complete!"
log "You can now use 'docker' and 'docker-compose' commands which will use Podman backend"
