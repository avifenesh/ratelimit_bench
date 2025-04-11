#!/bin/bash
#
# Advanced Benchmark Orchestration Script for Rate Limiter Testing
# This script automates testing of different rate limiter implementations
# with various concurrency levels and request types.

set -e

# Timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
# Use relative path for results
RESULTS_DIR="results/${TIMESTAMP}"
LOG_FILE="${RESULTS_DIR}/benchmark.log"
README_FILE="${RESULTS_DIR}/README.md"

# Default configurations
DEFAULT_DURATION=30
DEFAULT_CONCURRENCY_LEVELS=(10 50 100 500 1000)
DEFAULT_REQUEST_TYPES=("light" "heavy")
# Rate limiter types with Valkey implementations first (per project priority)
DEFAULT_RATE_LIMITER_TYPES=(
    # Standalone configurations
    "valkey-glide" 
    "valkey-io" 
    "redis-ioredis" 
    "redis-node"
    # Cluster configurations
    "valkey-glide:cluster"
    "valkey-io:cluster"
    "redis-ioredis:cluster"
)

# Parse command line arguments
duration=${1:-$DEFAULT_DURATION}
concurrency_levels=(${2:-${DEFAULT_CONCURRENCY_LEVELS[@]}})
request_types=(${3:-${DEFAULT_REQUEST_TYPES[@]}})
rate_limiter_types=(${4:-${DEFAULT_RATE_LIMITER_TYPES[@]}})

# Function for logging
log() {
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1"
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

# Make sure directories exist
mkdir -p "$RESULTS_DIR"
touch "$LOG_FILE"

# Create README with test information
cat > "$README_FILE" << EOF
# Rate Limiter Benchmark Results

## Test Summary
- **Date:** $(date)
- **Duration:** ${duration}s per test
- **Concurrency Levels:** ${concurrency_levels[@]}
- **Request Types:** ${request_types[@]}
- **Rate Limiter Types:** ${rate_limiter_types[@]}

## System Information
- **Hostname:** $(hostname)
- **CPU:** $(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
- **CPU Cores:** $(grep -c processor /proc/cpuinfo)
- **Memory:** $(free -h | grep Mem | awk '{print $2}')
- **OS:** $(uname -srm)
- **Kernel:** $(uname -r)

## Results Summary
(Results will be summarized here after all tests complete)

EOF

log "Starting benchmark suite with:"
log "- Duration: ${duration}s per test"
log "- Concurrency levels: ${concurrency_levels[*]}"
log "- Request types: ${request_types[*]}"
log "- Rate limiter types: ${rate_limiter_types[*]}"
log "Results will be saved to: $RESULTS_DIR"

# Function to start the server
start_server() {
    local rate_limiter_input=$1
    local use_cluster=false
    local rate_limiter_type=$rate_limiter_input
    
    # Parse rate limiter type to handle cluster configurations
    if [[ "$rate_limiter_input" == *":cluster" ]]; then
        rate_limiter_type=${rate_limiter_input%:cluster}
        use_cluster=true
    fi
    
    local test_name="${rate_limiter_type}"
    if [[ "$use_cluster" == "true" ]]; then
        test_name="${test_name}_cluster"
    fi
    
    local log_file="${RESULTS_DIR}/server_${test_name}.log"

    log "Starting server with ${rate_limiter_type} (cluster mode: ${use_cluster})..."

    # Stop any existing containers using the root docker-compose files
    docker-compose -f docker-compose.yml down --remove-orphans &>/dev/null || true
    docker-compose -f docker-compose-redis-cluster.yml down --remove-orphans &>/dev/null || true
    docker-compose -f docker-compose-valkey-cluster.yml down --remove-orphans &>/dev/null || true

    # Start Redis or Valkey based on rate limiter type and cluster mode
    if [[ "$rate_limiter_type" == *"redis"* ]]; then
        if [[ "$use_cluster" == "true" ]]; then
            log "Starting Redis Cluster containers..."
            docker-compose -f docker-compose-redis-cluster.yml up -d
            # Wait a bit longer for cluster to initialize
            sleep 15
            export USE_REDIS_CLUSTER=true
        else
            log "Starting standalone Redis container..."
            docker-compose -f docker-compose.yml up -d redis
            export USE_REDIS_CLUSTER=false
        fi
    elif [[ "$rate_limiter_type" == *"valkey"* ]]; then
        if [[ "$use_cluster" == "true" ]]; then
            log "Starting Valkey Cluster containers..."
            docker-compose -f docker-compose-valkey-cluster.yml up -d
            # Wait a bit longer for cluster to initialize
            sleep 15
            export USE_VALKEY_CLUSTER=true
        else
            log "Starting standalone Valkey container..."
            docker-compose -f docker-compose.yml up -d valkey
            export USE_VALKEY_CLUSTER=false
        fi
    fi

    # Wait for Redis/Valkey to be ready
    log "Waiting for database container..."
    sleep 10 # Increased wait time

    # Set environment variables for server
    export MODE=${rate_limiter_type} # Pass the full mode like 'redis-ioredis'
    
    # Cluster flags are already set in the conditional logic above
    # Set connection details
    export REDIS_HOST=localhost
    export REDIS_PORT=6379 # Default Redis port
    export VALKEY_HOST=localhost
    export VALKEY_PORT=6380 # Default Valkey port from root docker-compose.yml

    # Start the server using ts-node
    log "Starting Node.js server process..."
    ts-node src/server/index.ts > "$log_file" 2>&1 &
    SERVER_PID=$!

    log "Server process started with PID $SERVER_PID"

    # Wait for the server to be ready
    local max_retries=15 # Increased retries
    local retry=0
    local server_ready=false

    while [ $retry -lt $max_retries ]; do
        # Assuming server runs on port 3000 by default from config
        if curl -s http://localhost:3000/health | grep -q "ok"; then
            server_ready=true
            break
        fi
        log "Waiting for server to be ready... attempt ($((retry + 1))/$max_retries)"
        sleep 3 # Increased sleep
        retry=$((retry + 1))
    done

    if [ "$server_ready" = false ]; then
        log "ERROR: Server failed to start within expected time. Check $log_file"
        kill -9 $SERVER_PID 2>/dev/null || true
        # Attempt to stop containers as well
        if [[ "$rate_limiter_type" == *"redis"* ]]; then
            docker-compose -f docker-compose.yml stop redis
        elif [[ "$rate_limiter_type" == *"valkey"* ]]; then
            docker-compose -f docker-compose.yml stop valkey
        fi
        return 1
    fi

    log "Server is ready"
    return 0
}

# Function to stop the server
stop_server() {
    log "Stopping server process..."
    if [ ! -z "$SERVER_PID" ]; then
        kill -15 $SERVER_PID 2>/dev/null || true
        sleep 2
        kill -9 $SERVER_PID 2>/dev/null || true
        SERVER_PID=""
    fi
    log "Stopping Docker containers..."
    # Stop relevant containers based on the last run type (this might need refinement)
    docker-compose -f docker-compose.yml down --remove-orphans
    log "Server and containers stopped"
}

# Function to run a single benchmark
run_benchmark() {
    local rate_limiter_input=$1
    local request_type=$2
    local concurrency=$3
    
    # Parse rate limiter type and cluster mode
    local use_cluster=false
    local rate_limiter_type=$rate_limiter_input
    
    if [[ "$rate_limiter_input" == *":cluster" ]]; then
        rate_limiter_type=${rate_limiter_input%:cluster}
        use_cluster=true
    fi

    local test_name="${rate_limiter_type}"
    if [[ "$use_cluster" == "true" ]]; then
        test_name="${test_name}_cluster"
    fi
    
    test_name="${test_name}_${request_type}_c${concurrency}"
    local results_file="${RESULTS_DIR}/${test_name}.json" # Save JSON here
    local log_file="${RESULTS_DIR}/${test_name}.log" # Save stdout/stderr here

    log "Running benchmark: ${test_name}"

    # Environment variables for the benchmark loadtest script
    export TARGET_HOST=localhost
    export TARGET_PORT=3000 # Assuming server runs on 3000
    export REQUEST_TYPE=$request_type
    export CONCURRENCY=$concurrency
    export DURATION=$duration # Use the script's duration variable
    export MODE=$rate_limiter_type # Pass the mode being tested
    export RUN_ID=$TIMESTAMP
    export RESULTS_DIR=$RESULTS_DIR # Pass results dir for saving output
    export RESULT_FILE=$results_file # Explicitly pass the target JSON file path
    export USE_CLUSTER=$use_cluster # Pass cluster flag to benchmark tool

    # Run the benchmark using the consolidated autocannon implementation
    # Using the more comprehensive benchmark/autocannon.ts with resource monitoring
    ts-node src/benchmark/autocannon.ts > "$log_file" 2>&1

    # Check if benchmark completed successfully
    if [ $? -ne 0 ]; then
        log "ERROR: Benchmark ${test_name} failed. Check $log_file."
        # Optionally check if the results file was created anyway
        if [ ! -f "$results_file" ]; then
           log "WARNING: Results file ${results_file} not found."
        fi
    else
        log "Benchmark ${test_name} completed."
        if [ ! -f "$results_file" ]; then
           log "WARNING: Benchmark process succeeded but results file ${results_file} not found. Check loadtest script output in $log_file."
        fi
    fi

    # Let the system stabilize before the next benchmark
    sleep 5
}

# Trap SIGINT and SIGTERM to ensure cleanup
trap "log 'Caught signal, stopping server...'; stop_server; exit 1" SIGINT SIGTERM

# Process each rate limiter type
for rate_limiter_type in "${rate_limiter_types[@]}"; do
    log "=== Testing rate limiter: $rate_limiter_type ==="

    # Start the server with this rate limiter
    start_server "$rate_limiter_type"

    if [ $? -ne 0 ]; then
        log "ERROR: Failed to start server with $rate_limiter_type, skipping this rate limiter"
        continue # Skip to the next rate limiter type
    fi

    # Run benchmarks for each request type and concurrency level
    for request_type in "${request_types[@]}"; do
        for concurrency in "${concurrency_levels[@]}"; do
            run_benchmark "$rate_limiter_type" "$request_type" "$concurrency"
        done
    done

    # Stop the server after testing this rate limiter type
    stop_server

    log "Completed all tests for $rate_limiter_type"
    sleep 5 # Pause before starting the next type
done

# Generate a summary report
log "Generating summary report..."

echo "## Test Results Summary" >> "$README_FILE"
echo "" >> "$README_FILE"
echo "| Rate Limiter | Request Type | Concurrency | Requests/sec | Avg Response Time (ms) | P95 Response Time (ms) | Success Rate (%) | Rate Limited (%) |" >> "$README_FILE"
echo "| ------------ | ------------ | ----------- | ------------ | ---------------------- | ---------------------- | ---------------- | ---------------- |" >> "$README_FILE"

# Find and process all JSON result files
shopt -s nullglob # Prevent loop from running if no files match
for result_file in "$RESULTS_DIR"/*.json; do
    # Skip if file is empty or not valid JSON
    if [ ! -s "$result_file" ] || ! jq . "$result_file" > /dev/null 2>&1; then
        log "WARNING: Skipping invalid or empty results file: $result_file"
        continue
    fi

    # Extract data using jq - check if keys exist before accessing
    rate_limiter=$(jq -r '.testConfig.mode // "N/A"' "$result_file")
    request_type=$(jq -r '.testConfig.requestType // "N/A"' "$result_file")
    concurrency=$(jq -r '.testConfig.concurrency // "N/A"' "$result_file")
    rps=$(jq -r '.summary.requestsPerSecond // 0' "$result_file")
    avg_resp=$(jq -r '.responseTimes.avg // 0' "$result_file")
    p95_resp=$(jq -r '.responseTimes.p95 // 0' "$result_file")
    success_rate=$(jq -r '.summary.successRate // 0' "$result_file")
    limited_rate=$(jq -r '.summary.rateLimitedRate // 0' "$result_file") # Added rate limited rate

    # Format the numbers safely
    rps=$(printf "%.2f" "$rps" 2>/dev/null || echo "N/A")
    avg_resp=$(printf "%.2f" "$avg_resp" 2>/dev/null || echo "N/A")
    p95_resp=$(printf "%.2f" "$p95_resp" 2>/dev/null || echo "N/A")
    success_rate=$(printf "%.2f" "$success_rate" 2>/dev/null || echo "N/A")
    limited_rate=$(printf "%.2f" "$limited_rate" 2>/dev/null || echo "N/A") # Format rate limited rate

    # Add to the report
    echo "| $rate_limiter | $request_type | $concurrency | $rps | $avg_resp | $p95_resp | $success_rate | $limited_rate |" >> "$README_FILE"
done
shopt -u nullglob # Restore default glob behavior

# Add charts section (placeholder for now)
echo "" >> "$README_FILE"
echo "## Performance Charts" >> "$README_FILE"
echo "" >> "$README_FILE"
echo "Charts can be generated separately using the JSON data files in this directory." >> "$README_FILE"

log "Benchmark suite completed successfully!"
log "Results saved to: $RESULTS_DIR"
log "Summary report: $README_FILE"

echo "Benchmark suite completed successfully!"
echo "Results saved to: $RESULTS_DIR"
echo "Summary report: $README_FILE"

exit 0
