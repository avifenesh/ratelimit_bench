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
WARMUP_DURATION=10 # Define warmup duration
COOLDOWN_BETWEEN_TESTS=5 # Define cooldown between individual tests
COOLDOWN_BETWEEN_TYPES=10 # Define cooldown between rate limiter types

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

DEFAULT_RATE_LIMITER_TYPES=("valkey-glide" "iovalkey" "ioredis" "valkey-glide:cluster" "iovalkey:cluster" "ioredis:cluster")

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
  local cli_command="valkey-cli"
  
  # Use correct CLI tool based on database technology
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
}    # Determine actual container names based on Docker PS output
    get_actual_container_names() {
      local db_tech=$1
      
      # For standalone mode
      if [[ "$db_tech" == "redis" ]]; then
        ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "redis|Redis" | grep -v -E "exporter|cluster-setup|node[1-6]" | head -1)
      elif [[ "$db_tech" == "valkey" ]]; then
        ACTUAL_DB_CONTAINER=$(docker ps --format "{{.Names}}" | grep -E "valkey|Valkey" | grep -v -E "exporter|cluster-setup|node[1-6]" | head -1)
      fi
      
      # If we didn't find standalone containers, use the first node in cluster mode
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
    if [[ "$db_type" == "valkey-glide" || "$db_type" == "iovalkey" ]]; then
        db_tech="valkey"
    elif [[ "$db_type" == "ioredis" ]]; then
        db_tech="redis"
    else
        log "ERROR: Unknown database type derived from $rate_limiter_type"
        exit 1
    fi

    use_cluster="false"
    actual_rate_limiter_type="$db_type" # Clean rate limiter type without cluster suffix
    if [[ "$rate_limiter_type" == *":cluster"* ]]; then
        use_cluster="true"
        log "Detected cluster mode for $db_type"
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
        log "Starting database container(s) using $CURRENT_COMPOSE_FILE (standalone mode)..."

        # Use a unique project name for standalone runs to avoid conflicts
        STANDALONE_PROJECT_NAME="ratelimit_bench_standalone_${TIMESTAMP}"
        export COMPOSE_PROJECT_NAME="$STANDALONE_PROJECT_NAME"
        export BENCHMARK_NETWORK_NAME="$BENCHMARK_NETWORK" # Still use the same network

        log "Using project name: $STANDALONE_PROJECT_NAME"

        # Remove --remove-orphans to prevent accidental removal of run-all.sh containers
        # Use --force-recreate to ensure fresh containers for the standalone test
        docker-compose -f "$CURRENT_COMPOSE_FILE" -p "$STANDALONE_PROJECT_NAME" up -d --force-recreate

        # Explicitly connect the standalone containers to the benchmark network
        # Need to get the actual container names *after* they are started
        get_actual_container_names "$db_tech" # Re-detect names after compose up

        if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
             log "Connecting $ACTUAL_DB_CONTAINER to network $BENCHMARK_NETWORK..."
             docker network connect "$BENCHMARK_NETWORK" "$ACTUAL_DB_CONTAINER" 2>/dev/null || true
        else
             log "WARNING: Could not detect standalone container name after compose up to connect to network."
        fi

        log "Waiting for database container(s) to be ready..."

        # More robust health checks for database containers
        if [[ "$use_cluster" == "true" ]]; then
            log "Waiting for cluster initialization (30s)..."
            sleep 30
        else
            max_db_wait=30
            db_ready=false
            db_container="" # This variable seems unused now, consider removing

            if [[ "$db_tech" == "redis" ]]; then
                # db_container="redis" # Unused
                db_port=6379
            elif [[ "$db_tech" == "valkey" ]]; then
                # db_container="valkey" # Unused
                db_port=6379
            fi

            log "Checking database readiness..." 
            for ((i=1; i<=max_db_wait; i++)); do
                # Use the *detected* container name for the check
                if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
                    # Determine CLI tool based on database technology
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
                    
                    # Determine CLI tool based on database technology
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
    server_env_vars+=(-e "MODE=${actual_rate_limiter_type}")  # Use clean mode name without cluster suffix
    server_env_vars+=(-e "LOG_LEVEL=info")
    server_env_vars+=(-e "DEBUG=rate-limiter-flexible:*,@valkey/valkey-glide:*")

    # Prioritize Valkey configurations for better performance
    if [[ "$db_tech" == "valkey" ]]; then
        server_env_vars+=(-e "VALKEY_COMMAND_TIMEOUT=3000")
        server_env_vars+=(-e "VALKEY_RECONNECT_STRATEGY=constant")
        server_env_vars+=(-e "VALKEY_RECONNECT_DELAY=100")
    fi

    # Important network fix: Make sure both server and DB containers are on the benchmark network
    log "Ensuring proper network connectivity between containers..."
    
    # Check actual standalone container name to use
    if [[ "$SKIP_CONTAINER_SETUP" == "true" ]]; then
        # When run from run-all.sh
        if [[ "$db_tech" == "valkey" ]]; then
            DB_CONTAINER_NAME="benchmark-valkey"
        else
            DB_CONTAINER_NAME="benchmark-redis"
        fi
    else
        # When run standalone, use the detected container name
        DB_CONTAINER_NAME="$ACTUAL_DB_CONTAINER"
    fi
    
    # Set DB connection details based on mode
    if [[ "$use_cluster" == "true" ]]; then
        server_env_vars+=(-e "USE_${db_tech^^}_CLUSTER=true") # USE_VALKEY_CLUSTER=true or USE_REDIS_CLUSTER=true
        
        # Detect actual container names for better reliability
        # Look for cluster node containers and their network information
        log "Detecting actual cluster node containers..."
        if [[ "$db_tech" == "redis" ]]; then
            # Get actual node container names with proper network prefix
            redis_node1=$(docker ps --format "{{.Names}}" | grep -E "redis-node1" | head -1)
            redis_node2=$(docker ps --format "{{.Names}}" | grep -E "redis-node2" | head -1)
            redis_node3=$(docker ps --format "{{.Names}}" | grep -E "redis-node3" | head -1)
            
            if [[ -n "$redis_node1" && -n "$redis_node2" && -n "$redis_node3" ]]; then
                log "Found Redis cluster nodes: $redis_node1, $redis_node2, $redis_node3"
                server_env_vars+=(-e "REDIS_CLUSTER_NODES=$redis_node1:6379,$redis_node2:6379,$redis_node3:6379")
            else
                # Fallback to default naming with multiple patterns for better compatibility
                log "Couldn't detect actual Redis cluster node names, using default patterns"
                server_env_vars+=(-e "REDIS_CLUSTER_NODES=ratelimit_bench-redis-node1-1:6379,ratelimit_bench-redis-node2-1:6379,ratelimit_bench-redis-node3-1:6379")
            fi
        elif [[ "$db_tech" == "valkey" ]]; then
            # Get actual node container names with proper network prefix
            valkey_node1=$(docker ps --format "{{.Names}}" | grep -E "valkey-node1" | head -1)
            valkey_node2=$(docker ps --format "{{.Names}}" | grep -E "valkey-node2" | head -1)
            valkey_node3=$(docker ps --format "{{.Names}}" | grep -E "valkey-node3" | head -1)
            
            # Ensure all cluster nodes are connected to the benchmark network
            log "Ensuring all Valkey cluster nodes are on the benchmark network..."
            
            # Connect all found nodes to benchmark network
            if [[ -n "$valkey_node1" ]]; then
                log "Connecting $valkey_node1 to benchmark network..."
                docker network connect "$BENCHMARK_NETWORK" "$valkey_node1" 2>/dev/null || true
            fi
            if [[ -n "$valkey_node2" ]]; then
                log "Connecting $valkey_node2 to benchmark network..."
                docker network connect "$BENCHMARK_NETWORK" "$valkey_node2" 2>/dev/null || true
            fi
            if [[ -n "$valkey_node3" ]]; then
                log "Connecting $valkey_node3 to benchmark network..."
                docker network connect "$BENCHMARK_NETWORK" "$valkey_node3" 2>/dev/null || true
            fi
            
            # Get IP addresses for more reliable connection, specifically from the benchmark network
            # Use a more specific Docker inspect template to get the correct IP
            valkey_node1_ip=""
            if [[ -n "$valkey_node1" ]]; then
                # First, try to get the IP from the benchmark network
                valkey_node1_ip=$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{if eq \$k \"$BENCHMARK_NETWORK\"}}{{\$v.IPAddress}}{{end}}{{end}}" "$valkey_node1" 2>/dev/null | tr -d '\n' || echo "")
                # If empty, try to get any network IP
                if [[ -z "$valkey_node1_ip" ]]; then
                    valkey_node1_ip=$(docker inspect "$valkey_node1" -f '{{range $net,$v := .NetworkSettings.Networks}}{{$v.IPAddress}} {{end}}' | awk '{print $1}' || echo "")
                fi
                log "Node1 ($valkey_node1) IP: $valkey_node1_ip"
            fi
            
            valkey_node2_ip=""
            if [[ -n "$valkey_node2" ]]; then
                valkey_node2_ip=$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{if eq \$k \"$BENCHMARK_NETWORK\"}}{{\$v.IPAddress}}{{end}}{{end}}" "$valkey_node2" 2>/dev/null | tr -d '\n' || echo "")
                if [[ -z "$valkey_node2_ip" ]]; then
                    valkey_node2_ip=$(docker inspect "$valkey_node2" -f '{{range $net,$v := .NetworkSettings.Networks}}{{$v.IPAddress}} {{end}}' | awk '{print $1}' || echo "")
                fi
                log "Node2 ($valkey_node2) IP: $valkey_node2_ip"
            fi
            
            valkey_node3_ip=""
            if [[ -n "$valkey_node3" ]]; then
                valkey_node3_ip=$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{if eq \$k \"$BENCHMARK_NETWORK\"}}{{\$v.IPAddress}}{{end}}{{end}}" "$valkey_node3" 2>/dev/null | tr -d '\n' || echo "")
                if [[ -z "$valkey_node3_ip" ]]; then
                    valkey_node3_ip=$(docker inspect "$valkey_node3" -f '{{range $net,$v := .NetworkSettings.Networks}}{{$v.IPAddress}} {{end}}' | awk '{print $1}' || echo "")
                fi
                log "Node3 ($valkey_node3) IP: $valkey_node3_ip"
            fi
            
            # Get the correct port for Valkey cluster nodes (8080 per docker-compose-valkey-cluster.yml)
            VALKEY_CLUSTER_PORT=8080
            
            # If we have IP addresses, use them for more reliable connection
            if [[ -n "$valkey_node1_ip" && -n "$valkey_node2_ip" && -n "$valkey_node3_ip" ]]; then
                log "Using IP addresses for Valkey cluster nodes with port $VALKEY_CLUSTER_PORT: $valkey_node1_ip, $valkey_node2_ip, $valkey_node3_ip"
                server_env_vars+=(-e "VALKEY_CLUSTER_NODES=$valkey_node1_ip:$VALKEY_CLUSTER_PORT,$valkey_node2_ip:$VALKEY_CLUSTER_PORT,$valkey_node3_ip:$VALKEY_CLUSTER_PORT")
                
                # Save the IP addresses for connectivity testing
                export VALKEY_NODE1_IP=$valkey_node1_ip
                export VALKEY_NODE2_IP=$valkey_node2_ip
                export VALKEY_NODE3_IP=$valkey_node3_ip
                export VALKEY_CLUSTER_PORT=$VALKEY_CLUSTER_PORT
            elif [[ -n "$valkey_node1" && -n "$valkey_node2" && -n "$valkey_node3" ]]; then
                log "Found Valkey cluster nodes with port $VALKEY_CLUSTER_PORT: $valkey_node1, $valkey_node2, $valkey_node3"
                server_env_vars+=(-e "VALKEY_CLUSTER_NODES=$valkey_node1:$VALKEY_CLUSTER_PORT,$valkey_node2:$VALKEY_CLUSTER_PORT,$valkey_node3:$VALKEY_CLUSTER_PORT")
            else
                # Fallback to default naming with multiple patterns for better compatibility
                log "Couldn't detect actual Valkey cluster node names, using default patterns with port $VALKEY_CLUSTER_PORT"
                server_env_vars+=(-e "VALKEY_CLUSTER_NODES=ratelimit_bench-valkey-node1-1:$VALKEY_CLUSTER_PORT,ratelimit_bench-valkey-node2-1:$VALKEY_CLUSTER_PORT,ratelimit_bench-valkey-node3-1:$VALKEY_CLUSTER_PORT")
            fi
            
            # Additional optimized settings for Valkey Glide cluster mode
            if [[ "$actual_rate_limiter_type" == "valkey-glide" ]]; then
                log "Configuring optimized Valkey Glide cluster settings"
                server_env_vars+=(-e "VALKEY_GLIDE_CLUSTER_MAX_REDIRECTIONS=16")
                server_env_vars+=(-e "VALKEY_GLIDE_DISABLE_OFFLOAD=true")
                server_env_vars+=(-e "VALKEY_GLIDE_DISABLE_LOGGING=true")
            fi
        fi
    else
        # For standalone mode, use consistent naming from run-all.sh
        if [[ "$SKIP_CONTAINER_SETUP" == "true" ]]; then
            if [[ "$db_tech" == "redis" ]]; then
                log "Using Redis container: benchmark-redis"
                server_env_vars+=(-e "REDIS_HOST=benchmark-redis" -e "REDIS_PORT=6379")
            elif [[ "$db_tech" == "valkey" ]]; then
                log "Using Valkey container: benchmark-valkey" 
                server_env_vars+=(-e "VALKEY_HOST=benchmark-valkey" -e "VALKEY_PORT=6379")
            fi
        else
            # Use the detected container name when running standalone
            if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
                if [[ "$db_tech" == "redis" ]]; then
                    log "Using detected Redis container: $ACTUAL_DB_CONTAINER"
                    server_env_vars+=(-e "REDIS_HOST=$ACTUAL_DB_CONTAINER" -e "REDIS_PORT=6379")
                elif [[ "$db_tech" == "valkey" ]]; then
                    log "Using detected Valkey container: $ACTUAL_DB_CONTAINER"
                    server_env_vars+=(-e "VALKEY_HOST=$ACTUAL_DB_CONTAINER" -e "VALKEY_PORT=6379")
                fi
            else
                # Fallback to simplified container names
                if [[ "$db_tech" == "redis" ]]; then
                    server_env_vars+=(-e "REDIS_HOST=benchmark-redis" -e "REDIS_PORT=6379")
                elif [[ "$db_tech" == "valkey" ]]; then 
                    server_env_vars+=(-e "VALKEY_HOST=benchmark-valkey" -e "VALKEY_PORT=6379")
                fi
            fi
        fi
    fi

    # --- Start Server Container ---
    log "Starting server container ($SERVER_IMAGE_TAG)..."
    
    # Validate network connectivity to cluster nodes first
    if [[ "$use_cluster" == "true" ]]; then
        log "Validating network connectivity to cluster nodes before starting server..."
        if [[ "$db_tech" == "valkey" ]]; then
            # Connect to each cluster node and check if it's reachable
            for node_idx in {1..3}; do
                node_var="valkey_node${node_idx}"
                node_ip_var="VALKEY_NODE${node_idx}_IP"
                
                node_name="${!node_var}"
                node_ip="${!node_ip_var}"
                
                if [[ -n "$node_name" ]]; then
                    log "Testing connectivity to $node_name (IP: ${node_ip:-unknown})..."
                    
                    # First try using the node's IP address if available
                    if [[ -n "$node_ip" ]]; then
                        if docker exec "$node_name" redis-cli -h "$node_ip" -p "$VALKEY_CLUSTER_PORT" PING 2>/dev/null | grep -q "PONG"; then
                            log "Successfully connected to $node_name via IP $node_ip:$VALKEY_CLUSTER_PORT"
                            
                            # Check cluster info via IP
                            if docker exec "$node_name" redis-cli -h "$node_ip" -p "$VALKEY_CLUSTER_PORT" CLUSTER INFO 2>/dev/null | grep -q "cluster_state:ok"; then
                                log "Cluster state is OK on $node_name (via IP $node_ip:$VALKEY_CLUSTER_PORT)"
                            else
                                log "WARNING: Cluster may not be fully initialized on $node_name (via IP $node_ip:$VALKEY_CLUSTER_PORT)"
                            fi
                            continue
                        else
                            log "WARNING: Could not connect to $node_name via IP $node_ip:$VALKEY_CLUSTER_PORT, trying direct container access..."
                        fi
                    fi
                    
                    # Try direct container access using the correct port
                    if docker exec "$node_name" redis-cli -p "$VALKEY_CLUSTER_PORT" PING 2>/dev/null | grep -q "PONG"; then
                        log "Successfully connected to $node_name via direct container access on port $VALKEY_CLUSTER_PORT"
                        
                        # Check cluster info
                        cluster_state=$(docker exec "$node_name" redis-cli -p "$VALKEY_CLUSTER_PORT" CLUSTER INFO 2>/dev/null)
                        if echo "$cluster_state" | grep -q "cluster_state:ok"; then
                            log "Cluster state is OK on $node_name"
                        else
                            log "WARNING: Cluster may not be fully initialized on $node_name"
                            docker exec "$node_name" redis-cli -p "$VALKEY_CLUSTER_PORT" CLUSTER INFO 2>/dev/null || true
                        fi
                    else
                        log "WARNING: Could not connect to $node_name on port $VALKEY_CLUSTER_PORT, cluster may not be fully formed yet"
                    fi
                fi
            done
            
            # Extra validation: check if nodes can see each other
            log "Validating inter-node connectivity..."
            if [[ -n "$valkey_node1" && -n "$VALKEY_NODE2_IP" ]]; then
                if docker exec "$valkey_node1" redis-cli -h "$VALKEY_NODE2_IP" -p 6379 PING 2>/dev/null | grep -q "PONG"; then
                    log "Node $valkey_node1 can successfully reach $valkey_node2 via IP $VALKEY_NODE2_IP"
                else
                    log "WARNING: Node $valkey_node1 cannot reach $valkey_node2, which may cause cluster issues"
                fi
            fi
        elif [[ "$db_tech" == "redis" ]]; then
            # Similar approach for Redis cluster nodes
            for node in $redis_node1 $redis_node2 $redis_node3; do
                if [[ -n "$node" ]]; then
                    log "Testing connectivity to $node..."
                    if docker exec "$node" redis-cli PING 2>/dev/null | grep -q "PONG"; then
                        log "Successfully connected to $node"
                        
                        # Check cluster info
                        cluster_state=$(docker exec "$node" redis-cli CLUSTER INFO 2>/dev/null)
                        if echo "$cluster_state" | grep -q "cluster_state:ok"; then
                            log "Cluster state is OK on $node"
                        else
                            log "WARNING: Cluster may not be fully initialized on $node"
                        fi
                    else
                        log "WARNING: Could not connect to $node, cluster may not be fully formed yet"
                    fi
                fi
            done
        fi
    fi
    
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

    # --- Cleanup after testing a specific rate limiter type ---
    log "Stopping server container..."
    docker stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    log "Server container stopped and removed."

    # --- Conditional Database Cleanup ---
    # Only stop database containers if this script started them (i.e., not run via run-all.sh)
    if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
        log "Stopping database container(s) for $rate_limiter_type (managed by run-benchmark.sh)..."
        if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
            # Use docker-compose down to stop and remove containers defined in the specific compose file
            docker-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
            log "Database containers from $CURRENT_COMPOSE_FILE stopped."
            CURRENT_COMPOSE_FILE="" # Reset compose file variable for the next iteration
        else
            log "No specific compose file was used for $rate_limiter_type, skipping database stop."
        fi
    else
        # Add explicit logging for clarity when skipping
        log "Skipping database container stop for $rate_limiter_type as they are managed externally (by run-all.sh)."
    fi

    # Cooldown period between rate limiter types
    if [[ "$rate_limiter_type" != "${rate_limiter_types[-1]}" ]]; then
        log "Cooldown period (${COOLDOWN_BETWEEN_TYPES}s) before next rate limiter type..."
        sleep "$COOLDOWN_BETWEEN_TYPES" # Now this variable is defined
    fi

done # End of the main loop iterating through rate_limiter_types

# --- Final Script Cleanup ---
# This cleanup runs once after the entire script finishes or on error/interrupt
cleanup_final() {
    log "Performing final cleanup..."
    # Ensure server/loadtest containers specific to this script are gone
    docker stop "$SERVER_CONTAINER_NAME" "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true
    docker rm "$SERVER_CONTAINER_NAME" "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true

    # Only perform docker-compose down if NOT managed by run-all.sh
    if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
        if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then # Check if a compose file was active
             log "Final shutdown of database containers using $CURRENT_COMPOSE_FILE..."
             docker-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
        fi
        # Optionally, remove the network if this script created it
        # docker network rm "$BENCHMARK_NETWORK" 2>/dev/null || true
    fi
    log "Final cleanup complete."
}

# Register the final cleanup function for exit, error, interrupt, termination
trap cleanup_final EXIT ERR INT TERM

log_success "Benchmark suite finished successfully."
