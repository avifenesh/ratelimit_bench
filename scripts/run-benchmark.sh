#!/bin/bash

set -e

# --- Configuration ---

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR_HOST="$(pwd)/results/${TIMESTAMP}"
LOG_FILE="${RESULTS_DIR_HOST}/benchmark.log"
README_FILE="${RESULTS_DIR_HOST}/README.md"
SERVER_IMAGE_TAG="benchmark-server:latest"
LOADTEST_IMAGE_TAG="benchmark-loadtest:latest"
SERVER_CONTAINER_NAME="running-benchmark-server"
LOADTEST_CONTAINER_NAME="running-benchmark-loadtest"
DEFAULT_SERVER_PORT=3000
BENCHMARK_NETWORK="benchmark-network"

# Default configurations (unchanged)

DEFAULT_DURATION=30
DEFAULT_CONCURRENCY_LEVELS=(10 50 100 500 1000)
DEFAULT_REQUEST_TYPES=("light" "heavy")

# Define all possible types including cluster variations explicitly

DEFAULT_RATE_LIMITER_TYPES=("valkey-glide" "valkey-io" "ioredis" "valkey-glide:cluster" "valkey-io:cluster" "ioredis:cluster")

# Parse command line arguments (unchanged)

duration=${1:-$DEFAULT_DURATION}
concurrency_levels=(${2:-${DEFAULT_CONCURRENCY_LEVELS[@]}})
request_types=(${3:-${DEFAULT_REQUEST_TYPES[@]}})
rate_limiter_types=(${4:-${DEFAULT_RATE_LIMITER_TYPES[@]}})

# --- Helper Functions ---

log() {
echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

ensure_network() {
    log "Ensuring Docker network '$BENCHMARK_NETWORK' exists..."
    if ! docker network inspect "$BENCHMARK_NETWORK" >/dev/null 2>&1; then
        log "Creating Docker network '$BENCHMARK_NETWORK'..."
        docker network create "$BENCHMARK_NETWORK"
    else
        log "Network '$BENCHMARK_NETWORK' already exists."
    fi
}

cleanup_containers() {
    log "Cleaning up containers..."
    # Stop and remove server and loadtest containers if they exist
    docker stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker stop "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true

    # Stop and remove database containers using compose
    if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
        log "Stopping database containers defined in $CURRENT_COMPOSE_FILE..."
        docker-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
        CURRENT_COMPOSE_FILE="" # Reset compose file variable
    fi
    log "Cleanup complete."

}

run_server_container() {
  local rate_limiter=$1
  local cluster_env=$2
  local network_name=$3
  
  log "Starting server container ($SERVER_IMAGE_TAG)..."
  log "Using Docker network: $network_name"
  
  # Verify network exists
  if ! docker network inspect "$network_name" >/dev/null 2>&1; then
    log "ERROR: Network $network_name does not exist!"
    log "Available networks:"
    docker network ls
    log "An error occurred. Cleaning up..."
    cleanup_containers
    exit 1
  fi
  
  server_container_id=$(docker run -d \
    --name "$SERVER_CONTAINER_NAME" \
    --network "$network_name" \
    -p "$DEFAULT_SERVER_PORT:$DEFAULT_SERVER_PORT" \
    -e "MODE=$rate_limiter" \
    ${cluster_env} \
    -e "BENCHMARK=true" \
    -e "NODE_ENV=production" \
    "$SERVER_IMAGE_TAG")

  if [ $? -ne 0 ]; then
    log "An error occurred starting server container. Cleaning up..."
    cleanup_containers
    exit 1
  fi
  
  echo "$server_container_id"
}

# --- Initialization ---

# Create the results directory and log file *before* any logging happens
mkdir -p "$RESULTS_DIR_HOST"
touch "$LOG_FILE"

# Trap errors and ensure cleanup
trap 'log "An error occurred. Cleaning up..."; cleanup_containers; exit 1' ERR INT TERM

log "Initializing benchmark run..."

# Create README with testing methodology details

cat > "$README_FILE" << EOF

# Rate Limiter Benchmark Results (Dockerized)

## Test Summary

- **Date:** $(date)
- **Duration:** ${duration}s per test
- **Warmup Period:** 10s per test (not included in results)
- **Cooldown Period:** 5s between tests, 10s between rate limiter types
- **Concurrency Levels:** ${concurrency_levels[@]}
- **Request Types:** ${request_types[@]}
- **Rate Limiter Types:** ${rate_limiter_types[@]}

## System Information (Host)

- **Hostname:** $(hostname)
- **CPU:** $(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
- **CPU Cores:** $(grep -c processor /proc/cpuinfo)
- **Memory:** $(free -h | grep Mem | awk '{print $2}')
- **OS:** $(uname -srm)
- **Kernel:** $(uname -r)
- **Docker Version:** $(docker --version)

## Testing Methodology

Each benchmark test follows this procedure:
1. Start the server with the selected rate limiter implementation
2. Run a 10-second warmup phase to stabilize the system (results discarded)
3. Run the actual benchmark for the configured duration
4. Allow a 5-second cooldown period between different test configurations
5. Allow a 10-second cooldown period between different rate limiter types

## Results Summary

(Results will be summarized here after all tests complete)

EOF

log "Starting benchmark suite with:"
log "- Duration: ${duration}s per test"
log "- Warmup Period: 10s per test"
log "- Cooldown Periods: 5s between tests, 10s between rate limiter types"
log "- Concurrency levels: ${concurrency_levels[*]}"
log "- Request types: ${request_types[*]}"
log "- Rate limiter types: ${rate_limiter_types[*]}"
log "- Results will be saved to: ${RESULTS_DIR_HOST}"

# --- Build Docker Images ---

log "Building server Docker image ($SERVER_IMAGE_TAG)..."
docker build -t "$SERVER_IMAGE_TAG" -f Dockerfile.server .
log "Building loadtest Docker image ($LOADTEST_IMAGE_TAG)..."
docker build -t "$LOADTEST_IMAGE_TAG" -f Dockerfile.loadtest .

# --- Main Test Loop ---

CURRENT_COMPOSE_FILE="" # Track the currently active compose file

# Create network upfront
log "Creating Docker network for benchmarks..."
docker network create "$BENCHMARK_NETWORK" 2>/dev/null || log "Network $BENCHMARK_NETWORK already exists"

for rate_limiter_type in "${rate_limiter_types[@]}"; do
log "=== Testing rate limiter: $rate_limiter_type ==="

    # Determine database type and cluster mode
    db_type=$(echo "$rate_limiter_type" | cut -d':' -f1) # e.g., valkey-glide -> valkey
    if [[ "$db_type" == "valkey-glide" || "$db_type" == "valkey-io" ]]; then
        db_tech="valkey"
    elif [[ "$db_type" == "ioredis" ]]; then
        db_tech="redis"
    else
        log "ERROR: Unknown database type derived from $rate_limiter_type"
        exit 1
    fi

    use_cluster="false"
    if [[ "$rate_limiter_type" == *":cluster"* ]]; then
        use_cluster="true"
    fi

    # Select appropriate Docker Compose file
    if [[ "$use_cluster" == "true" ]]; then
        if [[ "$db_tech" == "redis" ]]; then
            CURRENT_COMPOSE_FILE="docker-compose-redis-cluster.yml"
        elif [[ "$db_tech" == "valkey" ]]; then
            CURRENT_COMPOSE_FILE="docker-compose-valkey-cluster.yml"
        fi
    else
        CURRENT_COMPOSE_FILE="docker-compose.yml"
    fi

    if [ ! -f "$CURRENT_COMPOSE_FILE" ]; then
        log "ERROR: Docker compose file $CURRENT_COMPOSE_FILE not found."
        exit 1
    fi

    # --- Start Database ---
    log "Starting database container(s) using $CURRENT_COMPOSE_FILE..."

    # Add network configuration to docker-compose command
    export COMPOSE_PROJECT_NAME="ratelimit_bench"
    export BENCHMARK_NETWORK_NAME="$BENCHMARK_NETWORK"
    
    # Add extra network config if it doesn't exist in compose files
    if ! grep -q "$BENCHMARK_NETWORK" "$CURRENT_COMPOSE_FILE"; then
        log "Adding $BENCHMARK_NETWORK to database containers..."
        # Use -p to set project name explicitly which affects network naming
        docker-compose -f "$CURRENT_COMPOSE_FILE" -p "ratelimit_bench" up -d --remove-orphans --force-recreate
        
        # Connect services to our benchmark network if needed
        if [[ "$use_cluster" == "true" ]]; then
            if [[ "$db_tech" == "redis" ]]; then
                for i in {1..6}; do
                    docker network connect "$BENCHMARK_NETWORK" "ratelimit_bench-redis-node$i-1" 2>/dev/null || true
                done
                docker network connect "$BENCHMARK_NETWORK" "ratelimit_bench-redis-cluster-setup-1" 2>/dev/null || true
            elif [[ "$db_tech" == "valkey" ]]; then
                for i in {1..6}; do
                    docker network connect "$BENCHMARK_NETWORK" "ratelimit_bench-valkey-node$i-1" 2>/dev/null || true
                done
                docker network connect "$BENCHMARK_NETWORK" "ratelimit_bench-valkey-cluster-setup-1" 2>/dev/null || true
            fi
        else
            # Connect standalone containers
            if [[ "$db_tech" == "redis" ]]; then
                docker network connect "$BENCHMARK_NETWORK" "ratelimit_bench-redis-1" 2>/dev/null || true
            elif [[ "$db_tech" == "valkey" ]]; then
                docker network connect "$BENCHMARK_NETWORK" "ratelimit_bench-valkey-1" 2>/dev/null || true
            fi
        fi
    else
        # Compose file already has network configuration
        docker-compose -f "$CURRENT_COMPOSE_FILE" -p "ratelimit_bench" up -d --remove-orphans --force-recreate
    fi
    
    log "Waiting for database container(s) to be ready..."
    # Simple sleep for now, replace with more robust health checks if needed
    sleep 15

    # --- Configure Server Environment ---
    server_env_vars=()
    server_env_vars+=(-e "NODE_ENV=production")
    server_env_vars+=(-e "PORT=${DEFAULT_SERVER_PORT}")
    server_env_vars+=(-e "MODE=${rate_limiter_type}") # Pass the full mode like 'valkey-glide:cluster'
    server_env_vars+=(-e "LOG_LEVEL=info")

    # Set DB connection details based on mode
    if [[ "$use_cluster" == "true" ]]; then
        server_env_vars+=(-e "USE_${db_tech^^}_CLUSTER=true") # USE_VALKEY_CLUSTER=true or USE_REDIS_CLUSTER=true
        if [[ "$db_tech" == "redis" ]]; then
            # Inside docker network, use service names and default ports
            server_env_vars+=(-e "REDIS_CLUSTER_NODES=redis-node1:6379,redis-node2:6379,redis-node3:6379,redis-node4:6379,redis-node5:6379,redis-node6:6379")
        elif [[ "$db_tech" == "valkey" ]]; then
             # Inside docker network, use service names and default ports
            server_env_vars+=(-e "VALKEY_CLUSTER_NODES=valkey-node1:8080,valkey-node2:8080,valkey-node3:8080,valkey-node4:8080,valkey-node5:8080,valkey-node6:8080")
        fi
    else
        # Standalone: Use service names from docker-compose.yml and default ports
        server_env_vars+=(-e "REDIS_HOST=redis" -e "REDIS_PORT=6379")
        server_env_vars+=(-e "VALKEY_HOST=valkey" -e "VALKEY_PORT=6379") # Valkey container listens on 6379 internally
    fi

    # --- Start Server Container ---
    log "Starting server container ($SERVER_IMAGE_TAG)..."
    docker run -d --name "$SERVER_CONTAINER_NAME" \
        --network="$BENCHMARK_NETWORK" \
        -p "${DEFAULT_SERVER_PORT}:${DEFAULT_SERVER_PORT}" \
        "${server_env_vars[@]}" \
        "$SERVER_IMAGE_TAG"

    log "Waiting for server container to be ready..."
    # Wait for the server to log that it's listening
    max_wait=60 # seconds
    interval=3  # seconds
    elapsed=0
    server_ready=false
    while [ $elapsed -lt $max_wait ]; do
        if docker logs "$SERVER_CONTAINER_NAME" 2>&1 | grep -q "Server listening on http://0.0.0.0:${DEFAULT_SERVER_PORT}"; then
            log "Server container is ready."
            server_ready=true
            break
        fi
        log "Waiting for server... attempt ($((elapsed / interval + 1)))"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [ "$server_ready" = false ]; then
        log "ERROR: Server container failed to start within $max_wait seconds."
        log "Server logs:"
        docker logs "$SERVER_CONTAINER_NAME" || true
        cleanup_containers
        exit 1
    fi

    # --- Run Benchmark Loop ---
    for req_type in "${request_types[@]}"; do
        for conn in "${concurrency_levels[@]}"; do
            test_id="${rate_limiter_type}_${req_type}_${conn}c_${duration}s"
            log_file_name="${RESULTS_DIR_HOST}/${test_id}.log"
            results_file_name="${RESULTS_DIR_HOST}/${test_id}.json" # Loadtest container writes here

            log "--- Running test: $test_id ---"
            log "Concurrency: $conn, Request Type: $req_type, Duration: ${duration}s"

            # Configure Loadtest Environment
            loadtest_env_vars=(
                -e "TARGET_URL=http://${SERVER_CONTAINER_NAME}:${DEFAULT_SERVER_PORT}" # Use container name for DNS resolution
                -e "DURATION=${duration}"
                -e "CONNECTIONS=${conn}"
                -e "REQUEST_TYPE=${req_type}"
                -e "OUTPUT_FILE=/app/results/${test_id}.json" # Path inside the container
                -e "RATE_LIMITER_TYPE=${rate_limiter_type}" # Pass for context if needed by loadtest script
            )

            # First run a warm-up phase
            log "Starting warmup phase (10s) for test: $test_id..."
            warmup_container_name="${LOADTEST_CONTAINER_NAME}_warmup"
            
            # Configure with shorter duration for warmup
            warmup_env_vars=("${loadtest_env_vars[@]}")
            # Replace DURATION with 10s for warmup
            for i in "${!warmup_env_vars[@]}"; do
                if [[ ${warmup_env_vars[$i]} == -e\ DURATION* ]]; then
                    warmup_env_vars[$i]="-e DURATION=10"
                    break
                fi
            done
            # Add flag to indicate this is warmup (can be used by loadtest script if needed)
            warmup_env_vars+=(-e "WARMUP=true")
            
            # Run warmup loadtest
            docker run --name "$warmup_container_name" \
                --network="$BENCHMARK_NETWORK" \
                "${warmup_env_vars[@]}" \
                "$LOADTEST_IMAGE_TAG" > /dev/null 2>&1 || true
                
            # Clean up warmup container regardless of result
            docker rm "$warmup_container_name" > /dev/null 2>&1 || true
            log "Warmup phase completed. Starting actual benchmark..."
            
            # Run the actual Loadtest Container
            log "Starting loadtest container ($LOADTEST_IMAGE_TAG)..."
            docker run --name "$LOADTEST_CONTAINER_NAME" \
                --network="$BENCHMARK_NETWORK" \
                -v "${RESULTS_DIR_HOST}:/app/results" \
                "${loadtest_env_vars[@]}" \
                "$LOADTEST_IMAGE_TAG" # Assumes CMD in Dockerfile.loadtest runs the benchmark

            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                log "ERROR: Loadtest container failed with exit code $exit_code."
                log "Loadtest logs:"
                docker logs "$LOADTEST_CONTAINER_NAME" || true
                # Optionally copy results even on failure if they exist
                # docker cp "${LOADTEST_CONTAINER_NAME}:/app/results/${test_id}.json" "$results_file_name" > /dev/null 2>&1 || true
            else
                log "Loadtest completed successfully for $test_id."
                # Results should be directly in RESULTS_DIR_HOST due to volume mount
                if [ -f "$results_file_name" ]; then
                    log "Results saved to $results_file_name"
                else
                    log "WARNING: Results file $results_file_name not found after loadtest."
                fi
            fi

            # Clean up loadtest container
            docker rm "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true

            log "--- Test finished: $test_id ---"
            sleep 5 # Cooldown period between tests
        done
    done

    # --- Stop Server and Database for this iteration ---
    log "Stopping server container..."
    docker stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1
    docker rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1

    log "Stopping database container(s) for $rate_limiter_type..."
    docker-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
    CURRENT_COMPOSE_FILE="" # Reset for next loop iteration

    log "=== Finished testing rate limiter: $rate_limiter_type ==="
    sleep 10 # Cooldown period between rate limiter types

done

# --- Final Cleanup ---

# cleanup_containers # Should be mostly clean already, but run just in case

log "Benchmark suite finished."
log "Results are stored in: ${RESULTS_DIR_HOST}"

# --- Generate Report (Optional) ---
if [ -f "scripts/generate-report.sh" ]; then
  log "Generating report..."
  ./scripts/generate-report.sh "$RESULTS_DIR_HOST"
fi

exit 0
