#!/usr/bin/env python3

import os
import json
import csv
import argparse
import pandas as pd
# --- Matplotlib Backend Configuration ---
# Set backend to 'Agg' BEFORE importing pyplot
# This is crucial for running in environments without a display (like servers)
import matplotlib
matplotlib.use('Agg')
# --- End Matplotlib Backend Configuration ---
import matplotlib.pyplot as plt
import base64
from io import BytesIO
from datetime import datetime
import re
import math
import numpy as np # Import numpy for NaN handling
import traceback # Import traceback for detailed error logging

DEFAULT_RESULTS_DIR = "./results/latest"
REPORT_SUBDIR = "report"
SUMMARY_CSV_FILENAME = "summary.csv"
REPORT_HTML_FILENAME = "index.html"

# Chart colors with explicit client mappings (lowercase keys)
COLOR_MAPPINGS = {
    'valkey-glide': (66/255, 133/255, 244/255, 0.85),  # Blue
    'iovalkey': (15/255, 157/255, 88/255, 0.85),       # Green
    'ioredis': (219/255, 68/255, 55/255, 0.85),        # Red
}
# Fallback colors for any additional clients
FALLBACK_COLORS = [
    (138/255, 78/255, 255/255, 0.85),  # Purple
    (244/255, 180/255, 0/255, 0.85),   # Yellow
    (0/255, 172/255, 193/255, 0.85),   # Cyan
]


def parse_filename(filename):
    """
    Extracts metadata (implementation, mode, type, concurrency, duration, group)
    from the result filename. Aims for robustness across different naming conventions.
    """
    base = os.path.basename(filename).replace('.json', '')
    parts = base.split('_')

    implementation_parts = []
    req_type = "unknown"
    concurrency = 0
    duration = 0
    mode = "standalone" # Default mode

    # --- Enhanced Parsing Logic ---
    # Use regex to find key components first, avoids strict order dependency
    concurrency_match = re.search(r'(\d+)c', base)
    if concurrency_match:
        concurrency = int(concurrency_match.group(1))

    duration_match = re.search(r'(\d+)s', base)
    if duration_match:
        duration = int(duration_match.group(1))

    type_match = re.search(r'(light|heavy)', base)
    if type_match:
        req_type = type_match.group(1)

    # Mode detection (more robust)
    if "cluster" in base.lower() or ":cluster" in base or "-cluster" in base:
        mode = "cluster"

    # Identify implementation parts (those not matching known patterns)
    # Remove known patterns and separators to isolate implementation name parts
    temp_base = base
    if concurrency_match: temp_base = temp_base.replace(concurrency_match.group(0), '')
    if duration_match: temp_base = temp_base.replace(duration_match.group(0), '')
    if type_match: temp_base = temp_base.replace(type_match.group(0), '')
    # Be careful not to remove 'cluster' if it's part of the implementation name itself
    # Only remove if clearly a mode indicator (e.g., _cluster_, :cluster)
    temp_base = re.sub(r'(_|-|:)cluster($|_)', r'\2', temp_base) # Remove cluster mode indicators
    temp_base = temp_base.replace('run', '') # Remove run keyword
    temp_base = re.sub(r'\d+$', '', temp_base) # Remove trailing run numbers
    temp_base = temp_base.replace('__', '_').strip('_:') # Clean up separators

    implementation_parts = [p for p in temp_base.split('_') if p]
    implementation = "-".join(implementation_parts)

    # Create a clean implementation group name (remove cluster suffix for grouping)
    # Rename to 'Client' for clarity in report
    client_name = implementation # Start with the parsed name
    if mode == "cluster": # Only remove suffix if mode is cluster
         client_name = client_name.replace("-cluster", "").replace(":cluster", "")


    # --- Fallbacks (if regex didn't find them) ---
    if concurrency == 0:
        for part in parts:
            if part.endswith('c'):
                try: concurrency = int(part[:-1]); break
                except ValueError: pass
    if duration == 0:
        for part in parts:
            if part.endswith('s'):
                try: duration = int(part[:-1]); break
                except ValueError: pass

    # Final check for unknown type
    if req_type == "unknown":
        if "light" in parts: req_type = "light"
        elif "heavy" in parts: req_type = "heavy"

    # Ensure implementation name is reasonable
    if not implementation:
        implementation = "unknown_impl"
        client_name = "unknown_impl"
        print(f"Warning: Could not determine implementation for {filename}. Using '{implementation}'.")

    # Ensure group name is not empty if implementation was just 'cluster'
    if not client_name:
        client_name = implementation if implementation else "unknown_impl"


    # Return client_name instead of implementation_group
    return implementation, mode, req_type, concurrency, duration, client_name


def get_throughput_from_json(filepath):
    """Safely extracts throughput from JSON, prioritizing 'throughput.average'."""
    try:
        with open(filepath, 'r') as f:
            result_json = json.load(f)
        # Prioritize throughput.average, fallback to requests.average
        throughput = result_json.get('throughput', {}).get('average', result_json.get('requests', {}).get('average', 0))
        # Handle potential None or non-numeric values
        return float(throughput) if throughput is not None and isinstance(throughput, (int, float)) else 0
    except (json.JSONDecodeError, IOError, ValueError, TypeError) as e:
        print(f"Warning: Could not read throughput from {os.path.basename(filepath)}: {e}")
        return 0


def generate_chart_base64(df, x_col, y_col, title, ylabel, chart_type='bar', hue_col='Client', filter_req_type=None, filter_mode=None):
    """Generates a matplotlib chart and returns it as a base64 encoded string."""
    plt.style.use('seaborn-v0_8-darkgrid')
    plt.rcParams['figure.autolayout'] = False
    fig, ax = plt.subplots(figsize=(16, 8)) # Keep increased figure size

    # Define default message
    display_message = None

    plot_df = df.copy()

    # Apply filters
    if filter_req_type:
        plot_df = plot_df[plot_df['RequestType'] == filter_req_type]
    if filter_mode:
        plot_df = plot_df[plot_df['Mode'] == filter_mode]

    # Check if data remains after filtering AND if the y-column exists and has valid (non-null) data
    if plot_df.empty or y_col not in plot_df.columns or plot_df[y_col].isnull().all():
        display_message = 'No data available for this combination'
    else:
        # Check if all valid data points are zero
        valid_y_values = plot_df[y_col].dropna()
        # Use a small tolerance for zero check
        if not valid_y_values.empty and (valid_y_values.abs() < 1e-9).all():
            display_message = 'All data points are zero for this combination'

    # If a message needs to be displayed (no data or all zero), show it and skip plotting
    if display_message:
        # --- Increase font size for message ---
        ax.text(0.5, 0.5, display_message, horizontalalignment='center', verticalalignment='center', transform=ax.transAxes, fontsize=14)
        ax.set_title(title, fontsize=18) # Increased title font size
        ax.set_xlabel(x_col.replace('Concurrency', 'Concurrency (Connections)'), fontsize=14) # Increased label font size
        ax.set_ylabel(ylabel, fontsize=14) # Increased label font size
    else:
        # Proceed with plotting logic only if there's valid, non-zero data
        try:
            # Ensure correct sorting for concurrency on x-axis
            plot_df[x_col] = pd.to_numeric(plot_df[x_col])
            plot_df = plot_df.sort_values(by=x_col)
            x_labels = sorted(plot_df[x_col].unique()) # Unique concurrency values

            # --- Sort implementations (hue_col) to prioritize 'valkey-glide' ---
            implementations = sorted(
                plot_df[hue_col].unique(),
                key=lambda x: (0 if str(x).lower() == 'valkey-glide' else (1 if 'valkey' in str(x).lower() else 2), str(x))
            )

            num_implementations = len(implementations)
            # Adjust bar width dynamically, ensure minimum width
            total_bar_space = 0.8
            bar_width = max(0.1, total_bar_space / num_implementations) if num_implementations > 0 else 0.8 # Ensure bars are visible

            x = np.arange(len(x_labels)) # Use numpy arange for positioning

            all_y_values_numeric = [] # Collect all plotted y-values for scale decisions

            # Assign colors robustly
            assigned_colors = {}
            fallback_idx = 0
            for impl in implementations:
                impl_lower = str(impl).lower() # Use str() for safety
                found_color = None
                # Check explicit mappings first
                for key, color in COLOR_MAPPINGS.items():
                    if key in impl_lower:
                        found_color = color
                        break
                # Assign fallback if no explicit match
                if found_color is None:
                    found_color = FALLBACK_COLORS[fallback_idx % len(FALLBACK_COLORS)]
                    fallback_idx += 1
                assigned_colors[impl] = found_color


            for i, impl in enumerate(implementations):
                impl_data = plot_df[plot_df[hue_col] == impl]
                # Create a mapping from x_label (concurrency) to y_value for the current implementation
                y_map = pd.Series(impl_data[y_col].values, index=impl_data[x_col]).to_dict()
                # Get y values in the order of x_labels, filling with NaN if missing
                y_values = [y_map.get(label, np.nan) for label in x_labels] # Use NaN for missing data
                # Add only numeric, non-NaN values for scale calculation
                all_y_values_numeric.extend([v for v in y_values if pd.notna(v)])

                # Calculate bar positions relative to the center of the group
                offset = (i - (num_implementations - 1) / 2) * bar_width
                bar_positions = x + offset

                color = assigned_colors[impl]

                # Plot bars, handling NaN (plot as 0)
                bars = ax.bar(bar_positions, [0 if pd.isna(v) else v for v in y_values], bar_width, label=impl, color=color)

                # Add value labels on top of bars
                for bar_idx, rect in enumerate(bars):
                    height = rect.get_height()
                    original_value = y_values[bar_idx] # Use original value (could be NaN)

                    # Only label valid bars with height > small threshold (avoid labeling zero bars)
                    if pd.notna(original_value) and abs(height) > 1e-9:
                        # Format large numbers with K/M suffixes
                        if abs(height) >= 1000000:
                            value_text = f"{height/1000000:.2f}M"
                        elif abs(height) >= 1000:
                            value_text = f"{height/1000:.1f}K"
                        else:
                            # Show 2 decimal places for latency/cpu, 0 for others
                            is_decimal_metric = 'latency' in y_col.lower() or 'cpu' in y_col.lower()
                            value_text = f"{height:,.2f}" if is_decimal_metric else f"{height:,.0f}"

                        # --- Increase font size for value labels ---
                        ax.text(rect.get_x() + rect.get_width()/2., height, value_text,
                                ha='center', va='bottom', rotation=0,
                                fontsize=10, fontweight='bold', color='black') # Was 9

            # --- Axis Configuration ---
            # --- Increased font sizes for labels and title ---
            ax.set_xlabel(x_col.replace('Concurrency', 'Concurrency (Connections)'), fontsize=14) # Was 12
            ax.set_title(title, fontsize=18, fontweight='bold') # Was 16
            ax.set_xticks(x)
            ax.set_xticklabels([str(int(label)) for label in x_labels]) # Tick labels size set below

            # --- Increased font size for tick labels ---
            ax.tick_params(axis='both', which='major', labelsize=12) # Was 11

            # Y-axis formatting and potential log scale for latency
            is_latency_chart = 'latency' in y_col.lower()
            current_ylabel = ylabel # Store original ylabel before potentially adding (log scale)

            # Check if there are numeric values to process for scaling
            if all_y_values_numeric:
                non_zero_positive_values = [v for v in all_y_values_numeric if v > 1e-9] # Consider values > tiny threshold
                if is_latency_chart and non_zero_positive_values:
                    max_val = max(non_zero_positive_values)
                    min_val = min(non_zero_positive_values)
                    # Use log scale if variance is high and min_val is positive
                    # Avoid log scale if max_val is zero or less
                    if min_val > 1e-9 and max_val > 1e-9 and max_val / min_val > 20:
                        try:
                            ax.set_yscale('log')
                            current_ylabel = f"{ylabel} (log scale)" # Update label text
                        except ValueError: # Fallback if log scale fails
                             ax.set_yscale('linear')
                             ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda x_val, p: format(int(x_val), ',')))
                    else: # Linear scale if variance isn't high or min is zero
                        ax.set_yscale('linear')
                        ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda x_val, p: format(int(x_val), ',')))
                else: # Not a latency chart or no positive values for latency
                     ax.set_yscale('linear') # Ensure linear scale
                     # Format y-axis as integer for counts (like RateLimitHits) or non-latency floats
                     is_integer_metric = 'hits' in y_col.lower() or 'memory' in y_col.lower() or 'reqpersec' in y_col.lower()
                     formatter = plt.FuncFormatter(lambda x_val, p: format(int(x_val), ',')) if is_integer_metric else plt.FuncFormatter(lambda x_val, p: format(float(x_val), ','))
                     ax.yaxis.set_major_formatter(formatter)

            else: # No numeric data points at all
                ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda x_val, p: format(int(x_val), ',')))

            # --- Set Y label with potentially updated text and increased fontsize ---
            ax.set_ylabel(current_ylabel, fontsize=14) # Was 12


            # --- Improve legend with increased font sizes ---
            legend = ax.legend(title="Client", # Changed title from Implementation
                     loc='center left',
                     bbox_to_anchor=(1.02, 0.5), # Position outside plot
                     fontsize=14, # Increased item font size (was 12)
                     title_fontsize=15, # Increased title font size (was 13)
                     frameon=True, # Add frame
                     edgecolor='grey',
                     facecolor='white',
                     framealpha=0.9, # Slightly transparent
                     fancybox=True,
                     shadow=False) # Remove shadow

            # Add grid lines
            ax.grid(True, which='major', linestyle='--', linewidth='0.5', color='grey')
            # Only show minor grid lines if scale is log
            if ax.get_yscale() == 'log':
                ax.grid(True, which='minor', linestyle=':', linewidth='0.5', color='lightgrey')

        except Exception as e:
             # If any error occurs during plotting, display an error message on the axes
             print(f"ERROR: Failed to generate plot '{title}'. Error: {e}")
             traceback.print_exc() # Print traceback for debugging
             # Clear existing axes content and add error text
             ax.clear()
             ax.text(0.5, 0.5, f'Error generating chart:\n{e}', horizontalalignment='center', verticalalignment='center', transform=ax.transAxes, color='red', wrap=True, fontsize=12)
             ax.set_title(title, fontsize=18)


    # --- Finalization ---
    # Convert plot to base64
    buf = BytesIO()
    # Use bbox_inches='tight' to include legend if outside plot area
    plt.savefig(buf, format='png', bbox_inches='tight', dpi=130) # Keep increased DPI
    buf.seek(0)
    img_base64 = base64.b64encode(buf.read()).decode('utf-8')
    plt.close(fig) # Close the figure to free memory
    return f"data:image/png;base64,{img_base64}"


def generate_html_report(df, report_dir, results_dir):
    """Generates the HTML report file with corrected structure and styles."""
    report_path = os.path.join(report_dir, REPORT_HTML_FILENAME)
    print(f"Generating HTML report at: {report_path}")

    # Sort data for display - Use Client for consistency
    df_display = df.sort_values(
        by=['Priority', 'RequestType', 'Mode', 'Concurrency', 'Client'],
        ascending=[True, True, True, True, True]
    ).drop(columns=['Priority']) # Drop helper column

    # Define request_types and modes for iteration
    request_types = sorted(df['RequestType'].unique())
    modes = sorted(df['Mode'].unique())

    # --- GENERATE CHARTS (with error handling) ---
    charts = {}
    print("Generating charts...")
    for req_type in request_types:
        for mode in modes:
            key_prefix = f"{req_type}_{mode}"
            title_suffix = f" ({req_type.capitalize()} Workload, {mode.capitalize()} Mode)"
            print(f"  Generating charts for: {title_suffix}")

            # --- Added RateLimitHits chart config ---
            chart_configs = [
                ('throughput', 'ReqPerSec', f'Throughput vs Concurrency{title_suffix}', 'Requests per Second (Higher is Better)'),
                ('rate_limit_hits', 'RateLimitHits', f'Rate Limit Hits vs Concurrency{title_suffix}', 'Rate Limit Hits (Count)'), # New chart
                ('latency_avg', 'Latency_Avg', f'Average Latency vs Concurrency{title_suffix}', 'Latency (ms) (Lower is Better)'),
                ('latency_p99', 'Latency_P99', f'P99 Latency vs Concurrency{title_suffix}', 'Latency (ms) (Lower is Better)'),
                ('cpu', 'CPUUsage', f'Average CPU Usage vs Concurrency{title_suffix}', 'CPU Usage (%)'),
                ('memory', 'MemoryUsage', f'Average Memory Usage vs Concurrency{title_suffix}', 'Memory Usage (Bytes)')
            ]

            for chart_key, y_col, title, ylabel in chart_configs:
                full_key = f"{key_prefix}_{chart_key}"
                try:
                    # Ensure the y-column exists in the dataframe before attempting to plot
                    if y_col in df.columns:
                        charts[full_key] = generate_chart_base64(
                            df, 'Concurrency', y_col, title, ylabel,
                            hue_col='Client', filter_req_type=req_type, filter_mode=mode # Use Client
                        )
                    else:
                        print(f"  WARNING: Column '{y_col}' not found for chart '{title}'. Skipping chart generation.")
                        charts[full_key] = None # Mark as None if column is missing
                except Exception as e:
                    print(f"  ERROR generating chart '{title}': {e}")
                    traceback.print_exc() # Print full traceback for debugging
                    charts[full_key] = None # Store None to indicate failure

    print("Chart generation complete.")

    # --- BUILD HTML CONTENT ---
    # Use f-strings for easier variable insertion and readability
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Rate Limiter Benchmark Results</title>
    <style>
        body {{ font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; background-color: #f4f7f9; color: #333; }}
        .container {{ max-width: 1600px; margin: 20px auto; padding: 20px; background-color: #fff; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }}
        h1, h2, h3 {{ color: #2c3e50; border-bottom: 2px solid #e0e0e0; padding-bottom: 10px; margin-top: 30px; }}
        h1 {{ text-align: center; margin-bottom: 20px; }}
        h2 {{ margin-top: 40px; }}
        h3 {{ margin-top: 25px; border-bottom: 1px dashed #ccc; padding-bottom: 5px; }}
        /* --- Added style for chart group subheadings --- */
        h4 {{
            margin-top: 35px;
            margin-bottom: 5px;
            color: #34495e;
            border-bottom: 1px solid #eee;
            padding-bottom: 8px;
            font-size: 1.2em;
        }}
        p {{ line-height: 1.6; }}
        .table-container {{ /* Added container for table scrolling */
             overflow-x: auto;
             margin: 20px 0;
        }}
        .results-table {{
            width: 100%;
            border-collapse: collapse;
            /* margin: 20px 0; Removed margin, handled by container */
            font-size: 0.9em;
            box-shadow: 0 0 15px rgba(0,0,0,0.08);
            border-radius: 6px;
            /* overflow: hidden; Removed, handled by container */
            min-width: 900px; /* Optional: set a min-width if desired */
        }}
        .results-table th, .results-table td {{
            padding: 9px 11px; /* Slightly adjusted padding */
            text-align: left;
            border-bottom: 1px solid #e0e0e0;
            white-space: nowrap; /* Prevent wrapping - keep this */
        }}
        .results-table th {{
            background-color: #3498db; /* Header background color */
            color: white;
            font-weight: bold;
            position: sticky; /* Make header sticky */
            top: 0; /* Stick to the top */
            z-index: 10;
            /* --- Smaller font size for table header --- */
            font-size: 0.85em;
            text-transform: uppercase; /* Optional: make header uppercase */
        }}
        /* Alternating row colors */
        .results-table tr:nth-child(even) {{ background-color: #f8f9fa; }}
        .results-table tr:hover {{ background-color: #e9ecef; }}

        /* Specific column widths (adjust as needed, maybe make slightly wider if needed) */
        .results-table th:nth-child(1), .results-table td:nth-child(1) {{ width: 12%; }} /* Client */
        .results-table th:nth-child(2), .results-table td:nth-child(2) {{ width: 7%; }}  /* Mode */
        .results-table th:nth-child(3), .results-table td:nth-child(3) {{ width: 7%; }}  /* RequestType */
        .results-table th:nth-child(4), .results-table td:nth-child(4) {{ width: 8%; text-align: right; }}  /* Concurrency */
        .results-table th:nth-child(5), .results-table td:nth-child(5) {{ width: 7%; text-align: right; }}  /* Duration */
        .results-table th:nth-child(6), .results-table td:nth-child(6) {{ width: 9%; text-align: right; font-weight: bold; }} /* ReqPerSec */
        .results-table th:nth-child(7), .results-table td:nth-child(7) {{ width: 9%; text-align: right; }} /* Latency_Avg */
        .results-table th:nth-child(8), .results-table td:nth-child(8) {{ width: 7%; text-align: right; }} /* Latency_P50 */
        .results-table th:nth-child(9), .results-table td:nth-child(9) {{ width: 7%; text-align: right; }} /* Latency_P99 */
        .results-table th:nth-child(10),.results-table td:nth-child(10) {{ width: 8%; text-align: right; }} /* RateLimitHits */
        .results-table th:nth-child(11),.results-table td:nth-child(11) {{ width: 8%; text-align: right; }} /* CPUUsage */
        .results-table th:nth-child(12),.results-table td:nth-child(12) {{ width: 11%; text-align: right; }} /* MemoryUsage */

        /* Right-align numeric columns */
        .results-table td:nth-child(4), .results-table td:nth-child(5),
        .results-table td:nth-child(6), .results-table td:nth-child(7),
        .results-table td:nth-child(8), .results-table td:nth-child(9),
        .results-table td:nth-child(10),.results-table td:nth-child(11),
        .results-table td:nth-child(12) {{ text-align: right; }}

        .chart-container {{
            width: 95%;
            margin: 30px auto;
            padding: 15px; /* Reduced padding */
            background-color: #ffffff;
            border-radius: 8px;
            box-shadow: 0 1px 5px rgba(0,0,0,0.1);
            page-break-inside: avoid; /* Prevent charts from breaking across pages when printing */
            min-height: 100px; /* Ensure container has some height even if chart fails */
            display: flex; /* Use flexbox for centering */
            flex-direction: column;
            align-items: center;
            justify-content: center;
        }}
        .chart-container img {{
            max-width: 100%;
            height: auto;
            display: block;
            margin: 10px auto 0 auto; /* Add margin top */
            border-radius: 4px;
        }}
        .chart-container h3 {{
             text-align: center;
             margin-bottom: 15px;
             border-bottom: none; /* Remove border for chart titles */
             font-size: 1.1em; /* Keep chart title size reasonable */
             color: #34495e;
        }}
        .chart-error-message {{
            color: red;
            font-weight: bold;
            text-align: center;
            margin-top: 20px;
        }}
        .highlight {{
            background-color: #e7f3ff;
            border-left: 5px solid #007bff;
            padding: 15px;
            margin: 25px 0;
            border-radius: 5px;
        }}
        .footer {{ text-align: center; margin-top: 40px; font-size: 0.9em; color: #777; }}
        .chart-grid {{
            display: grid;
            /* --- Adjusted chart grid for potentially larger charts --- */
            grid-template-columns: repeat(auto-fit, minmax(650px, 1fr)); /* Increased min width */
            gap: 30px; /* Increased gap */
            margin-top: 10px; /* Reduced top margin for grid */
        }}
        /* Tooltip for potentially truncated table cells */
        td {{ position: relative; }}
        td[title]:hover::after {{
            content: attr(title);
            position: absolute;
            left: 50%; /* Center tooltip */
            transform: translateX(-50%);
            bottom: 100%; /* Position above cell */
            margin-bottom: 5px; /* Space between cell and tooltip */
            background: rgba(51, 51, 51, 0.9); /* Semi-transparent background */
            color: white;
            padding: 6px 10px;
            border-radius: 4px;
            z-index: 100; /* Ensure tooltip is on top */
            white-space: nowrap;
            font-size: 0.85em;
            box-shadow: 0 1px 3px rgba(0,0,0,0.2);
        }}
        /* Hide tooltip attribute visually */
        td[title] {{ cursor: help; }}

    </style>
</head>
<body>
    <div class="container">
        <h1>Rate Limiter Benchmark Results</h1>
        <p><strong>Generated on:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
        <p><strong>Results directory:</strong> {os.path.abspath(results_dir)}</p>

        <div class="highlight">
            <h3>Key Findings</h3>
            <p>This report summarizes the median performance characteristics of different rate limiter implementations (e.g., Valkey Glide, IOValkey, IORedis) across multiple runs for each configuration. Comparisons are made under various conditions (standalone/cluster, light/heavy workload, different concurrency levels).</p>
            <p>Focus on comparing throughput (requests/sec), latency (average, P99), and resource usage (CPU, Memory). Charts visualize trends against increasing concurrency.</p>
            <p><i>Note: Lower latency is better. Higher throughput is better. Results below represent the median run for each configuration based on throughput. Zero values may indicate failed runs or specific test conditions. Charts showing "All data points are zero" reflect this.</i></p>
        </div>

        <h2>Detailed Results Summary (Median Runs)</h2>
"""

    # Add tables grouped by Mode
    if df_display.empty:
        html_content += "<p>No data available to display.</p>"
    else:
        # Select and reorder columns for the table
        table_columns = [
            "Client", "Mode", "RequestType", "Concurrency", "Duration", # Changed ImplementationGroup to Client
            "ReqPerSec", "Latency_Avg", "Latency_P50", "Latency_P99", # Simplified latency columns
            "RateLimitHits", "CPUUsage", "MemoryUsage"
        ]
        # Make sure all columns exist, add missing ones with NaN
        df_table_display_base = df_display.reindex(columns=table_columns, fill_value=np.nan).copy()


        # Format numbers for better readability in the table
        # Create a formatted copy
        df_table_display_formatted = df_table_display_base.copy()
        # Use pd.isna to check for NaN before formatting
        for col in ["Latency_Avg", "Latency_P50", "Latency_P99", "CPUUsage"]:
             if col in df_table_display_formatted.columns:
                df_table_display_formatted[col] = df_table_display_formatted[col].map(lambda x: f'{x:,.2f}' if pd.notna(x) else 'N/A')
        # --- Format ReqPerSec as integer ---
        if "ReqPerSec" in df_table_display_formatted.columns:
             df_table_display_formatted["ReqPerSec"] = df_table_display_formatted["ReqPerSec"].map(lambda x: f'{int(float(x)):,}' if pd.notna(x) else 'N/A')
        # --- End ReqPerSec formatting ---
        for col in ["RateLimitHits", "MemoryUsage"]:
             if col in df_table_display_formatted.columns:
                 # Format MemoryUsage potentially as float then int for display
                 df_table_display_formatted[col] = df_table_display_formatted[col].map(lambda x: f'{int(float(x)):,}' if pd.notna(x) else 'N/A')
        for col in ["Concurrency", "Duration"]:
             if col in df_table_display_formatted.columns:
                df_table_display_formatted[col] = df_table_display_formatted[col].map(lambda x: f'{int(x)}' if pd.notna(x) else 'N/A')


        for mode in modes:
            # Filter the *formatted* dataframe for the current mode
            mode_indices = df_display[df_display['Mode'] == mode].index # Get indices from original df
            mode_df_formatted = df_table_display_formatted.loc[mode_indices].copy() # Select rows from formatted df

            if not mode_df_formatted.empty:
                html_content += f'<h3>Mode: {mode.capitalize()}</h3>'
                # --- Wrap table in a scrollable div ---
                html_content += '<div class="table-container">'
                # Generate HTML table from the formatted data
                html_content += mode_df_formatted.to_html(index=False, classes='results-table', border=0, na_rep='N/A', escape=False)
                html_content += '</div>' # Close table-container
            else:
                 html_content += f'<h3>Mode: {mode.capitalize()}</h3><p>No data available for this mode.</p>'


    html_content += """
        <h2>Performance Charts</h2>
    """

    # Add charts grouped by request type and mode (checking for generation success)
    if not charts:
         html_content += "<p>No charts could be generated.</p>"
    else:
        for req_type in request_types:
            for mode in modes:
                key_prefix = f"{req_type}_{mode}"
                title_suffix = f" ({req_type.capitalize()} Workload, {mode.capitalize()} Mode)"
                html_content += f"<h2>Charts for {title_suffix}</h2>"

                # --- Define chart groups ---
                # Map internal keys to display info
                chart_group_configs = {
                    # --- Added note to Performance header ---
                    "Performance Metrics (Higher is Better)": [
                        ('throughput', 'Throughput vs Concurrency', f'Throughput Chart{title_suffix}'),
                        ('rate_limit_hits', 'Rate Limit Hits vs Concurrency', f'Rate Limit Hits Chart{title_suffix}')
                    ],
                    # --- Added note to Latency header ---
                    "Latency Metrics (Lower is Better)": [
                        ('latency_avg', 'Average Latency vs Concurrency', f'Average Latency Chart{title_suffix}'),
                        ('latency_p99', 'P99 Latency vs Concurrency', f'P99 Latency Chart{title_suffix}')
                    ],
                    "Resource Metrics": [
                        ('cpu', 'CPU Usage vs Concurrency', f'CPU Usage Chart{title_suffix}'),
                        ('memory', 'Memory Usage vs Concurrency', f'Memory Usage Chart{title_suffix}')
                    ]
                }

                # --- Loop through chart groups and add separators ---
                for group_title, configs_in_group in chart_group_configs.items():
                    # Check if any chart in this group was successfully generated or has data
                    group_has_content = False
                    temp_group_html = "" # Build HTML for the group temporarily

                    for chart_key, chart_title_h3, alt_text in configs_in_group:
                        full_key = f"{key_prefix}_{chart_key}"
                        chart_html = f'<div class="chart-container">'
                        chart_html += f'<h3>{chart_title_h3}</h3>'
                        if charts.get(full_key): # Check if chart data (base64 string) exists
                            chart_html += f'<img src="{charts[full_key]}" alt="{alt_text}">'
                            group_has_content = True # Mark group as having content
                        else: # Display error message if chart generation failed
                            chart_html += f'<p class="chart-error-message">Could not generate chart.</p>'
                        chart_html += f'</div>' # Close chart-container
                        temp_group_html += chart_html

                    # Only add the group heading and grid if there was content
                    if group_has_content:
                        html_content += f"<h4>{group_title}</h4>" # Subheading for the group
                        html_content += "<div class='chart-grid'>" # Start chart-grid for this group
                        html_content += temp_group_html # Add the generated chart containers
                        html_content += "</div>" # Close chart-grid for this group


    # *** Ensure correct closing structure ***
    html_content += """
    </div> <div class="footer">
        Benchmark report generated by generate_report.py
    </div>
</body>
</html>
    """

    try:
        with open(report_path, 'w', encoding='utf-8') as f:
            f.write(html_content)
        print(f"Successfully wrote HTML report to {report_path}")
    except IOError as e:
        print(f"Error writing HTML report to {report_path}: {e}")


def main():
    parser = argparse.ArgumentParser(description="Generate a benchmark report from JSON results, using median throughput runs.")
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
         try:
             results_dir = os.path.realpath(results_dir)
         except OSError as e:
             print(f"Error resolving symlink '{args.results_dir}': {e}")
             exit(1)


    if not os.path.isdir(results_dir):
        print(f"Error: Results directory '{results_dir}' not found!")
        print(f"Attempted absolute path: {os.path.abspath(results_dir)}")
        exit(1)

    print(f"Processing results from: {os.path.abspath(results_dir)}")

    # Create report directory
    report_dir = os.path.join(results_dir, REPORT_SUBDIR)
    try:
        os.makedirs(report_dir, exist_ok=True)
    except OSError as e:
        print(f"Error creating report directory '{report_dir}': {e}")
        exit(1)

    # Find all JSON result files
    all_files = []
    try:
        for filename in os.listdir(results_dir):
            if filename.endswith(".json"):
                all_files.append(os.path.join(results_dir, filename))
    except OSError as e:
        print(f"Error reading results directory '{results_dir}': {e}")
        exit(1)


    if not all_files:
        print(f"No result files (*.json) found in {results_dir}!")
        exit(1)

    print(f"Found {len(all_files)} total JSON files.")

    # --- Group files by configuration and find median ---
    file_groups = {}
    print("Grouping files by configuration and identifying median throughput runs...")
    for filepath in all_files:
        filename = os.path.basename(filepath)
        try:
            # Use the refined parser
            implementation, mode, req_type, concurrency, file_duration, client_name = parse_filename(filename) # Changed to client_name

            # Skip if parsing failed significantly (e.g., no concurrency or unknown type)
            if concurrency == 0 or req_type == "unknown":
                 print(f"  Skipping file due to incomplete parsed data: {filename}")
                 continue

            # Get throughput for median calculation (using the consistent helper function)
            throughput = get_throughput_from_json(filepath)

            # Configuration key uses the cleaned client name
            config_key = (client_name.lower(), mode.lower(), req_type.lower(), concurrency)

            if config_key not in file_groups:
                file_groups[config_key] = []
            # Store filepath and the throughput value used for sorting
            file_groups[config_key].append({'filepath': filepath, 'throughput': throughput})

        except Exception as e:
            print(f"  Warning: Error processing file {filename} during grouping: {e}")
            traceback.print_exc() # Print traceback for debugging grouping errors

    # Select the file with median throughput for each group
    median_files_to_process = []
    processed_configs = set() # Keep track of processed configurations

    for config_key, files_in_group in file_groups.items():
        if not files_in_group:
            print(f"  Warning: No files found for config: {config_key}")
            continue

        # Sort files within the group by throughput
        files_in_group.sort(key=lambda x: x['throughput'])

        # Find the median index (middle element)
        median_idx = len(files_in_group) // 2
        median_file_info = files_in_group[median_idx]
        median_files_to_process.append(median_file_info['filepath'])
        processed_configs.add(config_key)

        # Optional: Print info about median selection
        # print(f"  Config: {config_key} - Found {len(files_in_group)} runs. Median throughput: {median_file_info['throughput']:.2f} from file: {os.path.basename(median_file_info['filepath'])}")

    if not median_files_to_process:
        print("Error: No median files could be identified. Check file naming and content.")
        exit(1)

    print(f"Identified {len(median_files_to_process)} median files for processing across {len(processed_configs)} configurations.")

    # --- Process only the selected median files ---
    data = []
    print("Processing median files...")
    for result_file in sorted(median_files_to_process): # Sort for consistent order
        filename = os.path.basename(result_file)
        try:
            with open(result_file, 'r') as f:
                result_json = json.load(f)

            # Re-parse filename to get all metadata consistently
            implementation, mode, req_type, concurrency, file_duration, client_name = parse_filename(filename) # Changed to client_name

            # Prioritize Valkey implementations for sorting later
            priority = 1 if 'valkey' in client_name.lower() else 2 # Use client_name

            # Extract metrics, providing defaults (0 or NaN)
            req_per_sec = get_throughput_from_json(result_file) # Use helper again for consistency

            latency = result_json.get('latency', {})
            latency_avg = latency.get('average')
            latency_p50 = latency.get('p50')
            latency_p99 = latency.get('p99')

            rate_limit_hits = result_json.get('rateLimitHits')
            resources = result_json.get('resources', {})
            cpu_usage = resources.get('cpu', {}).get('average')
            memory_usage = resources.get('memory', {}).get('average')

            # Use duration from JSON if available, otherwise from filename, default to 30
            duration = result_json.get('duration', file_duration if file_duration > 0 else 30)

            # Helper function to safely convert to float or return NaN
            def safe_float(value):
                try:
                    # Attempt conversion only if value is not None
                    return float(value) if value is not None else np.nan
                except (ValueError, TypeError):
                     # Print warning if conversion fails for non-None value
                    if value is not None:
                        print(f"  Warning: Could not convert value '{value}' (type: {type(value)}) to float in file {filename}. Using NaN.")
                    return np.nan

            # Append data using Client name
            data.append({
                "Priority": priority,
                "Client": client_name, # Use Client name for consistency
                "Mode": mode,
                "RequestType": req_type,
                "Concurrency": concurrency,
                "Duration": round(safe_float(duration), 2), # Apply safe_float here too
                # --- Metrics (use safe conversion) ---
                "ReqPerSec": safe_float(req_per_sec),
                "Latency_Avg": safe_float(latency_avg),
                "Latency_P50": safe_float(latency_p50),
                "Latency_P99": safe_float(latency_p99),
                "RateLimitHits": int(safe_float(rate_limit_hits)) if pd.notna(safe_float(rate_limit_hits)) else 0, # Default 0 for hits
                "CPUUsage": safe_float(cpu_usage),
                "MemoryUsage": safe_float(memory_usage),
            })
            # print(f"  Processed: {filename}")

        except json.JSONDecodeError:
            print(f"  Warning: Could not decode JSON from file: {filename}")
        except Exception as e:
            print(f"  Warning: Error processing file {filename}: {e}")
            traceback.print_exc() # Print full traceback for debugging

    if not data:
        print("Error: No valid data processed from the median JSON files.")
        exit(1)

    # Create DataFrame from the processed median data
    df = pd.DataFrame(data)

    # --- Generate summary CSV ---
    summary_csv_path = os.path.join(report_dir, SUMMARY_CSV_FILENAME)
    print(f"Generating summary CSV at: {summary_csv_path}")
    try:
        # Define explicit column order for CSV, using Client
        csv_columns = [
            "Client", "Mode", "RequestType", "Concurrency", "Duration", # Changed to Client
            "ReqPerSec", "Latency_Avg", "Latency_P50", "Latency_P99", # Simplified latency
            "RateLimitHits", "CPUUsage", "MemoryUsage"
        ]
        # Ensure columns exist before selecting/sorting, add Priority for sorting
        cols_to_select = [col for col in csv_columns if col in df.columns] + ['Priority']
        # Filter df before copying to avoid SettingWithCopyWarning if cols_to_select is different
        df_csv = df[cols_to_select].copy()


        df_csv = df_csv.sort_values(
            by=['Priority', 'RequestType', 'Mode', 'Concurrency', 'Client'], # Sort by Client
            ascending=[True, True, True, True, True]
        ).drop(columns=['Priority']) # Drop helper column

        # Reorder to final CSV columns, ensuring they exist
        df_csv = df_csv[[col for col in csv_columns if col in df_csv.columns]]

        # Round floats for CSV readability
        float_cols = df_csv.select_dtypes(include=['float']).columns
        df_csv[float_cols] = df_csv[float_cols].round(2)

        df_csv.to_csv(summary_csv_path, index=False, quoting=csv.QUOTE_NONNUMERIC, na_rep='N/A')
        print(f"Successfully wrote CSV summary to {summary_csv_path}")
    except Exception as e:
        print(f"Error writing CSV summary: {e}")
        traceback.print_exc()


    # --- Generate HTML Report ---
    # Pass the DataFrame with median data (df) to the HTML generator
    generate_html_report(df, report_dir, results_dir)

    print("-" * 30)
    print(f"Report generation complete.")
    print(f"Summary CSV: {os.path.abspath(summary_csv_path)}")
    print(f"HTML Report: {os.path.abspath(os.path.join(report_dir, REPORT_HTML_FILENAME))}")
    print("-" * 30)

if __name__ == "__main__":
    main()
