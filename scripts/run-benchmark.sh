#!/bin/bash

set -e

# --- Configuration ---

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR_HOST="$(pwd)/results/${TIMESTAMP}"
LOG_FILE="${RESULTS_DIR_HOST}/benchmark.log"
README_FILE="${RESULTS_DIR_HOST}/README.md"

# Ensure results directory exists immediately
mkdir -p "$RESULTS_DIR_HOST"
touch "$LOG_FILE"

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

# --- Helper Functions ---

show_help() {
    cat << EOF
Usage: \$0 [OPTIONS]

DESCRIPTION:
    Runs rate limiter benchmarks with configurable parameters.
    
    If no options are provided, the script will start in interactive mode.

OPTIONS:
    --time, --duration SECONDS      Duration in seconds for each test
    --concurrency "LEVELS"          Space-separated concurrency levels (e.g., "50 100 500")
    --requests "TYPES"              Space-separated request types: light, heavy (e.g., "light heavy")
    --limiters "TYPES"              Space-separated rate limiter types (see available types below)
    
    --defaults, --default           Use default configuration (30s, all concurrency levels, all types)
    --clusters, --cluster-only      Test cluster configurations only (150s duration, with 1000 concurrency)
    --standalone, --standalone-only Test standalone configurations only (120s duration, up to 500 concurrency)
    --quick, --quick-mode          Quick test mode (30s, limited concurrency and types)
    
    --interactive, -i              Force interactive mode
    -h, --help                     Show this help message and exit

AVAILABLE RATE LIMITER TYPES:
    Standalone modes:
    - valkey-glide      Valkey with Glide client (standalone)
    - iovalkey          Valkey with IOValkey client (standalone)
    - ioredis           Redis with IORedis client (standalone)
    
    Cluster modes:
    - valkey-glide:cluster   Valkey with Glide client (cluster)
    - iovalkey:cluster       Valkey with IOValkey client (cluster)
    - ioredis:cluster        Redis with IORedis client (cluster)

EXAMPLES:
    \$0                                                    # Interactive mode
    \$0 --defaults                                         # Run with all defaults
    \$0 --clusters                                         # Test cluster configurations only
    \$0 --standalone                                       # Test standalone configurations only
    \$0 --quick                                           # Quick test mode
    
    \$0 --time 60 --concurrency "50 100" --requests "light" --limiters "valkey-glide ioredis"
    \$0 --duration 120 --limiters "valkey-glide:cluster iovalkey:cluster"
    \$0 --quick --limiters "valkey-glide"

PRESET CONFIGURATIONS:
    --defaults:     30s duration, concurrency: 50 100 500 1000, all request types, all limiters
    --clusters:     150s duration, concurrency: 50 100 500 1000, all request types, cluster limiters only
    --standalone:   120s duration, concurrency: 50 100 500, all request types, standalone limiters only
    --quick:        30s duration, concurrency: 50 100, light requests only, valkey-glide + iovalkey only

ENVIRONMENT VARIABLES (still supported):
    COMPUTATION_COMPLEXITY Set computational complexity (default: 10)
    DEBUG_MODE             Enable debug logging (true/false)
    SKIP_LONG_TESTS        Override test duration to 30s (true/false)
    SKIP_CONTAINER_SETUP   Use existing containers (true/false)

RESULTS:
    Results are saved to: ./results/YYYYMMDD_HHMMSS/
    Each test produces:
    - JSON results file with performance metrics
    - Log file with detailed execution information
    - README.md with test configuration summary

INTERACTIVE MODE:
    If no options are provided, the script will guide you through selecting:
    - Test duration
    - Concurrency levels
    - Request types
    - Rate limiter types
    - Additional options
EOF
}

# Parse command line arguments with proper flags

# Initialize variables with no defaults - we'll set them based on flags
duration=""
concurrency_levels=""
request_types=""
rate_limiter_types=""
interactive_mode=false
use_defaults=false
clusters_only=false
standalone_only=false
quick_mode=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --time|--duration)
            if [[ -z "$2" || "$2" =~ ^-- ]]; then
                echo "ERROR: --time requires a value (seconds)" >&2
                exit 1
            fi
            duration="$2"
            shift 2
            ;;
        --concurrency)
            if [[ -z "$2" || "$2" =~ ^-- ]]; then
                echo "ERROR: --concurrency requires values (e.g., '50 100 500')" >&2
                exit 1
            fi
            concurrency_levels="$2"
            shift 2
            ;;
        --requests|--request-types)
            if [[ -z "$2" || "$2" =~ ^-- ]]; then
                echo "ERROR: --requests requires values (e.g., 'light heavy')" >&2
                exit 1
            fi
            request_types="$2"
            shift 2
            ;;
        --limiters|--rate-limiters)
            if [[ -z "$2" || "$2" =~ ^-- ]]; then
                echo "ERROR: --limiters requires values (e.g., 'valkey-glide ioredis')" >&2
                exit 1
            fi
            rate_limiter_types="$2"
            shift 2
            ;;
        --defaults|--default)
            use_defaults=true
            shift
            ;;
        --clusters|--cluster-only)
            clusters_only=true
            shift
            ;;
        --standalone|--standalone-only)
            standalone_only=true
            shift
            ;;
        --quick|--quick-mode)
            quick_mode=true
            shift
            ;;
        --interactive|-i)
            interactive_mode=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Validate conflicting options
if [[ "$clusters_only" == true && "$standalone_only" == true ]]; then
    echo "ERROR: Cannot use --clusters and --standalone together" >&2
    exit 1
fi

# If no arguments provided, start interactive mode
if [[ "$use_defaults" == false && "$clusters_only" == false && "$standalone_only" == false && 
      -z "$duration" && -z "$concurrency_levels" && -z "$request_types" && -z "$rate_limiter_types" && 
      "$interactive_mode" == false && "$quick_mode" == false ]]; then
    interactive_mode=true
fi

# Set defaults or preset configurations
if [[ "$use_defaults" == true ]]; then
    duration=${duration:-$DEFAULT_DURATION}
    concurrency_levels=${concurrency_levels:-"${DEFAULT_CONCURRENCY_LEVELS[*]}"}
    request_types=${request_types:-"${DEFAULT_REQUEST_TYPES[*]}"}
    rate_limiter_types=${rate_limiter_types:-"${DEFAULT_RATE_LIMITER_TYPES[*]}"}
elif [[ "$clusters_only" == true ]]; then
    duration=${duration:-150}
    concurrency_levels=${concurrency_levels:-"50 100 500 1000"}
    request_types=${request_types:-"light heavy"}
    rate_limiter_types=${rate_limiter_types:-"valkey-glide:cluster iovalkey:cluster ioredis:cluster"}
elif [[ "$standalone_only" == true ]]; then
    duration=${duration:-120}
    concurrency_levels=${concurrency_levels:-"50 100 500"}
    request_types=${request_types:-"light heavy"}
    rate_limiter_types=${rate_limiter_types:-"valkey-glide iovalkey ioredis"}
elif [[ "$quick_mode" == true ]]; then
    duration=${duration:-30}
    concurrency_levels=${concurrency_levels:-"50 100"}
    request_types=${request_types:-"light"}
    rate_limiter_types=${rate_limiter_types:-"valkey-glide iovalkey"}
fi

# Convert string values to arrays (for non-interactive mode)
if [[ "$interactive_mode" == false ]]; then
    # Validate that all required values are set
    if [[ -z "$duration" || -z "$concurrency_levels" || -z "$request_types" || -z "$rate_limiter_types" ]]; then
        echo "ERROR: Missing required parameters. Use --help for usage information" >&2
        exit 1
    fi
    
    # Convert to arrays
    read -r -a concurrency_levels <<< "$concurrency_levels"
    read -r -a request_types <<< "$request_types"
    read -r -a rate_limiter_types <<< "$rate_limiter_types"
    
    # Validate duration is a number
    if ! [[ "$duration" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Duration must be a positive integer (seconds)" >&2
        exit 1
    fi
    
    # Validate concurrency levels are numbers
    for level in "${concurrency_levels[@]}"; do
        if ! [[ "$level" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Concurrency levels must be positive integers" >&2
            exit 1
        fi
    done
    
    # Validate request types
    for req_type in "${request_types[@]}"; do
        if [[ "$req_type" != "light" && "$req_type" != "heavy" ]]; then
            echo "ERROR: Request types must be 'light' or 'heavy'" >&2
            exit 1
        fi
    done
    
    # Validate rate limiter types
    valid_limiters=("valkey-glide" "iovalkey" "ioredis" "valkey-glide:cluster" "iovalkey:cluster" "ioredis:cluster")
    for limiter in "${rate_limiter_types[@]}"; do
        if [[ ! " ${valid_limiters[*]} " =~ " ${limiter} " ]]; then
            echo "ERROR: Invalid rate limiter type: $limiter" >&2
            echo "Valid types: ${valid_limiters[*]}" >&2
            exit 1
        fi
    done
fi

# --- Helper Functions ---

log() {
echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_success() {
echo "[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $1" | tee -a "$LOG_FILE"
}

# Interactive mode function
run_interactive_mode() {
    echo "=== Rate Limiter Benchmark - Interactive Mode ==="
    echo ""
    
    # Duration selection
    echo "1. Select test duration:"
    echo "   1) 30 seconds (quick)"
    echo "   2) 60 seconds (standard)"
    echo "   3) 120 seconds (thorough)"
    echo "   4) Custom duration"
    echo -n "Choose duration [1-4] (default: 1): "
    read -r duration_choice
    
    case "$duration_choice" in
        2) duration=60 ;;
        3) duration=120 ;;
        4) 
            echo -n "Enter custom duration in seconds: "
            read -r duration
            if ! [[ "$duration" =~ ^[0-9]+$ ]]; then
                echo "Invalid duration. Using default of 30 seconds."
                duration=30
            fi
            ;;
        *) duration=30 ;;
    esac
    
    # Concurrency selection
    echo ""
    echo "2. Select concurrency levels:"
    echo "   1) Light load (50, 100)"
    echo "   2) Medium load (50, 100, 500)"
    echo "   3) Heavy load (50, 100, 500, 1000)"
    echo "   4) Custom levels"
    echo -n "Choose concurrency [1-4] (default: 2): "
    read -r concurrency_choice
    
    case "$concurrency_choice" in
        1) concurrency_levels=(50 100) ;;
        3) concurrency_levels=(50 100 500 1000) ;;
        4)
            echo -n "Enter concurrency levels (space-separated, e.g., '50 100 200'): "
            read -r -a concurrency_levels
            if [ ${#concurrency_levels[@]} -eq 0 ]; then
                echo "No concurrency levels provided. Using default."
                concurrency_levels=(50 100 500)
            fi
            ;;
        *) concurrency_levels=(50 100 500) ;;
    esac
    
    # Request types selection
    echo ""
    echo "3. Select request types:"
    echo "   1) Light requests only"
    echo "   2) Heavy requests only"
    echo "   3) Both light and heavy requests"
    echo -n "Choose request types [1-3] (default: 3): "
    read -r request_choice
    
    case "$request_choice" in
        1) request_types=("light") ;;
        2) request_types=("heavy") ;;
        *) request_types=("light" "heavy") ;;
    esac
    
    # Rate limiter types selection
    echo ""
    echo "4. Select rate limiter types:"
    echo "   1) Standalone only (valkey-glide, iovalkey, ioredis)"
    echo "   2) Cluster only (valkey-glide:cluster, iovalkey:cluster, ioredis:cluster)"
    echo "   3) All types (standalone + cluster)"
    echo "   4) Valkey only (valkey-glide + valkey-glide:cluster)"
    echo "   5) Redis only (ioredis + ioredis:cluster)"
    echo "   6) Custom selection"
    echo -n "Choose rate limiter types [1-6] (default: 1): "
    read -r limiter_choice
    
    case "$limiter_choice" in
        1) rate_limiter_types=("valkey-glide" "iovalkey" "ioredis") ;;
        2) rate_limiter_types=("valkey-glide:cluster" "iovalkey:cluster" "ioredis:cluster") ;;
        3) rate_limiter_types=("valkey-glide" "iovalkey" "ioredis" "valkey-glide:cluster" "iovalkey:cluster" "ioredis:cluster") ;;
        4) rate_limiter_types=("valkey-glide" "valkey-glide:cluster") ;;
        5) rate_limiter_types=("ioredis" "ioredis:cluster") ;;
        6)
            echo ""
            echo "Available rate limiter types:"
            echo "  - valkey-glide"
            echo "  - iovalkey"
            echo "  - ioredis"
            echo "  - valkey-glide:cluster"
            echo "  - iovalkey:cluster"
            echo "  - ioredis:cluster"
            echo -n "Enter rate limiter types (space-separated): "
            read -r -a rate_limiter_types
            if [ ${#rate_limiter_types[@]} -eq 0 ]; then
                echo "No rate limiter types provided. Using default."
                rate_limiter_types=("valkey-glide" "iovalkey" "ioredis")
            fi
            ;;
        *) rate_limiter_types=("valkey-glide" "iovalkey" "ioredis") ;;
    esac
    
    # Additional options
    echo ""
    echo "5. Additional options:"
    echo -n "Enable debug mode? [y/N]: "
    read -r debug_choice
    if [[ "$debug_choice" =~ ^[Yy]$ ]]; then
        export DEBUG_MODE=true
    fi
    
    echo -n "Run quick tests only (30s max)? [y/N]: "
    read -r quick_choice
    if [[ "$quick_choice" =~ ^[Yy]$ ]]; then
        export SKIP_LONG_TESTS=true
        duration=30
    fi
    
    # Summary
    echo ""
    echo "=== Configuration Summary ==="
    echo "Duration: ${duration}s per test"
    echo "Concurrency levels: ${concurrency_levels[*]}"
    echo "Request types: ${request_types[*]}"
    echo "Rate limiter types: ${rate_limiter_types[*]}"
    echo "Debug mode: ${DEBUG_MODE:-false}"
    echo "Quick tests: ${SKIP_LONG_TESTS:-false}"
    echo ""
    echo -n "Proceed with these settings? [Y/n]: "
    read -r proceed_choice
    
    if [[ "$proceed_choice" =~ ^[Nn]$ ]]; then
        echo "Benchmark cancelled."
        exit 0
    fi
    
    echo ""
    echo "Starting benchmark with selected configuration..."
}

# Check if we should run interactive mode
if [[ "$interactive_mode" == true ]]; then
    run_interactive_mode
fi

# --- Helper Functions ---

ensure_network() {
    log "Ensuring Podman network '$BENCHMARK_NETWORK' exists..."
    if ! podman network inspect "$BENCHMARK_NETWORK" >/dev/null 2>&1; then
        log "Creating Podman network '$BENCHMARK_NETWORK'..."
        podman network create "$BENCHMARK_NETWORK"
    else
        log "Network '$BENCHMARK_NETWORK' already exists."
    fi
}

cleanup_containers() {
    log "Cleaning up containers..."
    podman stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    podman rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    podman stop "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true
    podman rm "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true

    if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
        log "Stopping database containers defined in $CURRENT_COMPOSE_FILE..."
        podman-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
        CURRENT_COMPOSE_FILE=""
    fi
    log "Cleanup complete."

}

run_server_container() {
  local rate_limiter=$1
  local cluster_env=$2
  local network_name=$3
  
  log "Starting server container ($SERVER_IMAGE_TAG)..."
  log "Using Podman network: $network_name"
  
  if ! podman network inspect "$network_name" >/dev/null 2>&1; then
    log "ERROR: Network $network_name does not exist!"
    log "Available networks:"
    podman network ls
    log "An error occurred. Cleaning up..."
    cleanup_containers
    exit 1
  fi
  
  server_container_id=$(podman run -d \
    --name "$SERVER_CONTAINER_NAME" \
    --restart=on-failure:3 \
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
    if podman exec $container_name $cli_command -p $port PING 2>/dev/null | grep -q "PONG"; then
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
    podman logs $container_name | tail -20
    return 1
  fi
  
  return 0
}
    get_actual_container_names() {
      local db_tech=$1
      
      if [[ "$db_tech" == "redis" ]]; then
        ACTUAL_DB_CONTAINER=$(podman ps --format "{{.Names}}" | grep -E "redis|Redis" | grep -v -E "exporter|cluster-setup|node[1-6]" | head -1)
      elif [[ "$db_tech" == "valkey" ]]; then
        ACTUAL_DB_CONTAINER=$(podman ps --format "{{.Names}}" | grep -E "valkey|Valkey" | grep -v -E "exporter|cluster-setup|node[1-6]" | head -1)
      fi
      
      if [[ -z "$ACTUAL_DB_CONTAINER" && "$db_tech" == "redis" ]]; then
        ACTUAL_DB_CONTAINER=$(podman ps --format "{{.Names}}" | grep -E "redis-node1" | head -1)
      elif [[ -z "$ACTUAL_DB_CONTAINER" && "$db_tech" == "valkey" ]]; then
        ACTUAL_DB_CONTAINER=$(podman ps --format "{{.Names}}" | grep -E "valkey-node1" | head -1)
      fi

      if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
        log "Detected actual database container name: $ACTUAL_DB_CONTAINER"
      else
        log "WARNING: Could not detect any $db_tech container!"
      fi
    }

# --- Ensure Thorough Cleanup Before Starting ---
log "Performing thorough cleanup before starting benchmark..."
# Clean up any containers with benchmark names
podman ps -a --filter "name=running-benchmark-" --format "{{.Names}}" | xargs -r podman rm -f || true
podman ps -a --filter "name=benchmark-loadtest" --format "{{.Names}}" | xargs -r podman rm -f || true

log "Benchmark cleanup completed"

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
- **Podman Version:** $(podman --version)

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

# --- Build Container Images ---
log "Building server container image ($SERVER_IMAGE_TAG)..."
podman build -t "$SERVER_IMAGE_TAG" -f Dockerfile.server .

log "Building loadtest container image ($LOADTEST_IMAGE_TAG)..."
podman build -t "$LOADTEST_IMAGE_TAG" -f Dockerfile.loadtest .

# --- Main Test Loop ---

CURRENT_COMPOSE_FILE=""
if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
    log "Creating Podman network for benchmarks..."
    podman network create "$BENCHMARK_NETWORK" 2>/dev/null || log "Network $BENCHMARK_NETWORK already exists"
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
            log "ERROR: Compose file $CURRENT_COMPOSE_FILE not found."
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


        podman-compose -f "$CURRENT_COMPOSE_FILE" -p "$BENCHMARK_MANAGED_PROJECT_NAME" up -d --force-recreate

        get_actual_container_names "$db_tech"

        if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
             log "Connecting $ACTUAL_DB_CONTAINER to network $BENCHMARK_NETWORK..."
             podman network connect "$BENCHMARK_NETWORK" "$ACTUAL_DB_CONTAINER" 2>/dev/null || true
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
                    
                    if podman exec "$ACTUAL_DB_CONTAINER" $cli_command -p "$db_port" PING 2>/dev/null | grep -q "PONG"; then
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
                    
                    if podman exec "$ACTUAL_DB_CONTAINER" $cli_command -p "$db_port" PING 2>/dev/null | grep -q "PONG"; then
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
                podman ps | grep "$ACTUAL_DB_CONTAINER" || true
                if [[ -n "$ACTUAL_DB_CONTAINER" ]]; then
                    podman logs "$ACTUAL_DB_CONTAINER" | tail -20
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
                if podman exec "$ACTUAL_DB_CONTAINER" redis-cli PING 2>/dev/null | grep -q "PONG"; then
                    log "Successfully verified connection to $ACTUAL_DB_CONTAINER"
                else
                    log "WARNING: Could not verify connection to $ACTUAL_DB_CONTAINER"
                fi
            fi
        fi
    fi

    # --- Configure Server Environment Variables ---
    # Initialize as empty array properly
    declare -a server_env_vars
    server_env_vars=(-e "NODE_ENV=production" -e "PORT=${DEFAULT_SERVER_PORT}")

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
        PROJECT_PREFIX=${COMPOSE_PROJECT_NAME:-ratelimit_bench}

        if [[ "$db_tech" == "redis" ]]; then
            REDIS_CLUSTER_NODES="${PROJECT_PREFIX}-redis-node1:6379,${PROJECT_PREFIX}-redis-node2:6379,${PROJECT_PREFIX}-redis-node3:6379,${PROJECT_PREFIX}-redis-node4:6379,${PROJECT_PREFIX}-redis-node5:6379,${PROJECT_PREFIX}-redis-node6:6379"
            server_env_vars+=(-e "REDIS_CLUSTER_NODES=${REDIS_CLUSTER_NODES}")
            log "REDIS_CLUSTER_NODES set to: ${REDIS_CLUSTER_NODES}"
        elif [[ "$db_tech" == "valkey" ]]; then
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

    podman stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    podman rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true

    # Pass COMPUTATION_COMPLEXITY environment variable if it exists
    if [[ -n "$COMPUTATION_COMPLEXITY" ]]; then
        server_env_vars+=(-e "COMPUTATION_COMPLEXITY=$COMPUTATION_COMPLEXITY")
        log "Setting COMPUTATION_COMPLEXITY=$COMPUTATION_COMPLEXITY"
    else
        # Set a reasonable default for heavy workloads
        server_env_vars+=(-e "COMPUTATION_COMPLEXITY=10")
        log "Setting default COMPUTATION_COMPLEXITY=10"
    fi

    # Debug: print the server env vars before using them
    log "Debug: server_env_vars array contents:"
    for i in "${!server_env_vars[@]}"; do
        log "  [$i]: ${server_env_vars[$i]}"
    done
    
    podman run -d --name "$SERVER_CONTAINER_NAME" \
        --restart=on-failure:3 \
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
        if podman logs "$SERVER_CONTAINER_NAME" 2>&1 | grep -q "Server listening on http://0.0.0.0:${DEFAULT_SERVER_PORT}"; then
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
        podman logs "$SERVER_CONTAINER_NAME" || true
        
        log "Network information:"
        podman network inspect "$BENCHMARK_NETWORK" || true
        
        log "Database connection information:"
        if [[ "$use_cluster" == "true" ]]; then
            log "Trying to ping cluster nodes..."
            if [[ "$db_tech" == "redis" ]]; then
                for i in {1..6}; do
                    podman exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-redis-node$i-1" || true
                done
            elif [[ "$db_tech" == "valkey" ]]; then
                for i in {1..6}; do
                    podman exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-valkey-node$i-1" || true
                done
            fi
        else
            if [[ "$db_tech" == "redis" ]]; then
                log "Trying to ping Redis container..."
                podman exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-redis-1" || true
            elif [[ "$db_tech" == "valkey" ]]; then
                log "Trying to ping Valkey container..."
                podman exec -i "$SERVER_CONTAINER_NAME" ping -c 1 "ratelimit_bench-valkey-1" || true
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

            # Determine how many runs to perform
            # If this is a quick benchmark, only do 1 run, otherwise do 3
            max_runs=3
            if [[ "$SKIP_LONG_TESTS" == "true" ]]; then
                max_runs=1
                log "Quick benchmark mode: Running each test configuration once only"
            fi
            
            # --- Add loop for multiple runs ---
            for run_num in $(seq 1 $max_runs); do
                # --- Calculate dynamic duration ---
                current_duration=$duration # Start with base duration
                
                # Only override duration if SKIP_LONG_TESTS is not set
                if [[ "$SKIP_LONG_TESTS" != "true" ]]; then
                    if [[ "$conn" -le 100 ]]; then
                        current_duration=120 # 2 minutes for 50, 100 concurrency
                    elif [[ "$conn" -ge 500 ]]; then
                        current_duration=180 # 3 minutes for 500, 1000 concurrency
                    fi

                    if [[ "$req_type" == "heavy" ]]; then
                        current_duration=$((current_duration + 30)) # Add 30s for heavy requests
                    fi
                else
                    # Force 30s duration for quick benchmark mode
                    current_duration=30
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
                    # Use timestamp to ensure unique container name
                    timestamp=$(date +%s)
                    warmup_container_name="${LOADTEST_CONTAINER_NAME}_warmup_${run_num}_${timestamp}" # Unique name per run
                    
                    # Ensure any existing container with similar name is removed first
                    podman rm -f "${LOADTEST_CONTAINER_NAME}_warmup_${run_num}" > /dev/null 2>&1 || true

                    # Print the exact podman run command for debugging
                    log "Running warmup with command: podman run --name $warmup_container_name --network=$BENCHMARK_NETWORK ${warmup_env_vars[*]} $LOADTEST_IMAGE_TAG"

                    # Ensure expansion treats each element as a separate argument
                    podman run --name "$warmup_container_name" \
                        --network="$BENCHMARK_NETWORK" \
                        "${warmup_env_vars[@]}" \
                        "$LOADTEST_IMAGE_TAG" > "${RESULTS_DIR_HOST}/${test_id}_warmup.log" 2>&1

                    warmup_exit_code=$?
                    if [ $warmup_exit_code -ne 0 ]; then
                        log "ERROR: Warmup container failed with exit code $warmup_exit_code."
                        log "=== Warmup container logs ==="
                        podman logs "$warmup_container_name" 2>&1 | tee -a "$LOG_FILE" || log "Could not retrieve logs for failed warmup container."
                        log "=== End warmup container logs ==="
                        log "Network diagnostic information:"
                        podman network inspect "$BENCHMARK_NETWORK" | grep -A 10 "Containers" | tee -a "$LOG_FILE"
                        log "Testing connectivity from warmup container to server:"
                        podman exec -i "$warmup_container_name" ping -c 1 "$SERVER_CONTAINER_NAME" || log "Could not ping server from warmup container"
                        podman rm "$warmup_container_name" > /dev/null 2>&1 || true
                        exit 1
                    fi

                    podman rm "$warmup_container_name" > /dev/null 2>&1 || true
                    log "Warmup phase completed. Starting actual benchmark..."
                else
                    log "Skipping warmup phase as WARMUP_DURATION is 0."
                fi
                # --- End Warmup Phase ---

                # --- Actual Benchmark Run ---
                log "Starting loadtest container ($LOADTEST_IMAGE_TAG) for run $run_num..." # Use run_num
                loadtest_container_name="${LOADTEST_CONTAINER_NAME}_run${run_num}" # Use run_num
                
                # Clean up any existing container with this name from previous benchmark runs
                podman rm -f "$loadtest_container_name" > /dev/null 2>&1 || true
                
                # Ensure expansion treats each element as a separate argument
                # Redirect stdout/stderr to the container log file
                podman run --name "$loadtest_container_name" \
                    --network="$BENCHMARK_NETWORK" \
                    "${loadtest_env_vars[@]}" \
                    "$LOADTEST_IMAGE_TAG" > "$container_log_file" 2>&1

                loadtest_exit_code=$?

                # Copy results from container regardless of exit code
                # Copy the JSON file generated inside the container to the host JSON results file
                podman cp "${loadtest_container_name}:/app/results/${test_id}.json" "$json_results_file" > /dev/null 2>&1 || log "WARNING: Could not copy results file ${test_id}.json from container ${loadtest_container_name}"

                if [ $loadtest_exit_code -ne 0 ]; then
                    log "ERROR: Loadtest container failed with exit code $loadtest_exit_code."
                    log "Loadtest container output saved to: $container_log_file" # Log the correct log file name
                    cat "$container_log_file" # Print the output for debugging
                    podman rm "$loadtest_container_name" > /dev/null 2>&1 || true
                    exit 1
                fi

                podman rm "$loadtest_container_name" > /dev/null 2>&1 || true
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
    podman stop "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    podman rm "$SERVER_CONTAINER_NAME" > /dev/null 2>&1 || true
    log "Server container stopped and removed."

    # --- Conditional Database Cleanup ---
    if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
        log "Stopping database container(s) for $rate_limiter_type (managed by run-benchmark.sh)..."
        if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
            podman-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
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
    podman stop "$SERVER_CONTAINER_NAME" "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true
    podman rm "$SERVER_CONTAINER_NAME" "$LOADTEST_CONTAINER_NAME" > /dev/null 2>&1 || true

    if [[ "$SKIP_CONTAINER_SETUP" != "true" ]]; then
        if [[ -n "$CURRENT_COMPOSE_FILE" ]]; then
             log "Final shutdown of database containers using $CURRENT_COMPOSE_FILE..."
             podman-compose -f "$CURRENT_COMPOSE_FILE" down -v --remove-orphans > /dev/null 2>&1
        fi
    fi
    log "Final cleanup complete."
}

trap cleanup_final EXIT ERR INT TERM

log_success "Benchmark suite finished successfully."
