/**
 * Cluster utilities
 * Implements Node.js cluster support
 */

const cluster = require('cluster');
const os = require('os');
const config = require('../config');

/**
 * Starts the server in cluster mode
 * @param {Function} startWorker - Function to start a worker process
 */
function setupCluster(startWorker) {
  if (cluster.isPrimary) {
    const numCPUs = config.workers || os.cpus().length;

    console.log(`Primary ${process.pid} is running`);
    console.log(`Starting ${numCPUs} workers in cluster mode`);

    // Fork workers
    for (let i = 0; i < numCPUs; i++) {
      cluster.fork();
    }

    cluster.on('exit', (worker, code, signal) => {
      console.log(`Worker ${worker.process.pid} died. Restarting...`);
      cluster.fork();
    });

    // Handle signals for graceful shutdown
    process.on('SIGINT', () => {
      console.log('SIGINT received, shutting down cluster');

      for (const id in cluster.workers) {
        cluster.workers[id].kill();
      }

      process.exit(0);
    });

    process.on('SIGTERM', () => {
      console.log('SIGTERM received, shutting down cluster');

      for (const id in cluster.workers) {
        cluster.workers[id].kill();
      }

      process.exit(0);
    });
  } else {
    console.log(`Worker ${process.pid} started`);
    startWorker();
  }
}

module.exports = {
  setupCluster
};
