/**
 * Resource monitoring for benchmark tests
 * Tracks CPU and memory usage during benchmarks
 * Compatible with different Node.js environments including ARM64
 */
import * as os from 'os';
import { cpuUsage, memoryUsage, hrtime } from 'process';

// Load average types are absent in NodeJS.OS type definitions
interface LoadAverage {
    '1': number;
    '5': number;
    '15': number;
}

export interface ResourceSnapshot {
    timestamp: number;
    cpu: {
        user: number;
        system: number;
        percentage: number;
    };
    memory: {
        rss: number;
        heapTotal: number;
        heapUsed: number;
        external: number;
        // arrayBuffers removed to avoid libuv symbol errors on aarch64
    };
}

export class ResourceMonitor {
    private snapshots: ResourceSnapshot[] = [];
    private intervalId: NodeJS.Timeout | null = null;
    private initialCpuUsage: NodeJS.CpuUsage;
    private lastCpuUsage: NodeJS.CpuUsage;
    private lastCpuTime: [number, number];
    private loadAvg: LoadAverage;

    constructor(private intervalMs: number = 1000) {
        // Initialize CPU monitoring
        this.initialCpuUsage = cpuUsage();
        this.lastCpuUsage = this.initialCpuUsage;
        this.lastCpuTime = hrtime();

        // Initialize load average monitoring (ARM64 compatible alternative)
        const [load1, load5, load15] = os.loadavg();
        this.loadAvg = { '1': load1, '5': load5, '15': load15 };
    }

    /**
     * Start monitoring resources
     */
    start(): void {
        if (this.intervalId) {
            return;
        }

        this.snapshots = [];
        this.initialCpuUsage = cpuUsage();
        this.lastCpuUsage = this.initialCpuUsage;
        this.lastCpuTime = hrtime();

        // Reset load average values
        const [load1, load5, load15] = os.loadavg();
        this.loadAvg = { '1': load1, '5': load5, '15': load15 };

        this.intervalId = setInterval(() => {
            this.takeSnapshot();
        }, this.intervalMs);
    }

    /**
     * Stop monitoring resources
     */
    stop(): void {
        if (this.intervalId) {
            clearInterval(this.intervalId);
            this.intervalId = null;
        }
    }

    /**
     * Take a snapshot of current resource usage
     * ARM64-compatible implementation that avoids problematic libuv functions
     */
    private takeSnapshot(): void {
        try {
            const nowCpu = cpuUsage();
            const nowTime = hrtime();

            // Update load average values (ARM64-safe alternative to some CPU metrics)
            const [load1, load5, load15] = os.loadavg();
            this.loadAvg = { '1': load1, '5': load5, '15': load15 };

            // Calculate time difference in microseconds
            const elapsedTime = (nowTime[0] - this.lastCpuTime[0]) * 1e6 + (nowTime[1] - this.lastCpuTime[1]) / 1e3;

            // Calculate CPU usage since last snapshot
            const userDiff = nowCpu.user - this.lastCpuUsage.user;
            const systemDiff = nowCpu.system - this.lastCpuUsage.system;

            // CPU percentage (user + system) / elapsed time * 100
            const cpuPercentage = ((userDiff + systemDiff) / elapsedTime) * 100;

            // Get memory usage in a way that's compatible with ARM64
            const mem = memoryUsage();

            this.snapshots.push({
                timestamp: Date.now(),
                cpu: {
                    user: userDiff,
                    system: systemDiff,
                    percentage: cpuPercentage
                },
                memory: {
                    rss: mem.rss / 1024 / 1024, // Convert to MB
                    heapTotal: mem.heapTotal / 1024 / 1024,
                    heapUsed: mem.heapUsed / 1024 / 1024,
                    external: mem.external / 1024 / 1024
                }
            });

            // Update last values for next calculation
            this.lastCpuUsage = nowCpu;
            this.lastCpuTime = nowTime;
        } catch (error) {
            console.error('Error taking resource snapshot:', error);
        }
    }

    /**
     * Get all collected snapshots
     */
    getSnapshots(): ResourceSnapshot[] {
        return [...this.snapshots];
    }

    /**
     * Get summary statistics
     */
    getSummary(): {
        avgCpuPercentage: number;
        maxCpuPercentage: number;
        avgMemoryUsed: number;
        maxMemoryUsed: number;
        duration: number;
    } {
        if (this.snapshots.length === 0) {
            return {
                avgCpuPercentage: 0,
                maxCpuPercentage: 0,
                avgMemoryUsed: 0,
                maxMemoryUsed: 0,
                duration: 0
            };
        }

        let totalCpu = 0;
        let maxCpu = 0;
        let totalMemory = 0;
        let maxMemory = 0;

        for (const snapshot of this.snapshots) {
            totalCpu += snapshot.cpu.percentage;
            maxCpu = Math.max(maxCpu, snapshot.cpu.percentage);

            totalMemory += snapshot.memory.heapUsed;
            maxMemory = Math.max(maxMemory, snapshot.memory.heapUsed);
        }

        const duration = this.snapshots.length > 1
            ? this.snapshots[this.snapshots.length - 1].timestamp - this.snapshots[0].timestamp
            : 0;

        return {
            avgCpuPercentage: totalCpu / this.snapshots.length,
            maxCpuPercentage: maxCpu,
            avgMemoryUsed: totalMemory / this.snapshots.length,
            maxMemoryUsed: maxMemory,
            duration
        };
    }

    /**
     * Get total system information (independent of monitoring)
     */
    static getSystemInfo(): {
        totalMemory: number;
        freeMemory: number;
        cpuCount: number;
        cpuModel: string;
        platform: string;
    } {
        return {
            totalMemory: os.totalmem() / 1024 / 1024, // MB
            freeMemory: os.freemem() / 1024 / 1024, // MB
            cpuCount: os.cpus().length,
            cpuModel: os.cpus()[0]?.model || 'Unknown',
            platform: os.platform()
        };
    }
}
