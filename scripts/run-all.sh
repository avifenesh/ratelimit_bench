#!/bin/bash

set -e

# --- Configuration ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_BASE_DIR="$(pwd)/results"
RESULTS_DIR="${RESULTS_BASE_DIR}/${TIMESTAMP}"

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
  log "Starting Docker containers..."

  # Clean the project before starting containers
  log "Cleaning the project..."
  npm run clean
  
  # Stop any running containers first
  log "Stopping any existing containers..."
  docker-compose down -v &>/dev/null || true
  
  # Copy built files to Docker volumes if needed
  log "Copying built application code to Docker volume..."
  if [ ! -d "./dist" ]; then
    log "No built code found. Attempting to build the application again..."
    npm run build
  fi
  
  if [ -d "./dist" ]; then
    mkdir -p ./docker/app
    cp -r ./dist ./docker/app/
    cp package.json ./docker/app/
    log "Application code copied to Docker volume"
  else
    log_error "No built code found even after rebuilding. Check for build errors."
    exit 1
  fi
  
  # Create the benchmark network explicitly
  log "Creating benchmark network..."
  docker network create benchmark-network 2>/dev/null || true
  
  # Start Valkey containers first (prioritizing Valkey implementations)
  log "Starting Valkey standalone..."
  docker-compose up -d valkey
  
  # Ensure Valkey standalone is connected to the benchmark network
  log "Connecting Valkey standalone to benchmark network..."
  docker network connect benchmark-network benchmark-valkey 2>/dev/null || true
  
  log "Starting Valkey cluster..."
  docker-compose -f docker-compose-valkey-cluster.yml up -d
  
  # Connect Valkey cluster nodes to benchmark network
  log "Connecting Valkey cluster nodes to benchmark network..."
  for i in {1..6}; do
    docker network connect benchmark-network ratelimit_bench-valkey-node$i-1 2>/dev/null || true
  done
  
  # Then start Redis containers
  log "Starting Redis standalone..."
  docker-compose up -d redis
  
  # Ensure Redis standalone is connected to the benchmark network
  log "Connecting Redis standalone to benchmark network..."
  docker network connect benchmark-network benchmark-redis 2>/dev/null || true
  
  log "Starting Redis cluster..."
  docker-compose -f docker-compose-redis-cluster.yml up -d
  
  # Connect Redis cluster nodes to benchmark network
  log "Connecting Redis cluster nodes to benchmark network..."
  for i in {1..6}; do
    docker network connect benchmark-network ratelimit_bench-redis-node$i-1 2>/dev/null || true
  done
  
  # Make sure all containers are on the same network
  log "Ensuring all containers are on the benchmark network..."
  for container in $(docker ps --format "{{.Names}}"); do
    docker network connect benchmark-network $container 2>/dev/null || true
  done
  
  # Verify network connectivity
  log "Verifying network connectivity between containers..."
  # Check if Valkey container is accessible
  docker exec benchmark-valkey redis-cli PING 2>/dev/null | grep -q "PONG" && \
    log "Valkey container is accessible" || log "WARNING: Valkey container is not responding"
  
  # Check if Redis container is accessible
  docker exec benchmark-redis redis-cli PING 2>/dev/null | grep -q "PONG" && \
    log "Redis container is accessible" || log "WARNING: Redis container is not responding"
  
  # Wait for containers to be ready
  log "Waiting for containers to be ready..."
  sleep 10
  
  log_success "All containers started successfully"
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
  
  if [ "$RUN_LONG_BENCHMARKS" = "true" ]; then
    # For full benchmark, run with multiple concurrency levels and longer duration
    CONCURRENCY_LEVELS="10 50 100 500 1000"
    
    # Set workload types based on user selection
    WORKLOAD_TYPES=""
    if [ "$RUN_LIGHT_WORKLOAD" = "true" ]; then
      WORKLOAD_TYPES="${WORKLOAD_TYPES}light "
    fi
    if [ "$RUN_HEAVY_WORKLOAD" = "true" ]; then
      WORKLOAD_TYPES="${WORKLOAD_TYPES}heavy"
    fi
    REQUEST_TYPES="$WORKLOAD_TYPES"
    
    # Run light workload benchmark if selected
    if [ "$RUN_LIGHT_WORKLOAD" = "true" ]; then
      # Run light workload with short duration
      log "Running light workload benchmark (short duration)..."
      DURATION=30 BENCHMARK_REQUEST_TYPES="light" $BENCHMARK_SCRIPT
      
      # Run light workload with long duration
      log "Running light workload benchmark (long duration)..."
      DURATION=120 BENCHMARK_REQUEST_TYPES="light" $BENCHMARK_SCRIPT
    fi
    
    # Run heavy workload benchmark if selected
    if [ "$RUN_HEAVY_WORKLOAD" = "true" ]; then
      # Run heavy workload with short duration and reduced complexity
      log "Running heavy workload benchmark (short duration)..."
      DURATION=30 COMPUTATION_COMPLEXITY=5 BENCHMARK_REQUEST_TYPES="heavy" $BENCHMARK_SCRIPT
      
      # Run heavy workload with long duration and reduced complexity
      log "Running heavy workload benchmark (long duration with reduced complexity)..."
      DURATION=120 COMPUTATION_COMPLEXITY=5 BENCHMARK_REQUEST_TYPES="heavy" $BENCHMARK_SCRIPT
    fi
  else
    # For quick benchmark, run only 30-second tests with 50 connections
    log "Running quick benchmarks (30s only)..."
    
    # Force 30-second duration for all tests
    export DURATION=30
    
    # Force single concurrency level
    export CONCURRENCY=50
    
    # Only run one test for each implementation (no long tests)
    export SKIP_LONG_TESTS=true
    
    # Set workload types based on user selection
    WORKLOAD_TYPES=""
    if [ "$RUN_LIGHT_WORKLOAD" = "true" ]; then
      WORKLOAD_TYPES="${WORKLOAD_TYPES}light "
    fi
    if [ "$RUN_HEAVY_WORKLOAD" = "true" ]; then
      WORKLOAD_TYPES="${WORKLOAD_TYPES}heavy"
    fi
    export REQUEST_TYPES="$WORKLOAD_TYPES"
    
    # Run light workload benchmark if selected
    if [ "$RUN_LIGHT_WORKLOAD" = "true" ]; then
      log "Running light workload benchmark (30s, 50 connections)..."
      BENCHMARK_REQUEST_TYPES="light" $BENCHMARK_SCRIPT
    fi
    
    # Run heavy workload benchmark if selected
    if [ "$RUN_HEAVY_WORKLOAD" = "true" ]; then
      log "Running heavy workload benchmark (30s, 50 connections)..."
      COMPUTATION_COMPLEXITY=10 BENCHMARK_REQUEST_TYPES="heavy" $BENCHMARK_SCRIPT
    fi
  fi
  
  # Unset environment variables
  unset CONTAINERS_ALREADY_RUNNING
  unset BENCHMARK_NETWORK
  unset RESULTS_DIR_HOST
  
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
    docker-compose down -v
    docker-compose -f docker-compose-valkey-cluster.yml down -v
    docker-compose -f docker-compose-redis-cluster.yml down -v
    log "All Docker containers stopped"
  else
    log "Docker containers left running"
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

# Clear screen and display header
clear
echo "==============================================="
echo "  Valkey vs Redis Rate Limiter Benchmark Suite "
echo "==============================================="
echo
echo "This script will run a complete benchmark comparing"
echo "Valkey and Redis rate limiting implementations."
echo
echo "Options:"
echo "  1. Quick Benchmark (30s runs)"
echo "  2. Full Benchmark (30s + 120s runs)"
echo
echo "Workload Options:"
echo "  a. All workloads (default)"
echo "  l. Light workload only"
echo "  h. Heavy workload only"
echo
read -p "Select benchmark option (1/2): " -n 1 benchmark_option
echo
read -p "Select workload type (a/l/h): " -n 1 workload_type
echo

# Set benchmark type
case $benchmark_option in
  1)
    RUN_LONG_BENCHMARKS=false
    ;;
  2)
    RUN_LONG_BENCHMARKS=true
    ;;
  *)
    log_error "Invalid benchmark selection. Exiting."
    exit 1
    ;;
esac

# Set workload type
case $workload_type in
  a|A|"") # Default to all if empty
    RUN_LIGHT_WORKLOAD=true
    RUN_HEAVY_WORKLOAD=true
    ;;
  l|L)
    RUN_LIGHT_WORKLOAD=true
    RUN_HEAVY_WORKLOAD=false
    ;;
  h|H)
    RUN_LIGHT_WORKLOAD=false
    RUN_HEAVY_WORKLOAD=true
    ;;
  *)
    log_error "Invalid workload selection. Exiting."
    exit 1
    ;;
esac

# Start benchmark process
setup_environment
build_application
start_containers
run_benchmarks
generate_final_report
cleanup
show_results

exit 0
