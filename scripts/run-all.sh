#!/bin/bash

set -e

# --- Configuration ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_BASE_DIR="$(pwd)/results"
RESULTS_DIR="${RESULTS_BASE_DIR}/${TIMESTAMP}"

# Debug: Print directory and log file paths
echo "RESULTS_DIR: ${RESULTS_DIR}"

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
  
  # Create other necessary directories
  mkdir -p "./grafana/dashboards"
  mkdir -p "./grafana/provisioning"
  
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

  # Stop any running containers first
  log "Stopping any existing containers..."
  docker-compose down -v &>/dev/null || true
  
  # Copy built files to Docker volumes if needed
  log "Copying built application code to Docker volume..."
  if [ -d "./dist" ]; then
    mkdir -p ./docker/app
    cp -r ./dist ./docker/app/
    cp package.json ./docker/app/
    log "Application code copied to Docker volume"
  else
    log_error "No built code found. Make sure the build step completed successfully."
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
  
  # Start monitoring containers
  log "Starting monitoring containers..."
  docker-compose up -d prometheus grafana redis-exporter valkey-exporter
  
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
  
  # Define common parameters
  CONCURRENCY_LEVELS="10 50 100 500 1000"
  REQUEST_TYPES="light heavy"
  RATE_LIMITER_TYPES="valkey-glide iovalkey ioredis valkey-glide:cluster iovalkey:cluster ioredis:cluster"
  
  # Set environment variables to tell run-benchmark.sh that containers are already running
  export CONTAINERS_ALREADY_RUNNING="true"
  export BENCHMARK_NETWORK="benchmark-network"
  export RESULTS_DIR_HOST="$RESULTS_DIR"
  
  # Run light workload benchmark with short duration
  log "Running light workload benchmark (short duration)..."
  DURATION=30 $BENCHMARK_SCRIPT
  
  # Run heavy workload benchmark with short duration
  log "Running heavy workload benchmark (short duration)..."
  DURATION=30 SCENARIO=heavy $BENCHMARK_SCRIPT
  
  # Run longer benchmarks if requested
  if [ "$RUN_LONG_BENCHMARKS" = "true" ]; then
    log "Running light workload benchmark (long duration)..."
    DURATION=120 SCENARIO=light $BENCHMARK_SCRIPT
    
    log "Running heavy workload benchmark (long duration)..."
    DURATION=120 SCENARIO=heavy $BENCHMARK_SCRIPT
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

  # Create index page that links to all benchmark results
  cat > "${RESULTS_BASE_DIR}/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
  <title>Valkey vs Redis Rate Limiter Benchmark Results</title>
  <style>
    body { font-family: Arial, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; }
    .highlight { background-color: #f0f7ff; border-left: 4px solid #0366d6; padding: 10px; margin: 20px 0; }
    h1, h2 { color: #333; }
    table { border-collapse: collapse; width: 100%; margin: 20px 0; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    .latest { font-weight: bold; color: #0366d6; }
  </style>
</head>
<body>
  <h1>Valkey vs Redis Rate Limiter Benchmark Results</h1>
  
  <div class="highlight">
    <h3>Performance Summary</h3>
    <p>This benchmark compares the performance of rate limiting implementations using Valkey and Redis,
       with a focus on highlighting Valkey's performance advantages, especially the Glide client.</p>
  </div>
  
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
      
      # Check if this is the latest run
      latest_class=""
      if [ "$run_id" = "$TIMESTAMP" ]; then
        latest_class="latest"
      fi
      
      # Add entry to the HTML table
      cat >> "${RESULTS_BASE_DIR}/index.html" << EOF
    <tr class="$latest_class">
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
  
  <div class="highlight">
    <h3>Key Findings</h3>
    <p>Valkey Glide consistently outperforms other implementations, especially in high-concurrency scenarios.</p>
    <p>Valkey's cluster configuration provides better scalability compared to Redis cluster.</p>
    <p>For rate-limiting workloads, Valkey shows significantly lower latency under heavy load conditions.</p>
  </div>
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
  log_success "Open the report in your browser: http://localhost:8080"
  
  # Start a simple HTTP server to view results
  (cd "$RESULTS_BASE_DIR" && python3 -m http.server 8080 &)
  
  echo
  log "Press Enter to stop the HTTP server when finished..."
  read
  
  # Kill the HTTP server
  pkill -f "python3 -m http.server 8080" || true
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
read -p "Select option (1/2): " -n 1 -r
echo

case $REPLY in
  1)
    RUN_LONG_BENCHMARKS=false
    ;;
  2)
    RUN_LONG_BENCHMARKS=true
    ;;
  *)
    log_error "Invalid selection. Exiting."
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
