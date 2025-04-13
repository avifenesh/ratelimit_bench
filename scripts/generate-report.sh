#!/bin/bash

# Exit on error
set -e

# Process command line arguments
RESULTS_DIR=${1:-"./results/latest"}

if [ ! -d "$RESULTS_DIR" ]; then
  echo "Error: Results directory '$RESULTS_DIR' not found!"
  echo "Usage: $0 [results_directory]"
  exit 1
fi

echo "Generating report from results in: $RESULTS_DIR"

# Create report directory
REPORT_DIR="${RESULTS_DIR}/report"
mkdir -p "$REPORT_DIR"

# Find all JSON result files
RESULT_FILES=$(find "$RESULTS_DIR" -name "*.json" | sort)

if [ -z "$RESULT_FILES" ]; then
  echo "No result files found in $RESULTS_DIR!"
  exit 1
fi

# Generate summary CSV file for easier analysis
SUMMARY_CSV="${REPORT_DIR}/summary.csv"
echo "Implementation,Mode,RequestType,Concurrency,Duration,ReqPerSec,Latency_Avg,Latency_P95,Latency_P99,RateLimitHits,CPUUsage,MemoryUsage" > "$SUMMARY_CSV"

# Process each result file
for result_file in $RESULT_FILES; do
  # Extract metadata from filename
  filename=$(basename "$result_file")
  implementation=$(echo "$filename" | cut -d'_' -f1)
  mode=$(echo "$filename" | grep -o "cluster" || echo "standalone")
  req_type=$(echo "$filename" | grep -o "light\|heavy")
  concurrency=$(echo "$filename" | grep -o "[0-9]\+")
  
  # Sort results to prioritize Valkey implementations first
  if [[ "$implementation" == valkey* ]]; then
    priority=1
  else
    priority=2
  fi
  
  # Extract metrics from JSON
  if [ -f "$result_file" ]; then
    req_per_sec=$(jq -r '.requests.average // 0' "$result_file")
    latency_avg=$(jq -r '.latency.average // 0' "$result_file")
    latency_p95=$(jq -r '.latency.p95 // 0' "$result_file")
    latency_p99=$(jq -r '.latency.p99 // 0' "$result_file")
    rate_limit_hits=$(jq -r '.rateLimitHits // 0' "$result_file")
    cpu_usage=$(jq -r '.resources.cpu.average // 0' "$result_file")
    memory_usage=$(jq -r '.resources.memory.average // 0' "$result_file")
    duration=$(jq -r '.duration // 30' "$result_file")
    
    # Add to summary CSV
    echo "$priority,$implementation,$mode,$req_type,$concurrency,$duration,$req_per_sec,$latency_avg,$latency_p95,$latency_p99,$rate_limit_hits,$cpu_usage,$memory_usage" >> "$SUMMARY_CSV.tmp"
  fi
done

# Sort by priority to ensure Valkey results appear first
if [ -f "$SUMMARY_CSV.tmp" ]; then
  sort -t, -k1,1 -n "$SUMMARY_CSV.tmp" | cut -d, -f2- >> "$SUMMARY_CSV"
  rm "$SUMMARY_CSV.tmp"
fi

# Generate visualization HTML
cat > "${REPORT_DIR}/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
  <title>Rate Limiter Benchmark Results</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    body { font-family: Arial, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; }
    .chart-container { width: 100%; height: 400px; margin-bottom: 30px; }
    .highlight { background-color: #f8f9fa; border-left: 4px solid #4CAF50; padding: 10px; margin: 20px 0; }
    h1, h2 { color: #333; }
    table { border-collapse: collapse; width: 100%; margin: 20px 0; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; }
    tr:nth-child(even) { background-color: #f9f9f9; }
  </style>
</head>
<body>
  <h1>Rate Limiter Benchmark Results</h1>
  <p>Generated on: $(date)</p>
  <p>Results directory: $RESULTS_DIR</p>
  
  <div class="highlight">
    <h3>Key Findings</h3>
    <p>This report highlights the performance characteristics of different rate limiter implementations,
       with a focus on Valkey's performance advantages.</p>
  </div>
  
  <h2>Throughput Comparison (Requests per Second)</h2>
  <div class="chart-container">
    <canvas id="throughputChart"></canvas>
  </div>
  
  <h2>Latency Comparison (ms)</h2>
  <div class="chart-container">
    <canvas id="latencyChart"></canvas>
  </div>
  
  <h2>Resource Usage</h2>
  <div class="chart-container">
    <canvas id="resourceChart"></canvas>
  </div>
  
  <h2>Detailed Results</h2>
  <div id="resultsTable"></div>
  
  <script>
    // Load data from CSV
    fetch('summary.csv')
      .then(response => response.text())
      .then(csvText => {
        const rows = csvText.split('\\n');
        const headers = rows[0].split(',');
        const data = rows.slice(1).filter(row => row.trim() !== '').map(row => {
          const values = row.split(',');
          const obj = {};
          headers.forEach((header, i) => {
            obj[header] = values[i];
          });
          return obj;
        });
        
        // Generate table
        const table = document.createElement('table');
        const headerRow = document.createElement('tr');
        headers.forEach(header => {
          const th = document.createElement('th');
          th.textContent = header;
          headerRow.appendChild(th);
        });
        table.appendChild(headerRow);
        
        data.forEach(row => {
          const tr = document.createElement('tr');
          headers.forEach(header => {
            const td = document.createElement('td');
            td.textContent = row[header];
            tr.appendChild(td);
          });
          table.appendChild(tr);
        });
        
        document.getElementById('resultsTable').appendChild(table);
        
        // Create charts
        createCharts(data);
      });
      
    function createCharts(data) {
      // Group data by implementation and concurrency
      const implementations = [...new Set(data.map(d => d.Implementation))];
      const concurrencyLevels = [...new Set(data.map(d => +d.Concurrency))].sort((a, b) => a - b);
      
      // Ensure Valkey implementations come first
      implementations.sort((a, b) => {
        if (a.includes('valkey') && !b.includes('valkey')) return -1;
        if (!a.includes('valkey') && b.includes('valkey')) return 1;
        return a.localeCompare(b);
      });
      
      // Throughput chart
      const throughputCtx = document.getElementById('throughputChart').getContext('2d');
      new Chart(throughputCtx, {
        type: 'bar',
        data: {
          labels: concurrencyLevels.map(c => c + ' connections'),
          datasets: implementations.map((impl, i) => ({
            label: impl,
            data: concurrencyLevels.map(conc => {
              const match = data.find(d => d.Implementation === impl && +d.Concurrency === conc);
              return match ? +match.ReqPerSec : 0;
            }),
            backgroundColor: getColor(i, 0.7),
            borderColor: getColor(i, 1),
            borderWidth: 1
          }))
        },
        options: {
          responsive: true,
          plugins: {
            title: {
              display: true,
              text: 'Throughput by Concurrency Level'
            },
            tooltip: {
              callbacks: {
                label: function(context) {
                  return context.dataset.label + ': ' + context.raw + ' req/sec';
                }
              }
            }
          }
        }
      });
      
      // More charts would be added here
    }
    
    function getColor(index, alpha) {
      const colors = [
        \`rgba(66, 133, 244, \${alpha})\`,  // Blue (Valkey Glide)
        \`rgba(15, 157, 88, \${alpha})\`,   // Green (IOValkey)
        \`rgba(244, 180, 0, \${alpha})\`,   // Yellow (Redis IORedis)
        \`rgba(138, 78, 255, \${alpha})\`,  // Purple
        \`rgba(66, 133, 244, \${alpha})\`,  // Blue
      ];
      return colors[index % colors.length];
    }
  </script>
</body>
</html>
EOF

echo "Report generated at: ${REPORT_DIR}/index.html"
echo "Summary data available at: ${SUMMARY_CSV}"
