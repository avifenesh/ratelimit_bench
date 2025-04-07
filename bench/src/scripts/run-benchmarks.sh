#!/bin/bash
#
# Advanced Benchmark Orchestration Script for Rate Limiter Testing
# This script automates testing of different rate limiter implementations
# with various concurrency levels and request types.

set -e

# Timestamp for this run
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="/home/ubuntu/ratelimit_bench/results/${TIMESTAMP}"
LOG_FILE="${RESULTS_DIR}/benchmark.log"
README_FILE="${RESULTS_DIR}/README.md"

# Default configurations
DEFAULT_DURATION=30
DEFAULT_CONCURRENCY_LEVELS=(10 50 100 500 1000)
DEFAULT_REQUEST_TYPES=("light" "heavy")
DEFAULT_RATE_LIMITER_TYPES=("redis-ioredis" "valkey")

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
    local rate_limiter_type=$1
    local test_name="${rate_limiter_type}"
    local log_file="${RESULTS_DIR}/server_${test_name}.log"
    
    log "Starting server with ${rate_limiter_type}..."
    
    # Stop any existing containers
    docker-compose down &>/dev/null || true
    
    # Start Redis or Valkey based on rate limiter type
    if [[ "$rate_limiter_type" == *"redis"* ]]; then
        log "Starting Redis container..."
        docker-compose up -d redis
    elif [[ "$rate_limiter_type" == "valkey" ]]; then
        log "Starting Valkey container..."
        docker-compose up -d valkey
    fi
    
    # Wait for Redis/Valkey to be ready
    sleep 5
    
    # Set environment variables for server
    export RATE_LIMITER_TYPE=${rate_limiter_type%%-*}  # Extract just 'redis' or 'valkey'
    export REDIS_HOST=localhost
    export REDIS_PORT=6379
    export VALKEY_HOST=localhost
    export VALKEY_PORT=6380
    
    # Start the server
    node /home/ubuntu/ratelimit_bench/src/server/index.js > "$log_file" 2>&1 &
    SERVER_PID=$!
    
    log "Server started with PID $SERVER_PID"
    
    # Wait for the server to be ready
    local max_retries=10
    local retry=0
    local server_ready=false
    
    while [ $retry -lt $max_retries ]; do
        if curl -s http://localhost:3000/health | grep -q "ok"; then
            server_ready=true
            break
        fi
        log "Waiting for server to be ready... ($retry/$max_retries)"
        sleep 2
        retry=$((retry + 1))
    done
    
    if [ "$server_ready" = false ]; then
        log "ERROR: Server failed to start within expected time"
        kill -9 $SERVER_PID 2>/dev/null || true
        return 1
    fi
    
    log "Server is ready"
    return 0
}

# Function to stop the server
stop_server() {
    log "Stopping server..."
    if [ ! -z "$SERVER_PID" ]; then
        kill -15 $SERVER_PID 2>/dev/null || true
        sleep 2
        kill -9 $SERVER_PID 2>/dev/null || true
    fi
    docker-compose down
    log "Server stopped"
}

# Function to run a single benchmark
run_benchmark() {
    local rate_limiter_type=$1
    local request_type=$2
    local concurrency=$3
    
    local test_name="${rate_limiter_type}_${request_type}_c${concurrency}"
    local results_file="${RESULTS_DIR}/${test_name}.json"
    
    log "Running benchmark: ${test_name}"
    
    # Environment variables for the benchmark
    export TARGET_HOST=localhost
    export TARGET_PORT=3000
    export REQUEST_TYPE=$request_type
    export CONCURRENCY=$concurrency
    export DURATION=$duration
    export MODE=$rate_limiter_type
    export RUN_ID=$TIMESTAMP
    export RESULTS_DIR=$RESULTS_DIR
    
    # Run the benchmark
    node /home/ubuntu/ratelimit_bench/src/loadtest/index.js > "${RESULTS_DIR}/${test_name}.log" 2>&1
    
    # Check if benchmark completed successfully
    if [ $? -ne 0 ]; then
        log "WARNING: Benchmark ${test_name} may have had errors. Check the log."
    else
        log "Benchmark ${test_name} completed successfully"
    fi
    
    # Let the system stabilize before the next benchmark
    sleep 5
}

# Process each rate limiter type
for rate_limiter_type in "${rate_limiter_types[@]}"; do
    log "=== Testing rate limiter: $rate_limiter_type ==="
    
    # Start the server with this rate limiter
    start_server "$rate_limiter_type"
    
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to start server with $rate_limiter_type, skipping this rate limiter"
        continue
    fi
    
    # Run benchmarks for each request type and concurrency level
    for request_type in "${request_types[@]}"; do
        for concurrency in "${concurrency_levels[@]}"; do
            run_benchmark "$rate_limiter_type" "$request_type" "$concurrency"
        done
    done
    
    # Stop the server
    stop_server
    
    log "Completed all tests for $rate_limiter_type"
done

# Generate a summary report
log "Generating summary report..."

echo "## Test Results Summary" >> "$README_FILE"
echo "" >> "$README_FILE"
echo "| Rate Limiter | Request Type | Concurrency | Requests/sec | Avg Response Time (ms) | P95 Response Time (ms) | Success Rate (%) |" >> "$README_FILE"
echo "| ------------ | ------------ | ----------- | ------------ | ---------------------- | ---------------------- | ---------------- |" >> "$README_FILE"

# Find and process all JSON result files
for result_file in "$RESULTS_DIR"/*.json; do
    # Skip if no files found
    [ -e "$result_file" ] || continue
    
    # Extract data from the JSON file
    rate_limiter=$(jq -r '.testConfig.mode' "$result_file")
    request_type=$(jq -r '.testConfig.requestType' "$result_file")
    concurrency=$(jq -r '.testConfig.concurrency' "$result_file")
    rps=$(jq -r '.summary.requestsPerSecond' "$result_file")
    avg_resp=$(jq -r '.responseTimes.avg' "$result_file")
    p95_resp=$(jq -r '.responseTimes.p95' "$result_file")
    success_rate=$(jq -r '.summary.successRate' "$result_file")
    
    # Format the numbers
    rps=$(printf "%.2f" $rps)
    avg_resp=$(printf "%.2f" $avg_resp)
    p95_resp=$(printf "%.2f" $p95_resp)
    success_rate=$(printf "%.2f" $success_rate)
    
    # Add to the report
    echo "| $rate_limiter | $request_type | $concurrency | $rps | $avg_resp | $p95_resp | $success_rate |" >> "$README_FILE"
done

# Add charts section (placeholder for now)
echo "" >> "$README_FILE"
echo "## Performance Charts" >> "$README_FILE"
echo "" >> "$README_FILE"
echo "Charts will be generated separately using the JSON data files." >> "$README_FILE"

log "Benchmark suite completed successfully!"
log "Results saved to: $RESULTS_DIR"
log "Summary report: $README_FILE"

echo "Benchmark suite completed successfully!"
echo "Results saved to: $RESULTS_DIR"
echo "Summary report: $README_FILE"

exit 0
