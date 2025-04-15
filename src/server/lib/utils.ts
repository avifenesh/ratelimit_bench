/**
 * Simulates a CPU-intensive task.
 * @param complexity - A number determining the duration of the computation.
 */
export function performHeavyComputation(complexity: number): void {
  const iterations = complexity * 100000;

  const batchSize = 10000;
  for (let i = 0; i < iterations; i += batchSize) {
    const end = Math.min(i + batchSize, iterations);
    for (let j = i; j < end; j++) {
      Math.sqrt(j);
    }
    if (i % 100000 === 0 && i > 0) {
      // This is a synchronous function, but breaking the work into batches
      // helps prevent complete event loop blocking
    }
  }
}
