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
DEFAULT_SERVER_PORT=3001
WARMUP_DURATION=10 
COOLDOWN_BETWEEN_TESTS=5
COOLDOWN_BETWEEN_TYPES=10

# Check if containers are already running (set by run-all.sh)
SKIP_CONTAINER_SETUP=${CONTAINERS_ALREADY_RUNNING:-false}

# Use provided network name if available
BENCHMARK_NETWORK=${BENCHMARK_NETWORK:-"benchmark-network"}

# Use provided results directory if available
if [ -n "$RESULTS_DIR_HOST" ]; then
  RESULTS_DIR_HOST_OVERRIDE="$RESULTS_DIR_HOST"
fi

DEFAULT_DURATION=30
# Remove 10 from the default list
DEFAULT_CONCURRENCY_LEVELS=(50 100 500 1000)
DEFAULT_REQUEST_TYPES=("light" "heavy")

# Define all possible types including cluster variations explicitly

DEFAULT_RATE_LIMITER_TYPES=("valkey-glide" "iovalkey" "ioredis" "valkey-glide:cluster" "iovalkey:cluster" "ioredis:cluster")

# Parse command line arguments (unchanged)

# Use environment variables if set, otherwise positional args, otherwise defaults
duration=${BENCHMARK_DURATION:-${1:-$DEFAULT_DURATION}}
concurrency_levels=(${2:-${DEFAULT_CONCURRENCY_LEVELS[@]}})
request_types_str=${BENCHMARK_REQUEST_TYPES:-${3:-"${DEFAULT_REQUEST_TYPES[*]}"}}
# Split the string into an array
read -r -a request_types <<< "$request_types_str"
rate_limiter_types=(${4:-${DEFAULT_RATE_LIMITER_TYPES[@]}})

# --- Helper Functions ---

log() {
echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_success() {
echo "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $1" | tee -a "$LOG_FILE"
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
    docker stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker stop "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true

    if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
        log "Stopping database containers defined in $CURRENT_COMPOSE_FILE..."
        docker-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
        CURRENT_COMPOSE_FILE=""
    fi
    log "Cleanup complete."

}

run_server_container() {
  local rate_limiter=$1
  local cluster_env=$2
  local network_name=$3
  
  log "Starting server container ($SERVER_IMAGE_TAG)..."
  log "Using Docker network: $network_name"
  
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
  
  local retries=5
  local connected=false
  local cli_command="valkey-cli"
  
  if [[ "$db_tech" == "redis" ]]; then
    cli_command="redis-cli"
  fi
  
  for ((i=1; i<=$retries; i++)); do
    if docker exec $container_name $cli_command -p $port PING 2>/dev/null | grep -q "PONG"; then
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
    get_actual_container_names() {
      local db_tech=$1
      
      if [[ "$db_tech" == "redis" ]]; then
        ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "redis|Redis" | grep -v -E "exporter|cluster-setup|node[1-6]" | head -1)
      elif [[ "$db_tech" == "valkey" ]]; then
        ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "valkey|Valkey" | grep -v -E "exporter|cluster-setup|node[1-6]" | head -1)
      fi
      
      if [[ -z "$ACTUAL_DB_CONTAINER" && "$db_tech" == "redis" ]]; then
        ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "redis-node1" | head -1)
      elif [[ -z "$ACTUAL_DB_CONTAINER" && "$db_tech" == "valkey" ]]; then
        ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "valkey-node1" | head -1)
      fi

      if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
        log "Detected actual database container name: $ACTUAL_DB_CONTAINER"
      else
        log "WARNING: Could not detect any $db_tech container!"
      fi
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

CURRENT_COMPOSE_FILE=""
if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
    log "Creating Docker network for benchmarks..."
    docker network create "$BENCHMARK_NETWORK" 2>/dev/null || log "Network $BENCHMARK_NETWORK already exists"
fi

for rate_limiter_type in "${rate_limiter_types[@]}"; do
log "=== Testing rate limiter: $rate_limiter_type ==="

    db_type=$(echo "$rate_limiter_type" | cut -d':' -f1)
    if [[ "$db_type" == "valkey-glide" || "$db_type" == "iovalkey" ]]; then
        db_tech="valkey"
    elif [[ "$db_type" == "ioredis" ]]; then
        db_tech="redis"
    else
        log "ERROR: Unknown database type derived from $rate_limiter_type"
        exit 1
    fi

    use_cluster="false"
    actual_rate_limiter_type="$db_type"
    if [[ "$rate_limiter_type" == *":cluster"* ]]; then
        use_cluster="true"
        log "Detected cluster mode for $db_type"
    fi

    get_actual_container_names "$db_tech"

    if [[ "$SKIP_CONTAINER_SETUP" == "true" ]]; then
        log "Using existing containers managed by run-all.sh"
        if [[ -z "$ACTUAL_DB_CONTAINER" ]]; then
            log "WARNING: Could not detect running $db_tech container. Make sure it was started by run-all.sh"
        else
            log "Found existing $db_tech container: $ACTUAL_DB_CONTAINER"
        fi
    else
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
        log "Starting database container(s) using $CURRENT_COMPOSE_FILE"

        # More descriptive name indicating this is a benchmark-managed project name
        BENCHMARK_MANAGED_PROJECT_NAME="ratelimit_bench_run_${TIMESTAMP}"
        export COMPOSE_PROJECT_NAME="$BENCHMARK_MANAGED_PROJECT_NAME"
        export BENCHMARK_NETWORK_NAME="$BENCHMARK_NETWORK"

        log "Using project name: $BENCHMARK_MANAGED_PROJECT_NAME"


        docker-compose -f "$CURRENT_COMPOSE_FILE" -p "$BENCHMARK_MANAGED_PROJECT_NAME" up -d --force-recreate

        get_actual_container_names "$db_tech"

        if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
             log "Connecting $ACTUAL_DB_CONTAINER to network $BENCHMARK_NETWORK..."
             docker network connect "$BENCHMARK_NETWORK" "$ACTUAL_DB_CONTAINER" 2>/dev/null || true
        else
             log "WARNING: Could not detect standalone container name after compose up to connect to network."
        fi

        log "Waiting for database container(s) to be ready..."

        if [[ "$use_cluster" == "true" ]]; then
            log "Waiting for cluster initialization (30s)..."
            sleep 30
        else
            max_db_wait=30
            db_ready=false
            db_container=""
            if [[ "$db_tech" == "redis" ]]; then
                db_port=6379
            elif [[ "$db_tech" == "valkey" ]]; then
                db_port=6379
            fi

            log "Checking database readiness..." 
            for ((i=1; i<=max_db_wait; i++)); do
                if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
                    cli_command="valkey-cli"
                    if [[ "$db_tech" == "redis" ]]; then
                        cli_command="redis-cli"
                    fi
                    
                    if docker exec "$ACTUAL_DB_CONTAINER" $cli_command -p "$db_port" PING 2>/dev/null | grep -q "PONG"; then
                        log "Database container $ACTUAL_DB_CONTAINER is ready!"
                        db_ready=true
                        break
                    fi
                else
                    log "WARNING: Cannot check readiness, container name not detected yet. Retrying detection..."
                    sleep 2 
                    get_actual_container_names "$db_tech" 
                    if [[ -z "$ACTUAL_DB_CONTAINER" ]]; then
                       log "Still cannot detect container name."
                       sleep 1 
                       continue
                    fi
                    
                    cli_command="valkey-cli"
                    if [[ "$db_tech" == "redis" ]]; then
                        cli_command="redis-cli"
                    fi
                    
                    if docker exec "$ACTUAL_DB_CONTAINER" $cli_command -p "$db_port" PING 2>/dev/null | grep -q "PONG"; then
                        log "Database container $ACTUAL_DB_CONTAINER is ready!"
                        db_ready=true
                        break
                    fi
                fi

                log "Waiting for database ($ACTUAL_DB_CONTAINER) to be ready... attempt ($i/$max_db_wait)"
                sleep 1
            done

            if [ "$db_ready" = false ]; then
                log "WARNING: Database ($ACTUAL_DB_CONTAINER) may not be fully ready after $max_db_wait attempts, but continuing..."
                log "Database container status:"
                docker ps | grep "$ACTUAL_DB_CONTAINER" || true
                if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
                    docker logs "$ACTUAL_DB_CONTAINER" | tail -20
                fi
            fi
        fi
    else
        log "Using existing database containers managed by run-all.sh"
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

    # --- Configure Server Environment Variables ---
    server_env_vars=()
    server_env_vars+=(-e "NODE_ENV=production")
    server_env_vars+=(-e "PORT=${DEFAULT_SERVER_PORT}")

    # Special handling for different client types
    case "$actual_rate_limiter_type" in
      "iovalkey")
        server_env_vars+=(-e "MODE=iovalkey")
        log "Setting MODE=iovalkey explicitly"
        
        if [[ "$use_cluster" == "true" ]]; then
          server_env_vars+=(-e "USE_VALKEY_CLUSTER=true")
          server_env_vars+=(-e "VALKEY_CLUSTER_NODES=${VALKEY_CLUSTER_NODES}")
          log "Setting cluster configuration for iovalkey client"
        else
          server_env_vars+=(-e "USE_VALKEY_CLUSTER=false")
          server_env_vars+=(-e "VALKEY_HOST=benchmark-valkey")
          server_env_vars+=(-e "VALKEY_PORT=6379")
          log "Setting standalone configuration for iovalkey client"
        fi
        ;;
        
      "valkey-glide")
        server_env_vars+=(-e "MODE=valkey-glide")
        
        if [[ "$use_cluster" == "true" ]]; then
          server_env_vars+=(-e "USE_VALKEY_CLUSTER=true")
          server_env_vars+=(-e "VALKEY_CLUSTER_NODES=${VALKEY_CLUSTER_NODES}")
        else
          server_env_vars+=(-e "USE_VALKEY_CLUSTER=false")
          server_env_vars+=(-e "VALKEY_HOST=benchmark-valkey")
          server_env_vars+=(-e "VALKEY_PORT=6379")
        fi
        ;;
        
      "ioredis")
        server_env_vars+=(-e "MODE=ioredis")
        
        if [[ "$use_cluster" == "true" ]]; then
          server_env_vars+=(-e "USE_REDIS_CLUSTER=true")
          server_env_vars+=(-e "REDIS_CLUSTER_NODES=${REDIS_CLUSTER_NODES}")
        else
          server_env_vars+=(-e "USE_REDIS_CLUSTER=false")
          server_env_vars+=(-e "REDIS_HOST=benchmark-redis")
          server_env_vars+=(-e "REDIS_PORT=6379")
        fi
        ;;
        
      *)
        server_env_vars+=(-e "MODE=valkey-glide")
        log "Unknown rate limiter type: $actual_rate_limiter_type, defaulting to valkey-glide"
        
        server_env_vars+=(-e "USE_VALKEY_CLUSTER=false")
        server_env_vars+=(-e "VALKEY_HOST=benchmark-valkey")
        server_env_vars+=(-e "VALKEY_PORT=6379")
        ;;
    esac

    # Add Debug logging only when needed
    if [[ "$DEBUG_MODE" == "true" ]]; then
      server_env_vars+=(-e "DEBUG=rate-limiter-flexible:*,@valkey/valkey-glide:*")
    fi

    log "Configuring server environment variables for $rate_limiter_type..."

    if [[ "$use_cluster" == "true" ]]; then
        log "Setting cluster environment variables..."
        server_env_vars+=(-e "USE_${db_tech^^}_CLUSTER=true")

        if [[ "$db_tech" == "redis" ]]; then
            REDIS_CLUSTER_NODES="redis-node1:6379,redis-node2:6379,redis-node3:6379,redis-node4:6379,redis-node5:6379,redis-node6:6379"
            server_env_vars+=(-e "REDIS_CLUSTER_NODES=${REDIS_CLUSTER_NODES}")
            log "REDIS_CLUSTER_NODES set to: ${REDIS_CLUSTER_NODES}"
        elif [[ "$db_tech" == "valkey" ]]; then
            PROJECT_PREFIX=${COMPOSE_PROJECT_NAME:-ratelimit_bench}
            VALKEY_CLUSTER_NODES="${PROJECT_PREFIX}-valkey-node1:8080,${PROJECT_PREFIX}-valkey-node2:8080,${PROJECT_PREFIX}-valkey-node3:8080,${PROJECT_PREFIX}-valkey-node4:8080,${PROJECT_PREFIX}-valkey-node5:8080,${PROJECT_PREFIX}-valkey-node6:8080"
            server_env_vars+=(-e "VALKEY_CLUSTER_NODES=${VALKEY_CLUSTER_NODES}")
            log "VALKEY_CLUSTER_NODES set to: ${VALKEY_CLUSTER_NODES}"
        fi
    else
        log "Setting standalone environment variables..."
        server_env_vars+=(-e "USE_${db_tech^^}_CLUSTER=false")


        if [[ "$db_tech" == "valkey" ]]; then
            server_env_vars+=(-e "VALKEY_HOST=benchmark-valkey")
            server_env_vars+=(-e "VALKEY_PORT=6379")
            log "VALKEY_HOST=benchmark-valkey, VALKEY_PORT=6379"
        elif [[ "$db_tech" == "redis" ]]; then
            server_env_vars+=(-e "REDIS_HOST=benchmark-redis")
            server_env_vars+=(-e "REDIS_PORT=6379")
            log "REDIS_HOST=benchmark-redis, REDIS_PORT=6379"
        fi
    fi

    # --- Start Server Container ---
    log "Starting server container ($SERVER_IMAGE_TAG) with calculated environment..."
    log "Network: $BENCHMARK_NETWORK"
    log "Env Vars: ${server_env_vars[@]}"

    docker stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true

    docker run -d --name "$SERVER_CONTAINER_NAME" \
        --network="$BENCHMARK_NETWORK" \
        -p "${DEFAULT_SERVER_PORT}:${DEFAULT_SERVER_PORT}" \
        "${server_env_vars[@]}" \
        "$SERVER_IMAGE_TAG"

    log "Waiting for server container to be ready..."
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
            if [[ "$use_cluster" == "false" && "$conn" -eq 1000 ]]; then
                log "Skipping concurrency level $conn for standalone mode."
                continue
            fi
            if [[ "$use_cluster" == "true" && "$conn" -eq 500 ]]; then
                log "Skipping concurrency level $conn for cluster mode."
                continue
            fi

            # --- Add loop for multiple runs ---
            for run_num in {1..3}; do
                # --- Calculate dynamic duration ---
                current_duration=$duration # Start with base duration
                if [[ "$conn" -le 100 ]]; then
                    current_duration=120 # 2 minutes for 50, 100 concurrency
                elif [[ "$conn" -ge 500 ]]; then
                    current_duration=180 # 3 minutes for 500, 1000 concurrency
                fi

                if [[ "$req_type" == "heavy" ]]; then
                    current_duration=$((current_duration + 30)) # Add 30s for heavy requests
                fi
                # --- End dynamic duration calculation ---

                # Create test_id with actual duration that will be used
                test_id="${rate_limiter_type}_${req_type}_${conn}c_${current_duration}s_run${run_num}" # Add run number and actual duration to ID
                # Define separate names for JSON results and container logs
                json_results_file="${RESULTS_DIR_HOST}/${test_id}.json"
                container_log_file="${RESULTS_DIR_HOST}/${test_id}.log"

                log "--- Running test: $test_id (Run ${run_num}/3) ---" # Update log message
                log "Concurrency: $conn, Request Type: $req_type, Actual Duration: ${current_duration}s (Warmup: ${WARMUP_DURATION}s)" # Log actual duration

                full_target_url="http://${SERVER_CONTAINER_NAME}:${DEFAULT_SERVER_PORT}/${req_type}"
                log "Target URL for loadtest: $full_target_url"

                # Use current_duration for the actual test run
                loadtest_env_vars=(
                    -e "TARGET_URL=${full_target_url}"
                    -e "DURATION=${current_duration}" # Use calculated duration
                    -e "CONNECTIONS=${conn}"
                    -e "REQUEST_TYPE=${req_type}"
                    -e "OUTPUT_FILE=/app/results/${test_id}.json" # Keep internal container path consistent
                    -e "RATE_LIMITER_TYPE=${rate_limiter_type}"
                )

                # --- Warmup Phase ---
                if [[ "$WARMUP_DURATION" -gt 0 ]]; then
                    # Use WARMUP_DURATION for the warmup run
                    warmup_env_vars=("${loadtest_env_vars[@]}") # Copy base vars
                    # Find and replace DURATION for warmup
                    duration_found=false
                    for i in "${!warmup_env_vars[@]}"; do
                        # Check if the current element is "-e" and the next element starts with "DURATION="
                        if [[ "${warmup_env_vars[$i]}" == "-e" && $i -lt $((${#warmup_env_vars[@]} - 1)) && "${warmup_env_vars[$((i+1))]}" == DURATION=* ]]; then
                            warmup_env_vars[$((i+1))]="DURATION=${WARMUP_DURATION}" # Update the value part only
                            duration_found=true
                            break
                        fi
                    done
                    # If DURATION wasn't in the original array (shouldn't happen, but safety check)
                    if ! $duration_found; then
                         # Add as separate elements if not found
                         warmup_env_vars+=("-e" "DURATION=${WARMUP_DURATION}")
                    fi
                    warmup_env_vars+=("-e" "WARMUP=true") # Mark as warmup

                    log "Starting warmup phase (${WARMUP_DURATION}s) for test: $test_id..." # Use constant WARMUP_DURATION
                    warmup_container_name="${LOADTEST_CONTAINER_NAME}_warmup_${run_num}" # Unique name per run

                    # Ensure expansion treats each element as a separate argument
                    docker run --name "$warmup_container_name" \
                        --network="$BENCHMARK_NETWORK" \
                        "${warmup_env_vars[@]}" \
                        "$LOADTEST_IMAGE_TAG" > /dev/null 2>&1

                    warmup_exit_code=$?
                    if [ $warmup_exit_code -ne 0 ]; then
                        log "ERROR: Warmup container failed with exit code $warmup_exit_code."
                        docker logs "$warmup_container_name" 2>/dev/null || log "Could not retrieve logs for failed warmup container."
                        docker rm "$warmup_container_name" > /dev/null 2>&1 || true
                        exit 1
                    fi

                    docker rm "$warmup_container_name" > /dev/null 2>&1 || true
                    log "Warmup phase completed. Starting actual benchmark..."
                else
                    log "Skipping warmup phase as WARMUP_DURATION is 0."
                fi
                # --- End Warmup Phase ---

                # --- Actual Benchmark Run ---
                log "Starting loadtest container ($LOADTEST_IMAGE_TAG) for run $run_num..." # Use run_num
                loadtest_container_name="${LOADTEST_CONTAINER_NAME}_run${run_num}" # Use run_num
                
                # Clean up any existing container with this name from previous benchmark runs
                docker rm -f "$loadtest_container_name" > /dev/null 2>&1 || true
                
                # Ensure expansion treats each element as a separate argument
                # Redirect stdout/stderr to the container log file
                docker run --name "$loadtest_container_name" \
                    --network="$BENCHMARK_NETWORK" \
                    "${loadtest_env_vars[@]}" \
                    "$LOADTEST_IMAGE_TAG" > "$container_log_file" 2>&1

                loadtest_exit_code=$?

                # Copy results from container regardless of exit code
                # Copy the JSON file generated inside the container to the host JSON results file
                docker cp "${loadtest_container_name}:/app/results/${test_id}.json" "$json_results_file" > /dev/null 2>&1 || log "WARNING: Could not copy results file ${test_id}.json from container ${loadtest_container_name}"

                if [ $loadtest_exit_code -ne 0 ]; then
                    log "ERROR: Loadtest container failed with exit code $loadtest_exit_code."
                    log "Loadtest container output saved to: $container_log_file" # Log the correct log file name
                    cat "$container_log_file" # Print the output for debugging
                    docker rm "$loadtest_container_name" > /dev/null 2>&1 || true
                    exit 1
                fi

                docker rm "$loadtest_container_name" > /dev/null 2>&1 || true
                log "--- Test run $run_num completed. Results saved to $json_results_file (log: $container_log_file) ---" # Log both file names

                # Cooldown between runs within the same configuration
                if [[ "$run_num" -lt 3 ]]; then
                    log "Cooldown period (${COOLDOWN_BETWEEN_TESTS}s) before next run..."
                    sleep "$COOLDOWN_BETWEEN_TESTS"
                fi
                # --- End Actual Benchmark Run ---

            done # End of the 3 runs loop

            # Cooldown between different test configurations (concurrency/request type)
            log "Cooldown period (${COOLDOWN_BETWEEN_TESTS}s) before next test configuration..."
            sleep "$COOLDOWN_BETWEEN_TESTS"

        done # End concurrency loop
    done # End request type loop

    # --- Cleanup after testing a specific rate limiter type ---
    log "Stopping server container..."
    docker stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    log "Server container stopped and removed."

    # --- Conditional Database Cleanup ---
    if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
        log "Stopping database container(s) for $rate_limiter_type (managed by run-benchmark.sh)..."
        if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
            docker-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
            log "Database containers from $CURRENT_COMPOSE_FILE stopped."
            CURRENT_COMPOSE_FILE="" # Reset compose file variable for the next iteration
        else
            log "No specific compose file was used for $rate_limiter_type, skipping database stop."
        fi
    else
        log "Skipping database container stop for $rate_limiter_type as they are managed externally (by run-all.sh)."
    fi

    if [[ "$rate_limiter_type" != "${rate_limiter_types[-1]}" ]]; then
        log "Cooldown period (${COOLDOWN_BETWEEN_TYPES}s) before next rate limiter type..."
        sleep "$COOLDOWN_BETWEEN_TYPES"
    fi

done

# --- Final Script Cleanup ---
cleanup_final() {
    log "Performing final cleanup..."
    docker stop "$SERVER_CONTAINER_NAME" "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$SERVER_CONTAINER_NAME" "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true

    if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
        if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
             log "Final shutdown of database containers using $CURRENT_COMPOSE_FILE..."
             docker-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
        fi
    fi
    log "Final cleanup complete."
}

trap cleanup_final EXIT ERR INT TERM

log_success "Benchmark suite finished successfully."
