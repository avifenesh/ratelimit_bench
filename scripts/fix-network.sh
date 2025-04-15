#!/bin/bash

set -e

echo "=== Docker Network Debug Utility ==="

# Get list of networks
echo "Available Docker networks:"
docker network ls

# Get the correct network name - this should match what docker-compose creates
network_name="ratelimit_bench_benchmark_network"
echo "Using network: $network_name"

# Clean up any existing containers to avoid conflicts
echo "Cleaning up existing containers..."
docker rm -f benchmark-server benchmark-loadtest 2>/dev/null || true

# Make sure the network exists
if ! docker network inspect $network_name >/dev/null 2>&1; then
    echo "Network $network_name does not exist. Creating it..."
    docker network create $network_name
fi

# Start Valkey standalone for testing
echo "Starting Valkey container..."
docker run -d --name benchmark-valkey --network $network_name -p 6379:6379 valkey/valkey:latest

# Wait for Valkey to be ready
echo "Waiting for Valkey to be ready..."
sleep 5

# Run the server with the correct network
echo "Starting server container..."
docker run -d --name benchmark-server \
    --network $network_name \
    -p 3001:3001 \
    -e "MODE=valkey-glide" \
    -e "VALKEY_HOST=benchmark-valkey" \
    -e "VALKEY_PORT=6379" \
    -e "BENCHMARK=true" \
    -e "NODE_ENV=production" \
    benchmark-server:latest

# Verify server started properly
echo "Checking server status..."
sleep 5
docker logs benchmark-server

# Run a simple loadtest as a test
echo "Running test loadtest..."
docker run --rm \
    --name benchmark-loadtest \
    --network $network_name \
    -e "SERVER_HOST=benchmark-server" \
    -e "SERVER_PORT=3001" \
    -e "DURATION=5" \
    -e "CONCURRENCY=10" \
    -e "SCENARIO=light" \
    -e "RATE_LIMITER=valkey-glide" \
    benchmark-loadtest:latest

echo "=== Network test complete ==="
echo "To clean up, run: docker rm -f benchmark-server benchmark-valkey"
