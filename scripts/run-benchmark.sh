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

# Check if containers are already running (set by run-all.sh)
SKIP_CONTAINER_SETUP=${CONTAINERS_ALREADY_RUNNING:-false}

# Use provided network name if available
BENCHMARK_NETWORK=${BENCHMARK_NETWORK:-"benchmark-network"}

# Use provided results directory if available
if [ -n "$RESULTS_DIR_HOST" ]; then
  RESULTS_DIR_HOST_OVERRIDE="$RESULTS_DIR_HOST"
fi

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

verify_database_connection() {
  local db_tech=$1
  local container_name=$2
  local port=$3
  
  log "Verifying database connection to $container_name:$port..."
  
  # Test if we can connect to the database directly
  local retries=5
  local connected=false
  
  for ((i=1; i<=$retries; i++)); do
    if docker exec $container_name redis-cli -p $port PING 2>/dev/null | grep -q "PONG"; then
      log "Successfully connected to $db_tech at $container_name:$port"
      connected=true
      break
    fi
    log "Connection attempt $i/$retries to $container_name:$port failed, retrying..."
    sleep 2
  done
  
  if [ "$connected" = false ]; then
    log "WARNING: Could not connect to $db_tech at $container_name:$port"
    log "Database container logs:"
    docker logs $container_name | tail -20
    return 1
  fi
  
  return 0
}

# Determine actual container names based on Docker PS output
get_actual_container_names() {
  local db_tech=$1
  
  # For standalone mode
  if [[ "$db_tech" == "redis" ]]; then
    ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep "redis" | grep -v "exporter" | head -1)
  elif [[ "$db_tech" == "valkey" ]]; then
    ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep "valkey" | grep -v "exporter" | head -1)
  fi
  
  log "Detected actual database container name: $ACTUAL_DB_CONTAINER"
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

# Create network upfront (unless already created by run-all.sh)
if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
    log "Creating Docker network for benchmarks..."
    docker network create "$BENCHMARK_NETWORK" 2>/dev/null || log "Network $BENCHMARK_NETWORK already exists"
fi

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

    # Get actual running container names for connections
    get_actual_container_names "$db_tech"

    # If containers are already running (called from run-all.sh), skip database setup
    if [[ "$SKIP_CONTAINER_SETUP" == "true" ]]; then
        log "Using existing containers managed by run-all.sh"
        # Verify the containers exist and are accessible
        if [[ -z "$ACTUAL_DB_CONTAINER" ]]; then
            log "WARNING: Could not detect running $db_tech container. Make sure it was started by run-all.sh"
        else
            log "Found existing $db_tech container: $ACTUAL_DB_CONTAINER"
        fi
    else
        # Select appropriate Docker Compose file for setting up our own containers
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
    fi

    # --- Start Database (only if not using pre-existing containers) ---
    if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
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
        
        # More robust health checks for database containers
        if [[ "$use_cluster" == "true" ]]; then
            log "Waiting for cluster initialization (30s)..."
            sleep 30
        else
            max_db_wait=30
            db_ready=false
            db_container=""
            
            if [[ "$db_tech" == "redis" ]]; then
                db_container="redis"
                db_port=6379
            elif [[ "$db_tech" == "valkey" ]]; then
                db_container="valkey"
                db_port=6379
            fi
            
            log "Checking if $db_container is ready..."
            for ((i=1; i<=max_db_wait; i++)); do
                if docker exec ratelimit_bench-$db_container-1 redis-cli -p $db_port PING 2>/dev/null | grep -q "PONG"; then
                    log "Database container $db_container is ready!"
                    db_ready=true
                    break
                fi
                log "Waiting for database to be ready... attempt ($i/$max_db_wait)"
                sleep 1
            done
            
            if [ "$db_ready" = false ]; then
                log "WARNING: Database may not be fully ready, but continuing..."
                log "Database container status:"
                docker ps | grep $db_container || true
                docker logs ratelimit_bench-$db_container-1 | tail -20
            fi
        fi
    else
        log "Using existing database containers managed by run-all.sh"
        # When using existing containers, we should still try to verify connectivity
        if [[ "$use_cluster" == "true" ]]; then
            log "Using existing cluster configuration"
        else
            if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
                log "Verifying connection to $ACTUAL_DB_CONTAINER"
                if docker exec "$ACTUAL_DB_CONTAINER" redis-cli PING 2>/dev/null | grep -q "PONG"; then
                    log "Successfully verified connection to $ACTUAL_DB_CONTAINER"
                else
                    log "WARNING: Could not verify connection to $ACTUAL_DB_CONTAINER"
                fi
            fi
        fi
    fi

    # --- Configure Server Environment ---
    server_env_vars=()
    server_env_vars+=(-e "NODE_ENV=production")
    server_env_vars+=(-e "PORT=${DEFAULT_SERVER_PORT}")
    server_env_vars+=(-e "MODE=${rate_limiter_type}")
    server_env_vars+=(-e "LOG_LEVEL=info")
    server_env_vars+=(-e "DEBUG=rate-limiter-flexible:*,@valkey/valkey-glide:*")

    # Prioritize Valkey configurations for better performance
    if [[ "$db_tech" == "valkey" ]]; then
        server_env_vars+=(-e "VALKEY_COMMAND_TIMEOUT=3000")
        server_env_vars+=(-e "VALKEY_RECONNECT_STRATEGY=constant")
        server_env_vars+=(-e "VALKEY_RECONNECT_DELAY=100")
    fi

    # Set DB connection details based on mode
    if [[ "$use_cluster" == "true" ]]; then
        server_env_vars+=(-e "USE_${db_tech^^}_CLUSTER=true") # USE_VALKEY_CLUSTER=true or USE_REDIS_CLUSTER=true
        
        if [[ "$SKIP_CONTAINER_SETUP" == "true" ]]; then
            # Using containers managed by run-all.sh
            if [[ "$db_tech" == "redis" ]]; then
                server_env_vars+=(-e "REDIS_CLUSTER_NODES=benchmark-redis-cluster:6379")
            elif [[ "$db_tech" == "valkey" ]]; then
                server_env_vars+=(-e "VALKEY_CLUSTER_NODES=benchmark-valkey-cluster:6379")
            fi
        else
            # Using containers managed by run-benchmark.sh
            if [[ "$db_tech" == "redis" ]]; then
                server_env_vars+=(-e "REDIS_CLUSTER_NODES=ratelimit_bench-redis-node1-1:6379,ratelimit_bench-redis-node2-1:6379,ratelimit_bench-redis-node3-1:6379,ratelimit_bench-redis-node4-1:6379,ratelimit_bench-redis-node5-1:6379,ratelimit_bench-redis-node6-1:6379")
            elif [[ "$db_tech" == "valkey" ]]; then
                server_env_vars+=(-e "VALKEY_CLUSTER_NODES=ratelimit_bench-valkey-node1-1:6379,ratelimit_bench-valkey-node2-1:6379,ratelimit_bench-valkey-node3-1:6379,ratelimit_bench-valkey-node4-1:6379,ratelimit_bench-valkey-node5-1:6379,ratelimit_bench-valkey-node6-1:6379")
            fi
        fi
    else
        # For standalone mode
        if [[ "$SKIP_CONTAINER_SETUP" == "true" ]]; then
            # Using containers managed by run-all.sh
            if [[ "$db_tech" == "redis" ]]; then
                server_env_vars+=(-e "REDIS_HOST=benchmark-redis" -e "REDIS_PORT=6379")
            elif [[ "$db_tech" == "valkey" ]]; then
                server_env_vars+=(-e "VALKEY_HOST=benchmark-valkey" -e "VALKEY_PORT=6379")
            fi
        else
            # For our own containers, use detected names if available
            if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
                if [[ "$db_tech" == "redis" ]]; then
                    log "Using detected Redis container: $ACTUAL_DB_CONTAINER"
                    server_env_vars+=(-e "REDIS_HOST=$ACTUAL_DB_CONTAINER" -e "REDIS_PORT=6379")
                elif [[ "$db_tech" == "valkey" ]]; then
                    log "Using detected Valkey container: $ACTUAL_DB_CONTAINER"
                    server_env_vars+=(-e "VALKEY_HOST=$ACTUAL_DB_CONTAINER" -e "VALKEY_PORT=6379")
                fi
            else
                # Fallback to standard naming if detection failed
                if [[ "$db_tech" == "redis" ]]; then
                    server_env_vars+=(-e "REDIS_HOST=ratelimit_bench-redis-1" -e "REDIS_PORT=6379")
                elif [[ "$db_tech" == "valkey" ]]; then 
                    server_env_vars+=(-e "VALKEY_HOST=ratelimit_bench-valkey-1" -e "VALKEY_PORT=6379")
                fi
            fi
        fi
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
    max_wait=120
    interval=3
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
        
        # Enhanced diagnostics - inspect networking issues
        log "Server container logs:"
        docker logs "$SERVER_CONTAINER_NAME" || true
        
        log "Network information:"
        docker network inspect "$BENCHMARK_NETWORK" || true
        
        log "Database connection information:"
        if [[ "$use_cluster" == "true" ]]; then
            log "Trying to ping cluster nodes..."
            if [[ "$db_tech" == "redis" ]]; then
                for i in {1..6}; do
                    docker exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-redis-node$i-1" || true
                done
            elif [[ "$db_tech" == "valkey" ]]; then
                for i in {1..6}; do
                    docker exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-valkey-node$i-1" || true
                done
            fi
        else
            # For standalone
            if [[ "$db_tech" == "redis" ]]; then
                log "Trying to ping Redis container..."
                docker exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-redis-1" || true
            elif [[ "$db_tech" == "valkey" ]]; then
                log "Trying to ping Valkey container..."
                docker exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-valkey-1" || true
            fi
        fi
        
        cleanup_containers
        exit 1
    fi

    # --- Run Benchmark Loop ---
    for req_type in "${request_types[@]}"; do
        for conn in "${concurrency_levels[@]}"; do
            test_id="${rate_limiter_type}_${req_type}_${conn}c_${duration}s"
            log_file_name="${RESULTS_DIR_HOST}/${test_id}.log"
            results_file_name="${RESULTS_DIR_HOST}/${test_id}.json"
            log "--- Running test: $test_id ---"
            log "Concurrency: $conn, Request Type: $req_type, Duration: ${duration}s"

            # Configure Loadtest Environment
            loadtest_env_vars=(
                -e "TARGET_URL=http://${SERVER_CONTAINER_NAME}:${DEFAULT_SERVER_PORT}"
                -e "DURATION=${duration}"
                -e "CONNECTIONS=${conn}"
                -e "REQUEST_TYPE=${req_type}"
                -e "OUTPUT_FILE=/app/results/${test_id}.json" 
                -e "RATE_LIMITER_TYPE=${rate_limiter_type}"
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
                "$LOADTEST_IMAGE_TAG"

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
