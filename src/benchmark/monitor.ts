import { cpuUsage, memoryUsage } from "process";

interface ResourceStats {
  cpu: {
    average: number;
    samples: number[];
    min: number;
    max: number;
  };
  memory: {
    average: number;
    samples: number[];
    min: number;
    max: number;
  };
}

export function monitorResources(sampleIntervalMs = 200) {
  let isRunning = true;
  const cpuSamples: number[] = [];
  const memorySamples: number[] = [];
  let lastCpuUsage = cpuUsage();
  const intervalId: NodeJS.Timeout = setInterval(() => {
    if (!isRunning) {
      clearInterval(intervalId);
      return;
    }

    // Sample CPU usage
    const currentCpuUsage = cpuUsage();
    const userDiff = currentCpuUsage.user - lastCpuUsage.user;
    const systemDiff = currentCpuUsage.system - lastCpuUsage.system;
    const totalDiff = userDiff + systemDiff;

    // Convert to percentage of time spent in CPU (0-100%)
    const cpuPercent = (totalDiff / 1000 / sampleIntervalMs) * 100;
    cpuSamples.push(cpuPercent);

    // Update last CPU usage for next iteration
    lastCpuUsage = currentCpuUsage;

    // Sample memory usage (in MB)
    const memUsage = memoryUsage().heapUsed;
    memorySamples.push(memUsage);
  }, sampleIntervalMs);

  // Return monitoring control object
  return {
    stop: (): ResourceStats => {
      isRunning = false;
      clearInterval(intervalId);

      // Calculate CPU stats
      const cpuAverage =
        cpuSamples.reduce((sum, sample) => sum + sample, 0) /
        (cpuSamples.length || 1);
      const cpuMin = Math.min(...cpuSamples, 0);
      const cpuMax = Math.max(...cpuSamples, 0);

      // Calculate memory stats
      const memoryAverage =
        memorySamples.reduce((sum, sample) => sum + sample, 0) /
        (memorySamples.length || 1);
      const memoryMin = Math.min(...memorySamples, 0);
      const memoryMax = Math.max(...memorySamples, 0);

      return {
        cpu: {
          average: cpuAverage,
          samples: cpuSamples,
          min: cpuMin,
          max: cpuMax,
        },
        memory: {
          average: memoryAverage,
          samples: memorySamples,
          min: memoryMin,
          max: memoryMax,
        },
      };
    },
  };
}
