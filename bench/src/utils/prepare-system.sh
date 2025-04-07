#!/bin/bash
# This script prepares the system for benchmarking by reducing background noise

# Check if running as root
if [ "$EUID" -eq 0 ]; then
  SUDO=""
  echo "Running with root privileges - will apply all optimizations"
else
  SUDO="sudo"
  echo "Running without root privileges - some optimizations may be skipped"
fi

echo "Preparing system for benchmarking..."

# Drop caches (requires sudo)
echo "Dropping filesystem caches..."
sync
if [ "$EUID" -eq 0 ]; then
  echo 3 > /proc/sys/vm/drop_caches
else
  $SUDO sh -c 'echo 3 > /proc/sys/vm/drop_caches' || echo "Failed to drop caches, continuing anyway"
fi

# Set process priorities for background tasks
echo "Setting process priorities..."
$SUDO pkill -STOP apt || echo "No apt process to stop"
$SUDO pkill -STOP snapd || echo "No snapd process to stop"
$SUDO systemctl stop cron || echo "Failed to stop cron, continuing anyway"
$SUDO systemctl stop apt-daily.service || echo "Failed to stop apt-daily, continuing anyway"
$SUDO systemctl stop apt-daily-upgrade.service || echo "Failed to stop apt-daily-upgrade, continuing anyway"

# Set CPU governor if possible
if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
  echo "Setting CPU governor to performance mode..."
  if [ "$EUID" -eq 0 ]; then
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo performance > $cpu 2>/dev/null || echo "Could not set governor for $cpu"
    done
  else
    echo "Skipping CPU governor adjustment (requires root)"
  fi
else
  echo "CPU frequency scaling not available on this system, skipping"
fi

# Get current process count
PROCESS_COUNT=$(ps aux | wc -l)
echo "Current process count: $PROCESS_COUNT"

echo "System prepared for benchmarking"
echo "Run your benchmarks now, then use ./reset-system.sh to restore normal settings"

# Create reset script
cat > $(dirname "$0")/reset-system.sh << EOF
#!/bin/bash
echo "Resetting system to normal state..."

# Restart services
sudo systemctl start cron || echo "Failed to start cron, continuing anyway"

# Resume processes
sudo pkill -CONT apt || echo "No apt process to resume" 
sudo pkill -CONT snapd || echo "No snapd process to resume"

# Set CPU governor back to default if it was changed
if [ -d "/sys/devices/system/cpu/cpu0/cpufreq" ]; then
  if [ "\$EUID" -eq 0 ]; then
    echo "Resetting CPU governor to ondemand mode..."
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo ondemand > \$cpu 2>/dev/null || echo "Could not reset governor for \$cpu"
    done
  fi
fi

echo "System restored to normal state"
EOF

chmod +x $(dirname "$0")/reset-system.sh
