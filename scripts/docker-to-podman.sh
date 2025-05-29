#!/bin/bash

# Docker to Podman compatibility wrapper
# This script provides Docker command compatibility using Podman

# Enable Podman socket if not running
if ! systemctl --user is-active --quiet podman.socket; then
    systemctl --user start podman.socket 2>/dev/null || true
fi

# Map Docker commands to Podman equivalents
case "$1" in
    "compose"|"-compose")
        # Use podman-compose for docker-compose commands
        shift
        if command -v podman-compose >/dev/null 2>&1; then
            exec podman-compose "$@"
        else
            echo "Error: podman-compose not found. Installing..."
            pip3 install podman-compose 2>/dev/null || {
                echo "Failed to install podman-compose. Using podman directly..."
                echo "Note: Some compose features may not work correctly"
                exec podman "$@"
            }
            exec podman-compose "$@"
        fi
        ;;
    "build")
        # Handle docker build
        exec podman build "$@"
        ;;
    "run")
        # Handle docker run - ensure compatibility with restart policies
        args=()
        restart_policy=""
        i=1
        while [ $i -le $# ]; do
            case "${!i}" in
                --restart=*)
                    restart_policy="${!i}"
                    args+=("${!i}")
                    ;;
                --restart)
                    i=$((i+1))
                    restart_policy="--restart=${!i}"
                    args+=("--restart" "${!i}")
                    ;;
                *)
                    args+=("${!i}")
                    ;;
            esac
            i=$((i+1))
        done
        exec podman run "${args[@]}"
        ;;
    "ps"|"images"|"pull"|"push"|"exec"|"logs"|"stop"|"start"|"rm"|"rmi"|"network"|"volume"|"inspect"|"cp")
        # Pass through common commands directly
        exec podman "$@"
        ;;
    "--version"|"version")
        # Show Podman version but mention Docker compatibility
        echo "Docker compatibility mode using Podman"
        exec podman version
        ;;
    *)
        # For all other commands, try podman directly
        exec podman "$@"
        ;;
esac
