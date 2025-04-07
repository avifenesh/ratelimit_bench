/**
 * Worker Manager
 * Handles creation and management of worker threads
 */

const { Worker } = require('worker_threads');
const path = require('path');
const config = require('../config');

/**
 * Creates and manages worker threads
 */
class WorkerManager {
  constructor() {
    this.workers = [];
    this.currentWorker = 0;
  }

  /**
   * Initializes worker threads
   * @param {Object} workerData - Data to pass to worker threads
   * @returns {Promise<void>}
   */
  initialize(workerData = {}) {
    console.log(`Starting ${config.workers} worker threads`);

    // Create workers
    for (let i = 0; i < config.workers; i++) {
      this.createWorker(i, workerData);
    }

    return Promise.resolve();
  }

  /**
   * Creates a worker thread
   * @param {number} workerId - Worker identifier
   * @param {Object} additionalData - Additional data to pass to worker
   */
  createWorker(workerId, additionalData = {}) {
    const worker = new Worker(path.join(__dirname, '../workers/worker.js'), {
      workerData: {
        workerId,
        ...additionalData
      }
    });

    worker.on('message', message => {
      if (message.type === 'ready') {
        console.log(`Worker ${workerId} is ready`);
      }

      // Let the main thread handle other message types
      if (this.onMessage) {
        this.onMessage(message, worker);
      }
    });

    worker.on('error', err => {
      console.error(`Worker ${workerId} error:`, err);
    });

    worker.on('exit', code => {
      console.log(`Worker ${workerId} exited with code ${code}`);
      // Restart worker if it dies
      if (code !== 0) {
        console.log(`Restarting worker ${workerId}...`);
        this.createWorker(workerId, additionalData);
      }
    });

    this.workers[workerId] = worker;
  }

  /**
   * Gets the next worker in round-robin fashion
   * @returns {Worker} The next worker
   */
  getNextWorker() {
    const worker = this.workers[this.currentWorker];
    this.currentWorker = (this.currentWorker + 1) % this.workers.length;
    return worker;
  }

  /**
   * Set message handler callback
   * @param {Function} callback - Callback for worker messages
   */
  setMessageHandler(callback) {
    this.onMessage = callback;
  }

  /**
   * Terminates all workers
   */
  terminateAll() {
    console.log('Terminating all workers');
    for (const worker of this.workers) {
      if (worker) {
        worker.terminate();
      }
    }
    this.workers = [];
  }
}

module.exports = new WorkerManager();
