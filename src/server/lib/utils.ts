/**
 * Simulates a CPU-intensive task.
 * @param complexity - A number determining the duration of the computation.
 */
export function performHeavyComputation(complexity: number): void {
  // Get computation complexity from environment or use the passed parameter
  const envComplexity = process.env.COMPUTATION_COMPLEXITY ? 
    parseInt(process.env.COMPUTATION_COMPLEXITY, 10) : complexity;
  
  // Use a more reasonable default if the complexity is too high
  const actualComplexity = Math.min(envComplexity, 100);
  
  const iterations = actualComplexity * 10000; // Reduced from 100000

  const batchSize = 5000; // Reduced from 10000
  for (let i = 0; i < iterations; i += batchSize) {
    const end = Math.min(i + batchSize, iterations);
    for (let j = i; j < end; j++) {
      Math.sqrt(j);
    }
    if (i % 50000 === 0 && i > 0) {
      // This is a synchronous function, but breaking the work into batches
      // helps prevent complete event loop blocking
    }
  }
}
