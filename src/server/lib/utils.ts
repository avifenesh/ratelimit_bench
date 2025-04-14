/**
 * Simulates a CPU-intensive task.
 * @param complexity - A number determining the duration of the computation.
 */
export function performHeavyComputation(complexity: number): void {
  for (let i = 0; i < complexity * 1000000; i++) {
    Math.sqrt(i);
  }
}
