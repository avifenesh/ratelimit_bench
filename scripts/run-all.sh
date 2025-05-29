#!/bin/bash

set -e

# --- Configuration ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_BASE_DIR="$(pwd)/results"
RESULTS_DIR="${RESULTS_BASE_DIR}/${TIMESTAMP}"

# Benchmark timing constants
COOLDOWN_BETWEEN_TESTS=5
COOLDOWN_BETWEEN_TYPES=10

# Initialize configuration variables
SELECTED_CLIENTS=""
RUN_LIGHT_WORKLOAD=false
RUN_HEAVY_WORKLOAD=false
BENCHMARK_CONCURRENCY=""
USE_DYNAMIC_DURATION=false
FIXED_DURATION=""

# Function to calculate dynamic duration
calculate_duration() {
  local concurrency=$1
  local client=$2
  local base_duration
  
  # Base duration based on concurrency
  if [ "$concurrency" -le 100 ]; then
    base_duration=120
  else
    base_duration=180
  fi
  
  # Add 30 seconds for cluster setups
  if [[ "$client" == *":cluster" ]]; then
    base_duration=$((base_duration + 30))
  fi
  
  echo "$base_duration"
}

# Command line argument variables
ARG_CLIENT=""
ARG_WORKLOAD=""
ARG_DURATION=""
ARG_CONCURRENCY=""

# Create directory structure before any logging happens
mkdir -p "$RESULTS_DIR"
MKDIR_EXIT_CODE=$?
echo "mkdir exit code: ${MKDIR_EXIT_CODE}"
if [ "$MKDIR_EXIT_CODE" -ne 0 ]; then
  echo "Error creating directory: $RESULTS_DIR"
  exit 1
fi

LOG_FILE="${RESULTS_DIR}/full_benchmark.log"
echo "LOG_FILE: ${LOG_FILE}"
touch "$LOG_FILE"
TOUCH_EXIT_CODE=$?
if [ "$TOUCH_EXIT_CODE" -ne 0 ]; then
    echo "Error: Failed to create log file '$LOG_FILE' with touch. Exit code: $TOUCH_EXIT_CODE" >&2
    # Add a check to see if the directory exists at this point
    if [ ! -d "$RESULTS_DIR" ]; then
        echo "Error: Directory '$RESULTS_DIR' does not exist when trying to touch the log file." >&2
    else
        echo "Error: Directory '$RESULTS_DIR' exists, but touch failed (Permissions issue?)" >&2
    fi
    exit 1 # Exit explicitly if touch fails
fi


# --- Helper Functions ---
log() {
  echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] \033[1;36m$1\033[0m" | tee -a "$LOG_FILE"
}

log_success() {
  echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] \033[1;32m$1\033[0m" | tee -a "$LOG_FILE"
}

log_error() {
  echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] \033[1;31m$1\033[0m" | tee -a "$LOG_FILE"
}

setup_environment() {
  log "Setting up environment..."
  
  # Install dependencies
  log "Installing npm dependencies..."
  npm install
  
  # Create Valkey config file if it doesn't exist
  if [ ! -f "./valkey.conf" ]; then
    echo "# Valkey configuration for benchmark" > ./valkey.conf
    log "Created valkey.conf file"
  fi
  
  # Ensure scripts are executable
  chmod +x ./scripts/run-benchmark.sh
  chmod +x ./scripts/generate_report.py
  
  # Create symlink for latest results
  rm -f "${RESULTS_BASE_DIR}/latest"
  ln -sf "${TIMESTAMP}" "${RESULTS_BASE_DIR}/latest"
  
  log_success "Environment setup complete"
}

build_application() {
  log "Building application..."
  npm run build
  log_success "Application built successfully"
}

start_containers() {
  log "Starting containers based on selected clients..."

  # Clean the project before starting containers
  log "Cleaning the project..."
  npm run clean
  
  # Stop any running containers first
  log "Stopping any existing containers..."  
  podman stop --all &>/dev/null || true
  podman pod stop --all &>/dev/null || true
  podman container rm --all &>/dev/null || true
  podman pod rm --all &>/dev/null || true

  # Copy built files to Podman volumes if needed
  log "Copying built application code to Podman volume..."
  if [ ! -d "./dist" ]; then
    log "No built code found. Attempting to build the application again..."
    npm run build
  fi
  
  if [ -d "./dist" ]; then
    mkdir -p ./docker/app
    cp -r ./dist ./docker/app/
    cp package.json ./docker/app/
    log "Application code copied to Podman volume"
  else
    log_error "No built code found even after rebuilding. Check for build errors."
    exit 1
  fi
  
  # Create the benchmark network explicitly
  log "Creating benchmark network..."
  podman network create benchmark-network 2>/dev/null || true
  
  # Determine what containers to start based on selected clients
  NEED_VALKEY_STANDALONE=false
  NEED_VALKEY_CLUSTER=false
  NEED_REDIS_STANDALONE=false
  NEED_REDIS_CLUSTER=false
  
  for client in $SELECTED_CLIENTS; do
    case $client in
      *valkey-glide*|*iovalkey*)
        if [[ $client == *":cluster"* ]]; then
          NEED_VALKEY_CLUSTER=true
        else
          NEED_VALKEY_STANDALONE=true
        fi
        ;;
      *ioredis*)
        if [[ $client == *":cluster"* ]]; then
          NEED_REDIS_CLUSTER=true
        else
          NEED_REDIS_STANDALONE=true
        fi
        ;;
    esac
  done
  
  # Start Valkey containers if needed
  if [ "$NEED_VALKEY_STANDALONE" = "true" ]; then
    log "Starting Valkey standalone..."
    podman run -d \
      --name benchmark-valkey \
      --restart on-failure:3 \
      -p 8080:6379 \
      --network benchmark-network \
      --ulimit nproc=65535 \
      --ulimit nofile=65535:65535 \
      --cpus 2 \
      --memory 2G \
      --cap-add SYS_RESOURCE \
      valkey/valkey:latest \
      valkey-server --save "" --appendonly no --maxmemory 1gb --maxmemory-policy volatile-lru
  fi
  
  if [ "$NEED_VALKEY_CLUSTER" = "true" ]; then
    log "Starting Valkey cluster..."
    
    # Create a pod for Valkey cluster with port mappings
    podman pod create --name valkey-cluster-pod --network benchmark-network \
      -p 7000:7000 -p 7001:7001 -p 7002:7002 -p 7003:7003 -p 7004:7004 -p 7005:7005
    
    # Start Valkey cluster nodes
    for i in {1..6}; do
      port=$((7000 + i - 1))
      podman run -d \
        --name ratelimit_bench-valkey-node$i \
        --pod valkey-cluster-pod \
        --restart on-failure:3 \
        --ulimit nproc=65535 \
        --ulimit nofile=65535:65535 \
        --cpus 1 \
        --memory 1G \
        valkey/valkey:8.1 \
        valkey-server --port $port --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly no --save ""
    done
    
    # Wait for nodes to start
    sleep 5
    
    # Create cluster setup container
    podman run -d \
      --name ratelimit_bench-valkey-cluster-setup \
      --pod valkey-cluster-pod \
      --restart on-failure:3 \
      valkey/valkey:8.1 \
      sh -c 'sleep 10 && echo "yes" | valkey-cli --cluster create localhost:7000 localhost:7001 localhost:7002 localhost:7003 localhost:7004 localhost:7005 --cluster-replicas 1'
  fi
  
  # Start Redis containers if needed  
  if [ "$NEED_REDIS_STANDALONE" = "true" ]; then
    log "Starting Redis standalone..."
    podman run -d \
      --name benchmark-redis \
      --restart on-failure:3 \
      -p 6379:6379 \
      --network benchmark-network \
      --ulimit nproc=65535 \
      --ulimit nofile=65535:65535 \
      --cpus 2 \
      --memory 2G \
      --cap-add SYS_RESOURCE \
      redis:8 \
      redis-server --save "" --appendonly no --maxmemory 1gb --maxmemory-policy volatile-lru
  fi
  
  if [ "$NEED_REDIS_CLUSTER" = "true" ]; then
    log "Starting Redis cluster..."
    
    # Create a pod for Redis cluster with port mappings
    podman pod create --name redis-cluster-pod --network benchmark-network \
      -p 6380:6380 -p 6381:6381 -p 6382:6382 -p 6383:6383 -p 6384:6384 -p 6385:6385
    
    # Start Redis cluster nodes
    for i in {1..6}; do
      port=$((6380 + i - 1))
      podman run -d \
        --name ratelimit_bench-redis-node$i \
        --pod redis-cluster-pod \
        --restart on-failure:3 \
        --ulimit nproc=65535 \
        --ulimit nofile=65535:65535 \
        --cpus 1 \
        --memory 1G \
        redis:8 \
        redis-server --port $port --cluster-enabled yes --cluster-config-file nodes.conf --cluster-node-timeout 5000 --appendonly no --save ""
    done
    
    # Wait for nodes to start
    sleep 5
    
    # Create cluster setup container
    podman run -d \
      --name ratelimit_bench-redis-cluster-setup \
      --pod redis-cluster-pod \
      --restart on-failure:3 \
      redis:8 \
      sh -c 'sleep 10 && echo "yes" | redis-cli --cluster create localhost:6380 localhost:6381 localhost:6382 localhost:6383 localhost:6384 localhost:6385 --cluster-replicas 1'
  fi
  
  # Make sure all containers are on the same network
  log "Ensuring all containers are on the benchmark network..."
  for container in $(podman ps --format "{{.Names}}"); do
    podman network connect benchmark-network $container 2>/dev/null || true
  done
  
  # Verify network connectivity for started containers
  log "Verifying network connectivity between containers..."
  
  if [ "$NEED_VALKEY_STANDALONE" = "true" ]; then
    podman exec benchmark-valkey valkey-cli PING 2>/dev/null | grep -q "PONG" && \
      log "Valkey container is accessible" || log "WARNING: Valkey container is not responding"
  fi
  
  if [ "$NEED_REDIS_STANDALONE" = "true" ]; then
    podman exec benchmark-redis redis-cli PING 2>/dev/null | grep -q "PONG" && \
      log "Redis container is accessible" || log "WARNING: Redis container is not responding"
  fi
  
  # Wait for containers to be ready
  log "Waiting for containers to be ready..."
  sleep 10
  
  log_success "Selected containers started successfully"
}

run_benchmarks() {
  log "Starting benchmark runs..."
  
  # Define benchmark script location
  BENCHMARK_SCRIPT="./scripts/run-benchmark.sh"
  
  # Ensure benchmark script is executable
  chmod +x "$BENCHMARK_SCRIPT"
  
  # Set environment variables to tell run-benchmark.sh that containers are already running
  export CONTAINERS_ALREADY_RUNNING="true"
  export BENCHMARK_NETWORK="benchmark-network"
  export RESULTS_DIR_HOST="$RESULTS_DIR"
  
  # Set workload types based on user selection
  WORKLOAD_TYPES=""
  if [ "$RUN_LIGHT_WORKLOAD" = "true" ]; then
    WORKLOAD_TYPES="${WORKLOAD_TYPES}light "
  fi
  if [ "$RUN_HEAVY_WORKLOAD" = "true" ]; then
    WORKLOAD_TYPES="${WORKLOAD_TYPES}heavy"
  fi
  WORKLOAD_TYPES=$(echo "$WORKLOAD_TYPES" | xargs) # Trim whitespace
  
  # Set common environment variables
  export BENCHMARK_REQUEST_TYPES="$WORKLOAD_TYPES"
  
  # Run benchmarks for each concurrency level and client combination
  for concurrency in $BENCHMARK_CONCURRENCY; do
    for client in $SELECTED_CLIENTS; do
      # Calculate duration for this specific combination
      if [ "$USE_DYNAMIC_DURATION" = "true" ]; then
        duration=$(calculate_duration "$concurrency" "$client")
      else
        duration="$FIXED_DURATION"
      fi
      
      log "Running benchmark: ${client} with ${concurrency} connections for ${duration}s..."
      
      # Set environment variables for this specific run
      export BENCHMARK_DURATION="$duration"
      export CONCURRENCY="$concurrency"
      export RATE_LIMITER_TYPES="$client"
      
      # Run the benchmark with current settings
      $BENCHMARK_SCRIPT
      
      # Wait between client tests
      log "Waiting ${COOLDOWN_BETWEEN_TESTS}s before next test..."
      sleep $COOLDOWN_BETWEEN_TESTS
    done
    
    # Wait between concurrency level tests
    log "Waiting ${COOLDOWN_BETWEEN_TYPES}s before next concurrency level..."
    sleep $COOLDOWN_BETWEEN_TYPES
  done
  
  # Unset environment variables
  unset CONTAINERS_ALREADY_RUNNING
  unset BENCHMARK_NETWORK
  unset RESULTS_DIR_HOST
  unset BENCHMARK_DURATION
  unset BENCHMARK_REQUEST_TYPES
  unset RATE_LIMITER_TYPES
  unset CONCURRENCY
  
  log_success "All benchmark runs completed"
}

generate_final_report() {
  log "Generating comprehensive report..."

  # Generate reports for each benchmark using the Python script
  if [ -f "./scripts/generate_report.py" ]; then
    log "Generating report for benchmark results using Python script..."
    python3 ./scripts/generate_report.py "$RESULTS_DIR"
  fi

  # Create a simplified index page that links to all benchmark results
  cat > "${RESULTS_BASE_DIR}/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
  <title>Valkey vs Redis Rate Limiter Benchmark Results</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; }
    h1, h2 { color: #333; }
    table { border-collapse: collapse; width: 100%; margin: 20px 0; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; }
  </style>
</head>
<body>
  <h1>Valkey vs Redis Rate Limiter Benchmark Results</h1>
  <h2>Benchmark Runs</h2>
  <table>
    <tr>
      <th>Date</th>
      <th>Run</th>
      <th>Results</th>
    </tr>
EOF

  # List all benchmark directories in reverse chronological order
  find "$RESULTS_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -not -path "*/\.*" | sort -r | while read -r dir; do
    run_id=$(basename "$dir")
    if [ "$run_id" != "latest" ]; then
      date_formatted=$(echo "$run_id" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
      # Add entry to the HTML table
      cat >> "${RESULTS_BASE_DIR}/index.html" << EOF
    <tr>
      <td>$date_formatted</td>
      <td>$run_id</td>
      <td><a href="./$run_id/report/index.html">View Results</a></td>
    </tr>
EOF
    fi
  done

  # Close the HTML table and document
  cat >> "${RESULTS_BASE_DIR}/index.html" << EOF
  </table>
</body>
</html>
EOF

  log_success "Comprehensive report generated at ${RESULTS_BASE_DIR}/index.html"
}

cleanup() {
  log "Cleaning up..."
  
  # Ask if containers should be stopped
  read -p "Do you want to stop all Docker containers? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    podman stop --all
    podman pod stop --all  
    podman container rm --all
    podman pod rm --all
    podman network rm benchmark-network 2>/dev/null || true
    log "All Podman containers and pods stopped"
  else
    log "Podman containers left running"
  fi
  
  log_success "Cleanup complete"
}

show_results() {
  log_success "All benchmark operations completed successfully!"
  log_success "Results are available at: ${RESULTS_DIR}"
  log_success "Full logs are available at: ${LOG_FILE}"
  # Update the viewing instructions
  log_success "Open the main results index in your browser: file://${RESULTS_BASE_DIR}/index.html"
  log_success "Or view the latest run report: file://${RESULTS_DIR}/report/index.html"
}

# Function to show usage
show_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  --clients CLIENT_LIST    Comma-separated list of clients to test"
  echo "                          Options: valkey-glide, iovalkey, ioredis,"
  echo "                                  valkey-glide:cluster, iovalkey:cluster, ioredis:cluster"
  echo "                          Special: standalone, cluster, all"
  echo "  --workload WORKLOAD     Workload type: light, heavy, both (default: both)"
  echo "  --concurrency LEVELS    Space-separated concurrency levels (default: 50 100 500 1000)"
  echo "  --duration-mode MODE    Duration mode: dynamic, fixed30, fixed120, custom:N"
  echo "                          dynamic: 120s for ≤100c, 180s for >100c, +30s for cluster"
  echo "  --help                  Show this help message"
  echo
  echo "Examples:"
  echo "  $0 --clients valkey-glide,ioredis --workload light --concurrency \"50 100\""
  echo "  $0 --clients cluster --duration-mode fixed30"
  echo "  $0 --clients all --workload both --duration-mode dynamic"
  echo
  echo "Interactive mode:"
  echo "  $0                      (run without arguments for guided configuration)"
  echo
  exit 0
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --clients)
        ARG_CLIENTS="$2"
        shift 2
        ;;
      --workload)
        ARG_WORKLOAD="$2"
        shift 2
        ;;
      --concurrency)
        ARG_CONCURRENCY="$2"
        shift 2
        ;;
      --duration-mode)
        ARG_DURATION_MODE="$2"
        shift 2
        ;;
      --help)
        show_usage
        ;;
      *)
        echo "Unknown option: $1"
        show_usage
        ;;
    esac
  done
}

# Set configuration from arguments
set_config_from_args() {
  # Set clients
  if [ -n "$ARG_CLIENTS" ]; then
    case $ARG_CLIENTS in
      standalone)
        SELECTED_CLIENTS="valkey-glide iovalkey ioredis"
        ;;
      cluster)
        SELECTED_CLIENTS="valkey-glide:cluster iovalkey:cluster ioredis:cluster"
        ;;
      all)
        SELECTED_CLIENTS="valkey-glide iovalkey ioredis valkey-glide:cluster iovalkey:cluster ioredis:cluster"
        ;;
      *)
        SELECTED_CLIENTS=$(echo "$ARG_CLIENTS" | tr ',' ' ')
        ;;
    esac
  fi
  
  # Set workload
  if [ -n "$ARG_WORKLOAD" ]; then
    case $ARG_WORKLOAD in
      light)
        RUN_LIGHT_WORKLOAD=true
        RUN_HEAVY_WORKLOAD=false
        ;;
      heavy)
        RUN_LIGHT_WORKLOAD=false
        RUN_HEAVY_WORKLOAD=true
        ;;
      both)
        RUN_LIGHT_WORKLOAD=true
        RUN_HEAVY_WORKLOAD=true
        ;;
    esac
  fi
  
  # Set concurrency
  if [ -n "$ARG_CONCURRENCY" ]; then
    BENCHMARK_CONCURRENCY="$ARG_CONCURRENCY"
  fi
  
  # Set duration mode
  if [ -n "$ARG_DURATION_MODE" ]; then
    case $ARG_DURATION_MODE in
      dynamic)
        USE_DYNAMIC_DURATION=true
        ;;
      fixed30)
        USE_DYNAMIC_DURATION=false
        FIXED_DURATION=30
        ;;
      fixed120)
        USE_DYNAMIC_DURATION=false
        FIXED_DURATION=120
        ;;
      custom:*)
        USE_DYNAMIC_DURATION=false
        FIXED_DURATION="${ARG_DURATION_MODE#custom:}"
        ;;
    esac
  fi
}

# Check if we should run in non-interactive mode
should_run_interactive() {
  [ -z "$ARG_CLIENTS" ] && [ -z "$ARG_WORKLOAD" ] && [ -z "$ARG_CONCURRENCY" ] && [ -z "$ARG_DURATION_MODE" ]
}
show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  --client CLIENT        Specify client(s) to test:"
  echo "                         valkey-glide, iovalkey, ioredis"
  echo "                         Add ':cluster' for cluster mode (e.g., valkey-glide:cluster)"
  echo "                         Use 'all', 'standalone', or 'cluster' for groups"
  echo "  --workload WORKLOAD    Specify workload type: light, heavy, or both"
  echo "  --duration DURATIONS   Specify duration(s) in seconds (space-separated)"
  echo "  --concurrency LEVELS   Specify concurrency level(s) (space-separated)"
  echo "  --help                 Show this help message"
  echo
  echo "Examples:"
  echo "  $0 --client valkey-glide --workload light --duration \"30 120\" --concurrency \"50 100\""
  echo "  $0 --client all --workload both --duration 30 --concurrency 50"
  echo "  $0 --client standalone --workload heavy --duration 60 --concurrency \"100 500\""
  echo
  echo "Interactive mode:"
  echo "  $0    (run without arguments for interactive configuration)"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --client)
        ARG_CLIENT="$2"
        shift 2
        ;;
      --workload)
        ARG_WORKLOAD="$2"
        shift 2
        ;;
      --duration)
        ARG_DURATION="$2"
        shift 2
        ;;
      --concurrency)
        ARG_CONCURRENCY="$2"
        shift 2
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

configure_benchmark() {
  # If arguments were provided, use non-interactive mode
  if [ -n "$ARG_CLIENT" ] || [ -n "$ARG_WORKLOAD" ] || [ -n "$ARG_DURATION" ] || [ -n "$ARG_CONCURRENCY" ]; then
    log "Running in non-interactive mode with provided arguments..."
    
    # Set client types
    case $ARG_CLIENT in
      valkey-glide)
        SELECTED_CLIENTS="valkey-glide"
        ;;
      iovalkey)
        SELECTED_CLIENTS="iovalkey"
        ;;
      ioredis)
        SELECTED_CLIENTS="ioredis"
        ;;
      valkey-glide:cluster)
        SELECTED_CLIENTS="valkey-glide:cluster"
        ;;
      iovalkey:cluster)
        SELECTED_CLIENTS="iovalkey:cluster"
        ;;
      ioredis:cluster)
        SELECTED_CLIENTS="ioredis:cluster"
        ;;
      standalone)
        SELECTED_CLIENTS="valkey-glide iovalkey ioredis"
        ;;
      cluster)
        SELECTED_CLIENTS="valkey-glide:cluster iovalkey:cluster ioredis:cluster"
        ;;
      all|"")
        SELECTED_CLIENTS="valkey-glide iovalkey ioredis valkey-glide:cluster iovalkey:cluster ioredis:cluster"
        ;;
      *)
        # Custom client list
        SELECTED_CLIENTS="$ARG_CLIENT"
        ;;
    esac
    
    # Set workload type
    case $ARG_WORKLOAD in
      light)
        RUN_LIGHT_WORKLOAD=true
        RUN_HEAVY_WORKLOAD=false
        ;;
      heavy)
        RUN_LIGHT_WORKLOAD=false
        RUN_HEAVY_WORKLOAD=true
        ;;
      both|"")
        RUN_LIGHT_WORKLOAD=true
        RUN_HEAVY_WORKLOAD=true
        ;;
      *)
        log_error "Invalid workload type: $ARG_WORKLOAD"
        exit 1
        ;;
    esac
    
    # Set durations
    BENCHMARK_DURATIONS="${ARG_DURATION:-30 120}"
    
    # Set concurrency
    BENCHMARK_CONCURRENCY="${ARG_CONCURRENCY:-50 100 500}"
    
    # Show configuration
    echo "==============================================="
    echo "Non-Interactive Benchmark Configuration:"
    echo "==============================================="
    echo "Clients: $SELECTED_CLIENTS"
    echo "Workloads: $([ "$RUN_LIGHT_WORKLOAD" = "true" ] && echo -n "light ")$([ "$RUN_HEAVY_WORKLOAD" = "true" ] && echo -n "heavy")"
    echo "Durations: $BENCHMARK_DURATIONS seconds"
    echo "Concurrency: $BENCHMARK_CONCURRENCY"
    echo "==============================================="
    
    return
  fi
  
  # Interactive mode
  # Clear screen and display header
  clear
  echo "==============================================="
  echo "  Valkey vs Redis Rate Limiter Benchmark Suite "
  echo "==============================================="
  echo
  echo "This script allows you to run customizable benchmarks comparing"
  echo "Valkey and Redis rate limiting implementations."
  echo
  
  # Client selection
  echo "Available Clients:"
  echo "  1. valkey-glide (standalone)"
  echo "  2. iovalkey (standalone)"
  echo "  3. ioredis (standalone)"
  echo "  4. valkey-glide (cluster)"
  echo "  5. iovalkey (cluster)"
  echo "  6. ioredis (cluster)"
  echo "  7. All standalone clients"
  echo "  8. All cluster clients"
  echo "  9. All clients (default)"
  echo
  read -p "Select client(s) to test (1-9): " -n 1 client_option
  echo
  
  # Set client types
  case $client_option in
    1)
      SELECTED_CLIENTS="valkey-glide"
      ;;
    2)
      SELECTED_CLIENTS="iovalkey"
      ;;
    3)
      SELECTED_CLIENTS="ioredis"
      ;;
    4)
      SELECTED_CLIENTS="valkey-glide:cluster"
      ;;
    5)
      SELECTED_CLIENTS="iovalkey:cluster"
      ;;
    6)
      SELECTED_CLIENTS="ioredis:cluster"
      ;;
    7)
      SELECTED_CLIENTS="valkey-glide iovalkey ioredis"
      ;;
    8)
      SELECTED_CLIENTS="valkey-glide:cluster iovalkey:cluster ioredis:cluster"
      ;;
    9|"")
      SELECTED_CLIENTS="valkey-glide iovalkey ioredis valkey-glide:cluster iovalkey:cluster ioredis:cluster"
      ;;
    *)
      log_error "Invalid client selection. Exiting."
      exit 1
      ;;
  esac
  
  # Workload selection
  echo "Workload Options:"
  echo "  1. Light workload only"
  echo "  2. Heavy workload only"
  echo "  3. Both workloads (default)"
  echo
  read -p "Select workload type (1-3): " -n 1 workload_option
  echo
  
  case $workload_option in
    1)
      RUN_LIGHT_WORKLOAD=true
      RUN_HEAVY_WORKLOAD=false
      ;;
    2)
      RUN_LIGHT_WORKLOAD=false
      RUN_HEAVY_WORKLOAD=true
      ;;
    3|"")
      RUN_LIGHT_WORKLOAD=true
      RUN_HEAVY_WORKLOAD=true
      ;;
    *)
      log_error "Invalid workload selection. Exiting."
      exit 1
      ;;
  esac
  
  # Duration selection
  echo "Duration Mode:"
  echo "  1. Dynamic duration (120s for 50-100c, 180s for 500-1000c, +30s for cluster)"
  echo "  2. Fixed short duration (30s for all)"
  echo "  3. Fixed medium duration (120s for all)"
  echo "  4. Custom duration"
  echo
  read -p "Select duration mode (1-4): " -n 1 duration_option
  echo
  
  case $duration_option in
    1)
      USE_DYNAMIC_DURATION=true
      ;;
    2)
      USE_DYNAMIC_DURATION=false
      FIXED_DURATION=30
      ;;
    3)
      USE_DYNAMIC_DURATION=false
      FIXED_DURATION=120
      ;;
    4)
      USE_DYNAMIC_DURATION=false
      echo
      read -p "Enter custom duration in seconds: " custom_duration
      FIXED_DURATION="$custom_duration"
      ;;
    *)
      log_error "Invalid duration selection. Exiting."
      exit 1
      ;;
  esac
  
  # Concurrency selection
  echo
  echo "Concurrency Options:"
  echo "  1. Light load (50 100)"
  echo "  2. Medium load (50 100 500)"
  echo "  3. Heavy load (50 100 500 1000)"
  echo "  4. Extreme load (100 500 1000 2000)"
  echo "  5. Custom concurrency"
  echo
  read -p "Select concurrency option (1-5): " -n 1 concurrency_option
  echo
  
  case $concurrency_option in
    1)
      BENCHMARK_CONCURRENCY="50 100"
      ;;
    2)
      BENCHMARK_CONCURRENCY="50 100 500"
      ;;
    3)
      BENCHMARK_CONCURRENCY="50 100 500 1000"
      ;;
    4)
      BENCHMARK_CONCURRENCY="100 500 1000 2000"
      ;;
    5)
      echo
      read -p "Enter custom concurrency levels (space separated, e.g., '10 50 200'): " custom_concurrency
      BENCHMARK_CONCURRENCY="$custom_concurrency"
      ;;
    *)
      log_error "Invalid concurrency selection. Exiting."
      exit 1
      ;;
  esac
  
  # Summary
  echo
  echo "==============================================="
  echo "Benchmark Configuration Summary:"
  echo "==============================================="
  echo "Clients: $SELECTED_CLIENTS"
  echo "Workloads: $([ "$RUN_LIGHT_WORKLOAD" = "true" ] && echo -n "light ")$([ "$RUN_HEAVY_WORKLOAD" = "true" ] && echo -n "heavy")"
  if [ "$USE_DYNAMIC_DURATION" = "true" ]; then
    echo "Duration: Dynamic (120s for 50-100c, 180s for 500-1000c, +30s for cluster)"
  else
    echo "Duration: Fixed ${FIXED_DURATION}s"
  fi
  echo "Concurrency: $BENCHMARK_CONCURRENCY"
  echo "==============================================="
  echo
  read -p "Proceed with this configuration? (y/n): " -n 1 confirm
  echo
  
  if [[ ! $confirm =~ ^[Yy]$ ]]; then
    log "Benchmark cancelled by user."
    exit 0
  fi
}

# Parse command line arguments
parse_arguments "$@"

# Parse command line arguments first
parse_arguments "$@"

# Set default values if not provided
if [ -z "$SELECTED_CLIENTS" ]; then
  SELECTED_CLIENTS="valkey-glide iovalkey ioredis valkey-glide:cluster iovalkey:cluster ioredis:cluster"
fi
if [ -z "$BENCHMARK_CONCURRENCY" ]; then
  BENCHMARK_CONCURRENCY="50 100 500 1000"
fi
if [ "$RUN_LIGHT_WORKLOAD" = false ] && [ "$RUN_HEAVY_WORKLOAD" = false ]; then
  RUN_LIGHT_WORKLOAD=true
  RUN_HEAVY_WORKLOAD=true
fi
if [ "$USE_DYNAMIC_DURATION" = false ] && [ -z "$FIXED_DURATION" ]; then
  USE_DYNAMIC_DURATION=true
fi

# Set configuration from arguments if provided, otherwise run interactive mode
if should_run_interactive; then
  configure_benchmark
else
  set_config_from_args
  # Show non-interactive configuration summary
  echo "==============================================="
  echo "  Valkey vs Redis Rate Limiter Benchmark Suite "
  echo "==============================================="
  echo
  echo "Running in non-interactive mode with:"
  echo "Clients: $SELECTED_CLIENTS"
  echo "Workloads: $([ "$RUN_LIGHT_WORKLOAD" = "true" ] && echo -n "light ")$([ "$RUN_HEAVY_WORKLOAD" = "true" ] && echo -n "heavy")"
  if [ "$USE_DYNAMIC_DURATION" = "true" ]; then
    echo "Duration: Dynamic (120s for 50-100c, 180s for 500-1000c, +30s for cluster)"
  else
    echo "Duration: Fixed ${FIXED_DURATION}s"
  fi
  echo "Concurrency: $BENCHMARK_CONCURRENCY"
  echo "==============================================="
  echo
fi

# Start benchmark process
setup_environment
build_application
start_containers
run_benchmarks
generate_final_report
cleanup
show_results

exit 0
