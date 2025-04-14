#!/usr/bin/env python3

import os
import json
import csv
import argparse
import pandas as pd
import matplotlib.pyplot as plt
import base64
from io import BytesIO
from datetime import datetime
import re

DEFAULT_RESULTS_DIR = "./results/latest"
REPORT_SUBDIR = "report"
SUMMARY_CSV_FILENAME = "summary.csv"
REPORT_HTML_FILENAME = "index.html"

# Chart colors (converted to tuples for matplotlib)
COLORS = [
    (66/255, 133/255, 244/255, 0.7),  # Blue (Valkey Glide)
    (15/255, 157/255, 88/255, 0.7),   # Green (IOValkey)
    (244/255, 180/255, 0/255, 0.7),   # Yellow (Redis IORedis)
    (138/255, 78/255, 255/255, 0.7),  # Purple
    (219/255, 68/255, 55/255, 0.7),   # Red
    (0/255, 172/255, 193/255, 0.7),   # Cyan
]


def parse_filename(filename):
    """Extracts metadata from the result filename."""
    base = os.path.basename(filename).replace('.json', '')
    parts = base.split('_')

    implementation_parts = []
    mode_explicitly_found = False # Flag to track if 'cluster' part was found
    req_type = "unknown"
    concurrency = 0
    duration = 0

    # Iterate through parts to identify components
    i = 0
    while i < len(parts):
        part = parts[i]
        if part in ["light", "heavy"]:
            req_type = part
            i += 1
        elif part.endswith('c'):
            try:
                concurrency = int(part[:-1])
                i += 1
            except ValueError:
                implementation_parts.append(part) # Assume it's part of the name
                i += 1
        elif part.endswith('s'):
             try:
                duration = int(part[:-1])
                i += 1
             except ValueError:
                implementation_parts.append(part) # Assume it's part of the name
                i += 1
        elif part == "cluster":
            mode_explicitly_found = True # Mark cluster mode found explicitly
            i += 1
        else:
            implementation_parts.append(part)
            i += 1

    implementation = "-".join(implementation_parts)

    # Fallback for concurrency if not found via 'c' suffix
    if concurrency == 0:
        match = re.search(r'_(\\d+)c(?:_|$)', base) # Look for _<digits>c_ or _<digits>c at end
        if match:
            concurrency = int(match.group(1))

    # Fallback for duration if not found via 's' suffix
    if duration == 0:
        match = re.search(r'_(\\d+)s(?:_|$)', base) # Look for _<digits>s_ or _<digits>s at end
        if match:
            duration = int(match.group(1))

    # Determine mode based on explicit flag or implementation name suffix
    if mode_explicitly_found or implementation.endswith("-cluster") or implementation.endswith(":cluster"):
        mode = "cluster"
        # Clean implementation name for grouping, handle both separators
        implementation_group = implementation.replace("-cluster", "").replace(":cluster", "")
    else:
        mode = "standalone"
        implementation_group = implementation


    return implementation, mode, req_type, concurrency, duration, implementation_group

def generate_chart_base64(df, x_col, y_col, title, ylabel, chart_type='bar', hue_col='ImplementationGroup', filter_req_type=None, filter_mode=None):
    """Generates a matplotlib chart and returns it as a base64 encoded string."""
    plt.style.use('seaborn-v0_8-darkgrid') # Use a visually appealing style
    fig, ax = plt.subplots(figsize=(10, 5))

    plot_df = df.copy()

    # Apply filters
    if filter_req_type:
        plot_df = plot_df[plot_df['RequestType'] == filter_req_type]
    if filter_mode:
        plot_df = plot_df[plot_df['Mode'] == filter_mode]

    if plot_df.empty:
        ax.text(0.5, 0.5, 'No data available for this combination', horizontalalignment='center', verticalalignment='center', transform=ax.transAxes)
        ax.set_title(title)
    else:
        # Ensure correct sorting for concurrency on x-axis
        plot_df[x_col] = pd.to_numeric(plot_df[x_col])
        plot_df = plot_df.sort_values(by=x_col)
        x_labels = sorted(plot_df[x_col].unique())

        implementations = sorted(plot_df[hue_col].unique(), key=lambda x: (0 if 'valkey' in x else 1, x)) # Prioritize Valkey

        num_implementations = len(implementations)
        bar_width = 0.8 / num_implementations
        x = range(len(x_labels))

        for i, impl in enumerate(implementations):
            impl_data = plot_df[plot_df[hue_col] == impl]
            # Create a mapping from x_label to y_value for the current implementation
            y_map = pd.Series(impl_data[y_col].values, index=impl_data[x_col]).to_dict()
            # Get y values in the order of x_labels, filling with 0 if missing
            y_values = [y_map.get(label, 0) for label in x_labels]

            bar_positions = [pos + i * bar_width - (bar_width * (num_implementations -1) / 2) for pos in x]

            ax.bar(bar_positions, y_values, bar_width, label=impl, color=COLORS[i % len(COLORS)])

        ax.set_xlabel(x_col.replace('Concurrency', 'Concurrency (Connections)'))
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.set_xticks(x)
        ax.set_xticklabels(x_labels)
        ax.legend(title=hue_col)
        ax.ticklabel_format(style='plain', axis='y') # Avoid scientific notation

    # Convert plot to base64
    buf = BytesIO()
    plt.tight_layout()
    plt.savefig(buf, format='png')
    buf.seek(0)
    img_base64 = base64.b64encode(buf.read()).decode('utf-8')
    plt.close(fig)
    return f"data:image/png;base64,{img_base64}"

def generate_html_report(df, report_dir, results_dir):
    """Generates the HTML report file."""
    report_path = os.path.join(report_dir, REPORT_HTML_FILENAME)
    print(f"Generating HTML report at: {report_path}")

    # Sort DataFrame for display (Valkey first, then by other columns)
    df_display = df.sort_values(
        by=['Priority', 'RequestType', 'Mode', 'Concurrency', 'Implementation'],
        ascending=[True, True, True, True, True]
    ).drop(columns=['Priority', 'ImplementationGroup']) # Drop helper columns for display

    # Generate charts for each request type and mode
    charts = {}
    request_types = df['RequestType'].unique()
    modes = df['Mode'].unique()

    for req_type in request_types:
        for mode in modes:
            key_prefix = f"{req_type}_{mode}"
            title_suffix = f" ({req_type.capitalize()} Workload, {mode.capitalize()} Mode)"

            charts[f"{key_prefix}_throughput"] = generate_chart_base64(
                df, 'Concurrency', 'ReqPerSec', f'Throughput vs Concurrency{title_suffix}', 'Requests per Second',
                filter_req_type=req_type, filter_mode=mode
            )
            charts[f"{key_prefix}_latency_avg"] = generate_chart_base64(
                df, 'Concurrency', 'Latency_Avg', f'Average Latency vs Concurrency{title_suffix}', 'Latency (ms)',
                filter_req_type=req_type, filter_mode=mode
            )
            charts[f"{key_prefix}_latency_p99"] = generate_chart_base64(
                df, 'Concurrency', 'Latency_P99', f'P99 Latency vs Concurrency{title_suffix}', 'Latency (ms)',
                 filter_req_type=req_type, filter_mode=mode
            )
            charts[f"{key_prefix}_cpu"] = generate_chart_base64(
                df, 'Concurrency', 'CPUUsage', f'Average CPU Usage vs Concurrency{title_suffix}', 'CPU Usage (%)',
                 filter_req_type=req_type, filter_mode=mode
            )
            # Memory usage might be better as a line chart if values vary widely
            charts[f"{key_prefix}_memory"] = generate_chart_base64(
                df, 'Concurrency', 'MemoryUsage', f'Average Memory Usage vs Concurrency{title_suffix}', 'Memory Usage (Bytes)',
                 filter_req_type=req_type, filter_mode=mode
            )


    # Basic HTML structure
    html_content = f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Rate Limiter Benchmark Results</title>
    <style>
        body {{ font-family: Arial, sans-serif; max-width: 1400px; margin: 0 auto; padding: 20px; background-color: #f4f4f4; color: #333; }}
        .container {{ background-color: #fff; padding: 30px; border-radius: 8px; box-shadow: 0 0 15px rgba(0,0,0,0.1); }}
        h1, h2 {{ color: #0056b3; border-bottom: 2px solid #0056b3; padding-bottom: 5px; }}
        h1 {{ text-align: center; margin-bottom: 30px; }}
        h2 {{ margin-top: 40px; }}
        table {{ border-collapse: collapse; width: 100%; margin: 25px 0; box-shadow: 0 2px 3px rgba(0,0,0,0.1); }}
        th, td {{ border: 1px solid #ddd; padding: 10px 12px; text-align: left; }}
        th {{ background-color: #007bff; color: white; font-weight: bold; }}
        tr:nth-child(even) {{ background-color: #f9f9f9; }}
        tr:hover {{ background-color: #f1f1f1; }}
        .chart-container {{ width: 95%; margin: 30px auto; padding: 20px; background-color: #fff; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }}
        .chart-container img {{ max-width: 100%; height: auto; display: block; margin: 0 auto; }}
        .highlight {{ background-color: #e7f3ff; border-left: 5px solid #007bff; padding: 15px; margin: 25px 0; border-radius: 5px; }}
        p {{ line-height: 1.6; }}
        .footer {{ text-align: center; margin-top: 40px; font-size: 0.9em; color: #777; }}
        .chart-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(600px, 1fr)); gap: 20px; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Rate Limiter Benchmark Results</h1>
        <p><strong>Generated on:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
        <p><strong>Results directory:</strong> {os.path.abspath(results_dir)}</p>

        <div class="highlight">
            <h3>Key Findings</h3>
            <p>This report summarizes the performance characteristics of different rate limiter implementations (Valkey Glide, IOValkey, IORedis) under various conditions (standalone/cluster, light/heavy workload, different concurrency levels).</p>
            <p>Focus on comparing throughput (requests/sec), latency (average, P99), and resource usage (CPU, Memory).</p>
            <p><i>Note: Lower latency is better. Higher throughput is better.</i></p>
        </div>

        <h2>Detailed Results Summary</h2>
        {df_display.to_html(index=False, classes='results-table', border=0)}

        <h2>Performance Charts</h2>
    """

    # Add charts grouped by request type and mode
    for req_type in request_types:
        for mode in modes:
            key_prefix = f"{req_type}_{mode}"
            title_suffix = f" ({req_type.capitalize()} Workload, {mode.capitalize()} Mode)"
            html_content += f"<h2>Charts for {title_suffix}</h2>"
            html_content += "<div class='chart-grid'>"
            html_content += f"""
            <div class="chart-container">
                <h3>Throughput vs Concurrency</h3>
                <img src="{charts[f'{key_prefix}_throughput']}" alt="Throughput Chart">
            </div>
            <div class="chart-container">
                <h3>Average Latency vs Concurrency</h3>
                <img src="{charts[f'{key_prefix}_latency_avg']}" alt="Average Latency Chart">
            </div>
            <div class="chart-container">
                <h3>P99 Latency vs Concurrency</h3>
                <img src="{charts[f'{key_prefix}_latency_p99']}" alt="P99 Latency Chart">
            </div>
            <div class="chart-container">
                <h3>CPU Usage vs Concurrency</h3>
                <img src="{charts[f'{key_prefix}_cpu']}" alt="CPU Usage Chart">
            </div>
            <div class="chart-container">
                <h3>Memory Usage vs Concurrency</h3>
                <img src="{charts[f'{key_prefix}_memory']}" alt="Memory Usage Chart">
            </div>
            """
            html_content += "</div>" # Close chart-grid


    html_content += """
    </div> <!-- Close container -->
    <div class="footer">
        Benchmark report generated by generate_report.py
    </div>
</body>
</html>
    """

    with open(report_path, 'w') as f:
        f.write(html_content)

def main():
    parser = argparse.ArgumentParser(description="Generate a benchmark report from JSON results.")
    parser.add_argument(
        "results_dir",
        nargs='?',
        default=DEFAULT_RESULTS_DIR,
        help=f"Directory containing the JSON result files (default: {DEFAULT_RESULTS_DIR})"
    )
    args = parser.parse_args()

    results_dir = args.results_dir
    # Resolve 'latest' symlink if present
    if os.path.islink(results_dir):
         results_dir = os.path.realpath(results_dir)


    if not os.path.isdir(results_dir):
        print(f"Error: Results directory '{results_dir}' not found!")
        print(f"Attempted real path: {os.path.abspath(results_dir)}")
        exit(1)

    print(f"Generating report from results in: {os.path.abspath(results_dir)}")

    # Create report directory
    report_dir = os.path.join(results_dir, REPORT_SUBDIR)
    os.makedirs(report_dir, exist_ok=True)

    # Find all JSON result files
    result_files = []
    for filename in os.listdir(results_dir):
        if filename.endswith(".json"):
            result_files.append(os.path.join(results_dir, filename))

    if not result_files:
        print(f"No result files (*.json) found in {results_dir}!")
        exit(1)

    # Process each result file
    data = []
    for result_file in sorted(result_files):
        try:
            with open(result_file, 'r') as f:
                result_json = json.load(f)

            filename = os.path.basename(result_file)
            implementation, mode, req_type, concurrency, file_duration, impl_group = parse_filename(filename)

            # Prioritize Valkey implementations
            priority = 1 if 'valkey' in implementation.lower() else 2

            # Extract metrics, providing defaults for missing keys
            req_per_sec = result_json.get('requests', {}).get('average', 0)
            latency_avg = result_json.get('latency', {}).get('average', 0)
            # Handle potential variations in percentile keys
            latency_p95 = result_json.get('latency', {}).get('p95', result_json.get('latency', {}).get('p97.5', 0)) # Use p97.5 as fallback
            latency_p99 = result_json.get('latency', {}).get('p99', 0)
            rate_limit_hits = result_json.get('rateLimitHits', 0)
            cpu_usage = result_json.get('resources', {}).get('cpu', {}).get('average', 0)
            memory_usage = result_json.get('resources', {}).get('memory', {}).get('average', 0)
            # Use duration from JSON if available, otherwise from filename, default to 30
            duration = result_json.get('duration', file_duration if file_duration > 0 else 30)


            data.append({
                "Priority": priority,
                "Implementation": implementation,
                "ImplementationGroup": impl_group, # Cleaned name for grouping/coloring
                "Mode": mode,
                "RequestType": req_type,
                "Concurrency": concurrency,
                "Duration": round(float(duration), 2) if duration else 0,
                "ReqPerSec": round(float(req_per_sec), 2) if req_per_sec else 0,
                "Latency_Avg": round(float(latency_avg), 2) if latency_avg else 0,
                "Latency_P95": round(float(latency_p95), 2) if latency_p95 else 0,
                "Latency_P99": round(float(latency_p99), 2) if latency_p99 else 0,
                "RateLimitHits": int(rate_limit_hits) if rate_limit_hits else 0,
                "CPUUsage": round(float(cpu_usage), 2) if cpu_usage else 0,
                "MemoryUsage": int(memory_usage) if memory_usage else 0,
            })

        except json.JSONDecodeError:
            print(f"Warning: Could not decode JSON from file: {result_file}")
        except Exception as e:
            print(f"Warning: Error processing file {result_file}: {e}")

    if not data:
        print("No valid data processed from JSON files.")
        exit(1)

    # Create DataFrame
    df = pd.DataFrame(data)

    # --- Generate summary CSV ---
    summary_csv_path = os.path.join(report_dir, SUMMARY_CSV_FILENAME)
    print(f"Generating summary CSV at: {summary_csv_path}")
    # Sort before saving CSV
    df_csv = df.sort_values(
        by=['Priority', 'RequestType', 'Mode', 'Concurrency', 'Implementation'],
        ascending=[True, True, True, True, True]
    ).drop(columns=['Priority', 'ImplementationGroup']) # Drop helper columns for CSV

    # Define explicit column order for CSV
    csv_columns = [
        "Implementation", "Mode", "RequestType", "Concurrency", "Duration",
        "ReqPerSec", "Latency_Avg", "Latency_P95", "Latency_P99",
        "RateLimitHits", "CPUUsage", "MemoryUsage"
    ]
    df_csv = df_csv[csv_columns] # Reorder columns
    df_csv.to_csv(summary_csv_path, index=False, quoting=csv.QUOTE_NONNUMERIC)


    # --- Generate HTML Report ---
    generate_html_report(df, report_dir, results_dir)

    print("-" * 30)
    print(f"Report generation complete.")
    print(f"Summary CSV: {os.path.abspath(summary_csv_path)}")
    print(f"HTML Report: {os.path.abspath(os.path.join(report_dir, REPORT_HTML_FILENAME))}")
    print("-" * 30)

if __name__ == "__main__":
    main()
