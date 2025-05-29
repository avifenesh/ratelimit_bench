#!/bin/bash

# System Configuration Summary
# Shows current Podman/Docker configuration

echo "=== PODMAN CONFIGURATION SUMMARY ==="
echo

echo "1. Container Runtime:"
echo "   - Docker daemon: $(systemctl is-active docker 2>/dev/null || echo 'stopped/disabled')"
echo "   - Podman socket: $(systemctl --user is-active podman.socket 2>/dev/null || echo 'inactive')"
echo

echo "2. Command Wrappers:"
echo "   - docker command: $(which docker)"
echo "   - docker-compose command: $(which docker-compose)"
echo

echo "3. Version Information:"
docker --version
docker-compose --version
echo

echo "4. Environment Variables:"
echo "   - DOCKER_HOST: ${DOCKER_HOST:-'not set'}"
echo "   - CONTAINER_HOST: ${CONTAINER_HOST:-'not set'}"
echo

echo "5. Available Networks:"
podman network ls
echo

echo "6. Running Containers:"
podman ps -a
echo

echo "7. Images:"
podman images | head -10
echo

echo "=== CONFIGURATION STATUS ==="
if [[ "$(which docker)" == "/usr/local/bin/podman-wrappers/docker" ]]; then
    echo "✅ Docker wrapper correctly configured"
else
    echo "❌ Docker wrapper not properly configured"
fi

if [[ "$(which docker-compose)" == "/usr/local/bin/podman-wrappers/docker-compose" ]]; then
    echo "✅ Docker Compose wrapper correctly configured"
else
    echo "❌ Docker Compose wrapper not properly configured"
fi

if systemctl --user is-active --quiet podman.socket; then
    echo "✅ Podman socket is running"
else
    echo "❌ Podman socket is not running"
fi

if systemctl is-active --quiet docker 2>/dev/null; then
    echo "⚠️  Docker daemon is still running (should be stopped)"
else
    echo "✅ Docker daemon is stopped"
fi

echo
echo "=== READY FOR BENCHMARKING ==="
echo "The system is now configured to use Podman by default."
echo "You can run: ./scripts/run-all.sh to start a full benchmark."
