# Rate Limiter Benchmark

A comprehensive benchmarking system to compare rate limiters under production-like conditions.

## Overview

This benchmark evaluates the performance of various rate limiter implementations from the `rate-limiter-flexible` library:

- Valkey-Glide client (`@valkey/valkey-glide`)
- IOValkey client (`iovalkey`)
- IORedis client (`ioredis`)
- Node-Redis client (`redis`)

The benchmark includes testing both standalone instances and cluster configurations, simulating real-world production conditions with:

- Multiple worker processes via Node.js worker threads model
- Optional Node.js cluster mode for horizontal scaling
- Redis and Valkey cluster support with 3 shards (primary + replica)
- Proper warm-up and cool-down phases
- Clean environment between test runs
- Comprehensive metrics collection

## Project Structure

```
bench/
├── docker/                    # Docker configuration
│   ├── docker-compose.yml                 # Docker Compose for standalone Redis/Valkey
│   ├── docker-compose-redis-cluster.yml   # Docker Compose for Redis cluster
│   ├── docker-compose-valkey-cluster.yml  # Docker Compose for Valkey cluster
│   ├── prometheus.yml                     # Prometheus configuration
│   └── grafana/                           # Grafana dashboards and provisioning
├── src/
│   ├── server/                # Modular server implementation
│   │   ├── config/            # Configuration settings
│   │   ├── lib/               # Core libraries
│   │   ├── middleware/        # Fastify middleware
│   │   ├── routes/            # API routes
│   │   ├── utils/             # Utility functions
│   │   ├── workers/           # Worker thread implementations
│   │   └── index.js           # Server entry point
│   ├── k6/                    # k6 load testing scripts
│   │   └── benchmark.js       # k6 benchmark script
│   └── node-loadtest/         # Alternative Node.js load testing (fallback)
│       └── benchmark.js       # Node.js benchmark script (auto-generated)
├── results/                   # Benchmark results (generated)
├── run-benchmark.sh           # Main benchmark orchestration script
├── redis.conf                 # Redis configuration
├── valkey.conf                # Valkey configuration
├── .eslintrc.json             # ESLint configuration
├── package.json               # Project dependencies
└── README.md                  # This file
```

## Requirements

- Node.js 20+
- Docker and Docker Compose
- k6 (optional, will fallback to autocannon or Node.js if not available)

## How to Run

### Install Dependencies

```bash
npm install
```

### Start Redis and Valkey Servers

```bash
# Start standalone Redis and Valkey
npm run docker:up

# Start Redis Cluster (3 shards, 1 primary + 1 replica each)
npm run docker:redis-cluster:up

# Start Valkey Cluster (3 shards, 1 primary + 1 replica each)
npm run docker:valkey-cluster:up
```

### Start the Benchmark Server

```bash
# Standard standalone mode
npm start

# With Node.js cluster mode (different from Redis/Valkey clustering)
npm run start:cluster

# With specific client libraries
npm run start:valkey-glide
npm run start:valkey-io
npm run start:redis-ioredis
npm run start:redis-node

# With Redis Cluster
npm run start:redis-cluster

# With Valkey Cluster
npm run start:valkey-cluster
```

### Run Benchmarks

```bash
# Run standard benchmark
npm run benchmark

# Run benchmark with Node.js cluster mode
npm run benchmark:cluster

# Run benchmark against Redis Cluster
npm run benchmark:redis-cluster

# Run benchmark against Valkey Cluster
npm run benchmark:valkey-cluster

# Run with custom settings
DURATION=5m CONCURRENCY=100 WORKERS=4 RATE_LIMIT=200 RATE_DURATION=60 npm run benchmark
```

### Cleanup

```bash
# Stop standalone Redis and Valkey
npm run docker:down

# Stop Redis Cluster
npm run docker:redis-cluster:down

# Stop Valkey Cluster
npm run docker:valkey-cluster:down
```

## Custom Configuration

You can customize the benchmark by setting environment variables:

- `MODE`: Client library to use (valkey-glide, valkey-io, redis-ioredis, redis-node)
- `DURATION`: Test duration (e.g., "2m", "5m")
- `CONCURRENCY`: Number of concurrent users for load testing
- `WORKERS`: Number of worker threads
- `RATE_LIMIT`: Maximum points for rate limiting
- `RATE_DURATION`: Duration in seconds for rate limiting
- `USE_CLUSTER`: Whether to use Node.js cluster mode (true/false)
- `USE_REDIS_CLUSTER`: Whether to use Redis Cluster (true/false)
- `USE_VALKEY_CLUSTER`: Whether to use Valkey Cluster (true/false)
- `CLUSTER_NODES`: JSON string defining Redis cluster nodes
- `VALKEY_CLUSTER_NODES`: JSON string defining Valkey cluster nodes

## Benchmark Methodology

Each benchmark follows these steps:

1. **Setup Phase**

   - Start Redis/Valkey servers (standalone or cluster)
   - Start Fastify server with worker processes
   - Configure rate limiters

2. **Warm-up Phase**

   - Allow connections to establish
   - Prime caches and database connections

3. **Test Phase**

   - Run load test with configured virtual users
   - Collect metrics from server and databases

4. **Cool-down Phase**

   - Gracefully stop load test
   - Collect final metrics

5. **Cleanup Phase**

   - Stop server and containers
   - Save all metrics to results directory

6. **Analysis Phase**
   - Generate summary report comparing all rate limiters

## Metrics Collected

- **Performance Metrics**

  - Requests per second (throughput)
  - Response time (avg, p50, p95, p99)
  - Success/failure rates

- **Rate Limiter Metrics**

  - Rate limit hits
  - Rate limit blocks

- **Resource Usage**
  - CPU usage (server and database)
  - Memory usage
  - Connection stats

## Cluster Testing Features

This benchmark includes comprehensive support for testing rate limiters against Redis and Valkey clusters:

### Redis Cluster

- 3 primary nodes + 3 replica nodes (3 shards total)
- Automatic cluster configuration
- Works with rate-limiter-flexible's Redis cluster support
- Tests fault tolerance and performance distribution

### Valkey Cluster

- 3 primary nodes + 3 replica nodes (3 shards total)
- Compatible with Redis Cluster specification
- Tests advanced rate limiting with distributed state
- Provides insights into scaling and reliability

### Benefits of Cluster Testing

- More realistic production environment simulation
- Tests rate limiting with distributed state
- Evaluates performance under sharded data conditions
- Demonstrates scaling characteristics of different implementations
- Provides insights into fault tolerance and reliability

## Comparing Rate Limiter Implementations

This benchmark helps you choose the right rate limiter implementation for your needs:

1. **Standalone Performance**: How each implementation performs with a single Redis/Valkey instance
2. **Cluster Performance**: How each implementation scales across a Redis/Valkey cluster
3. **Node.js Scalability**: How performance changes when using Node.js clustering
4. **Resource Efficiency**: CPU and memory usage of each implementation

## Why Valkey and Valkey-Glide?

### Valkey Advantages

Valkey is a modern, high-performance, in-memory data store compatible with Redis but offering several advantages:

- **Better Performance**: Optimized for high-throughput scenarios with improved memory management
- **Modern Architecture**: Built using contemporary software development practices
- **Active Development**: Continuously improved with performance and reliability enhancements
- **Redis Compatibility**: Drop-in replacement for Redis with enhanced capabilities

### Valkey-Glide Client Benefits

The Valkey-Glide client (`@valkey/valkey-glide`) is the recommended client for Node.js applications using Valkey:

- **TypeScript Native**: Built from the ground up with TypeScript for excellent developer experience
- **Modern Promise API**: Clean, async/await friendly interface
- **Superior Performance**: Optimized communication protocol for minimizing latency
- **Cluster-Safe**: Properly handles cluster operations without race conditions
- **Resource Efficient**: Low memory footprint and efficient connection management

For rate limiting use cases, Valkey-Glide provides enhanced throughput and reliability under high load, making it an excellent choice for production services. This benchmark aims to quantify these advantages with real-world performance metrics.
