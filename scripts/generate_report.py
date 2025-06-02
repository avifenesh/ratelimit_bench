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
import shutil

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


def collect_all_error_data(results_dir):
    """Collect error data from all runs, not just median runs."""
    print("Collecting error data from all runs...")
    all_error_data = []

    # Find all JSON result files
    all_files = []
    try:
        for filename in os.listdir(results_dir):
            if filename.endswith(".json"):
                all_files.append(os.path.join(results_dir, filename))
    except OSError as e:
        print(f"Error reading results directory '{results_dir}': {e}")
        return []

    for filepath in all_files:
        filename = os.path.basename(filepath)
        try:
            # Parse filename to get metadata
            implementation, mode, req_type, concurrency, file_duration, client_name = parse_filename(filename)

            # Read the JSON file
            with open(filepath, 'r') as f:
                result_json = json.load(f)

            # Extract error data
            errors = result_json.get('errors', 0)
            timeouts = result_json.get('timeouts', 0)
            total_errors = errors + timeouts

            # Add to error data collection
            all_error_data.append({
                "Client": client_name,
                "Mode": mode,
                "RequestType": req_type,
                "Concurrency": concurrency,
                "Errors": int(errors) if isinstance(errors, (int, float)) else 0,
                "Timeouts": int(timeouts) if isinstance(timeouts, (int, float)) else 0,
                "TotalErrors": int(total_errors) if isinstance(total_errors, (int, float)) else 0,
            })

        except Exception as e:
            print(f"Warning: Error processing file {filename} for error data: {e}")

    return all_error_data


def generate_html_report(
    df, report_dir, results_dir, comparison_data=None, trends=None
):
    """Generates the HTML report file with corrected structure and styles."""
    report_path = os.path.join(report_dir, REPORT_HTML_FILENAME)
    print(f"Generating HTML report at: {report_path}")

    # Collect error data from all runs
    all_error_data = collect_all_error_data(results_dir)
    error_df = pd.DataFrame(all_error_data) if all_error_data else pd.DataFrame()

    # Sort data by configuration and then order clients as: valkey-glide, iovalkey, ioredis
    # Create a client priority column for fine-grained sorting
    def get_client_priority(client):
        client_lower = str(client).lower()
        if 'valkey-glide' in client_lower:
            return 1
        elif 'iovalkey' in client_lower:
            return 2
        elif 'ioredis' in client_lower:
            return 3
        return 4  # Any other clients

    df['ClientPriority'] = df['Client'].apply(get_client_priority)

    # Sort by configuration components first, then by the client priority (valkey-glide, iovalkey, ioredis)
    df_display = df.sort_values(
        by=['RequestType', 'Mode', 'Concurrency', 'ClientPriority'],
        ascending=[True, True, True, True]
    ).drop(columns=['Priority', 'ClientPriority']) # Drop helper columns

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
        
        /* Error summary styling */
        .error-summary {{
            margin: 20px 0;
            padding: 15px;
            background-color: #f8f9fa;
            border-radius: 6px;
            border-left: 5px solid #dc3545;
        }}
        .error-summary h3 {{
            color: #343a40;
            margin-top: 0;
            font-size: 1.1em;
            border-bottom: 1px solid #dee2e6;
            padding-bottom: 8px;
        }}
        .error-table {{
            width: 100%;
            border-collapse: collapse;
            margin-top: 10px;
            font-size: 0.9em;
        }}
        .error-table th, .error-table td {{
            padding: 8px 12px;
            text-align: left;
            border-bottom: 1px solid #dee2e6;
        }}
        .error-table th {{
            background-color: #e9ecef;
            font-weight: bold;
        }}
        .error-table tr:hover {{
            background-color: #f1f3f5;
        }}

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
            df_table_display_formatted["ReqPerSec"] = df_table_display_formatted[
                "ReqPerSec"
            ].map(lambda x: f"{int(float(x)):,}" if pd.notna(x) else "N/A")
        # --- End ReqPerSec formatting ---
        for col in ["RateLimitHits", "MemoryUsage"]:
            if col in df_table_display_formatted.columns:
                # Format MemoryUsage potentially as float then int for display
                df_table_display_formatted[col] = df_table_display_formatted[col].map(
                    lambda x: f"{int(float(x)):,}" if pd.notna(x) else "N/A"
                )
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
                html_content += f"<h3>Mode: {mode.capitalize()}</h3><p>No data available for this mode.</p>"

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

                # Add error summary for this workload and mode
                html_content += "<div class='error-summary'>"
                html_content += "<h3>Error Summary (Across All Runs)</h3>"
                html_content += "<table class='error-table'>"
                html_content += "<tr><th>Client</th><th>Total Errors</th><th>Connection Errors</th><th>Timeouts</th></tr>"

                # Get data for this workload and mode from the complete error dataset
                if not error_df.empty:
                    workload_mode_data = error_df[
                        (error_df['RequestType'] == req_type) & 
                        (error_df['Mode'] == mode)
                    ].copy()

                    # Sort clients in our desired order
                    def get_client_priority(client):
                        client_lower = str(client).lower()
                        if 'valkey-glide' in client_lower:
                            return 1
                        elif 'iovalkey' in client_lower:
                            return 2
                        elif 'ioredis' in client_lower:
                            return 3
                        return 4

                    workload_mode_data['ClientPriority'] = workload_mode_data['Client'].apply(get_client_priority)
                    workload_mode_data = workload_mode_data.sort_values('ClientPriority')

                    # Calculate total errors per client for this workload/mode
                    client_errors = workload_mode_data.groupby('Client').agg({
                        'TotalErrors': 'sum',
                        'Errors': 'sum',
                        'Timeouts': 'sum'
                    }).reset_index()

                    # Add a row for each client
                    for _, row in client_errors.iterrows():
                        html_content += f"<tr><td>{row['Client']}</td><td>{int(row['TotalErrors'])}</td><td>{int(row['Errors'])}</td><td>{int(row['Timeouts'])}</td></tr>"
                else:
                    html_content += "<tr><td colspan='4'>No error data available</td></tr>"

                html_content += "</table>"
                html_content += "</div>"

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

    # Add comparison and trends sections if available
    if comparison_data:
        html_content += """
        <h2>Performance Comparison</h2>
        <p>This section compares performance across multiple benchmark runs.</p>
        <div class="table-container">
            <table class="results-table">
                <thead>
                    <tr>
                        <th>Run Timestamp</th>
                        <th>Date/Time</th>
                        <th>Configurations</th>
                        <th>Avg Throughput</th>
                        <th>Max Throughput</th>
                        <th>Avg Latency</th>
                    </tr>
                </thead>
                <tbody>
        """

        for run_data in comparison_data:
            df_run = run_data["df"]
            html_content += f"""
                    <tr>
                        <td>{run_data['timestamp']}</td>
                        <td>{run_data['datetime'].strftime('%Y-%m-%d %H:%M:%S')}</td>
                        <td>{len(df_run)}</td>
                        <td>{df_run['ReqPerSec'].mean():.2f}</td>
                        <td>{df_run['ReqPerSec'].max():.2f}</td>
                        <td>{df_run['Latency_Avg'].mean():.2f} ms</td>
                    </tr>
            """

        html_content += """
                </tbody>
            </table>
        </div>
        """

    if trends:
        html_content += """
        <h2>Performance Trends Analysis</h2>
        <p>This section shows performance trends and changes across multiple benchmark runs.</p>
        <div class="table-container">
            <table class="results-table">
                <thead>
                    <tr>
                        <th>Configuration</th>
                        <th>Change (%)</th>
                        <th>Trend</th>
                        <th>Stability</th>
                        <th>Data Points</th>
                        <th>Avg Throughput</th>
                        <th>Best</th>
                        <th>Worst</th>
                    </tr>
                </thead>
                <tbody>
        """

        # Sort trends by performance change (worst declines first, then best improvements)
        sorted_trends = sorted(
            trends.values(), key=lambda x: x["throughput_change_percent"]
        )

        for trend in sorted_trends:
            config_display = trend["config"].replace("_", " ").title()
            change_class = ""
            if trend["throughput_change_percent"] > 5:
                change_class = "style='color: green; font-weight: bold;'"
            elif trend["throughput_change_percent"] < -5:
                change_class = "style='color: red; font-weight: bold;'"

            trend_icon = (
                "↗️"
                if trend["trend_direction"] == "improving"
                else "↘️" if trend["trend_direction"] == "declining" else "➡️"
            )

            html_content += f"""
                    <tr>
                        <td>{config_display}</td>
                        <td {change_class}>{trend['throughput_change_percent']:+.1f}%</td>
                        <td>{trend_icon} {trend['trend_direction'].title()}</td>
                        <td>{trend['stability'].title()}</td>
                        <td>{trend['data_points']}</td>
                        <td>{trend['avg_throughput']:.2f}</td>
                        <td>{trend['best_throughput']:.2f}</td>
                        <td>{trend['worst_throughput']:.2f}</td>
                    </tr>
            """

        html_content += """
                </tbody>
            </table>
        </div>
        """

        # Add trend charts if they exist
        trend_chart_files = [
            f
            for f in os.listdir(report_dir)
            if f.startswith("trends_") and f.endswith(".png")
        ]
        if trend_chart_files:
            html_content += """
            <h3>Trend Visualization</h3>
            <div class="chart-grid">
            """
            for chart_file in sorted(trend_chart_files):
                chart_name = (
                    chart_file.replace("trends_", "").replace(".png", "").title()
                )
                html_content += f"""
                <div class="chart-container">
                    <h4>Performance Trends: {chart_name}</h4>
                    <img src="{chart_file}" alt="Trend chart for {chart_name}" style="max-width: 100%; height: auto;">
                </div>
                """
            html_content += "</div>"

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


def find_comparison_directories(results_base_dir):
    """Find all timestamped result directories for comparison analysis."""
    comparison_dirs = []

    if not os.path.isdir(results_base_dir):
        return comparison_dirs

    for item in os.listdir(results_base_dir):
        item_path = os.path.join(results_base_dir, item)
        if os.path.isdir(item_path) and re.match(r"\d{8}_\d{6}", item):
            # Check if this directory has JSON files
            json_files = [f for f in os.listdir(item_path) if f.endswith(".json")]
            if json_files:
                comparison_dirs.append(
                    {
                        "path": item_path,
                        "timestamp": item,
                        "datetime": datetime.strptime(item, "%Y%m%d_%H%M%S"),
                        "json_count": len(json_files),
                    }
                )

    # Sort by timestamp (oldest first)
    comparison_dirs.sort(key=lambda x: x["datetime"])
    return comparison_dirs


def calculate_performance_trends(comparison_data):
    """Calculate performance trends across multiple benchmark runs."""
    trends = {}

    if len(comparison_data) < 2:
        return trends

    # Group by configuration for trend analysis
    config_groups = {}
    for run_data in comparison_data:
        for _, row in run_data["df"].iterrows():
            config_key = f"{row['Client']}_{row['Mode']}_{row['RequestType']}_{row['Concurrency']}"
            if config_key not in config_groups:
                config_groups[config_key] = []
            config_groups[config_key].append(
                {
                    "timestamp": run_data["timestamp"],
                    "datetime": run_data["datetime"],
                    "throughput": row["ReqPerSec"],
                    "latency_avg": row["Latency_Avg"],
                    "latency_p99": row["Latency_P99"],
                    "cpu_usage": row["CPUUsage"],
                    "memory_usage": row["MemoryUsage"],
                }
            )

    # Calculate trends for each configuration
    for config_key, data_points in config_groups.items():
        if len(data_points) < 2:
            continue

        # Sort by datetime
        data_points.sort(key=lambda x: x["datetime"])

        # Calculate trend metrics
        throughputs = [
            p["throughput"] for p in data_points if pd.notna(p["throughput"])
        ]
        latencies = [
            p["latency_avg"] for p in data_points if pd.notna(p["latency_avg"])
        ]

        if len(throughputs) >= 2:
            # Calculate performance change from first to last
            first_throughput = throughputs[0]
            last_throughput = throughputs[-1]

            if first_throughput > 0:
                throughput_change = (
                    (last_throughput - first_throughput) / first_throughput
                ) * 100
            else:
                throughput_change = 0

            # Calculate trend direction and stability
            if len(throughputs) >= 3:
                # Simple linear trend calculation
                x_values = list(range(len(throughputs)))
                trend_slope = (
                    np.polyfit(x_values, throughputs, 1)[0]
                    if len(throughputs) > 1
                    else 0
                )
                trend_direction = (
                    "improving"
                    if trend_slope > 0
                    else "declining" if trend_slope < 0 else "stable"
                )

                # Calculate coefficient of variation for stability
                cv = (
                    np.std(throughputs) / np.mean(throughputs) * 100
                    if np.mean(throughputs) > 0
                    else 0
                )
                stability = (
                    "stable" if cv < 10 else "variable" if cv < 25 else "unstable"
                )
            else:
                trend_direction = (
                    "improving"
                    if throughput_change > 5
                    else "declining" if throughput_change < -5 else "stable"
                )
                stability = "insufficient_data"

            trends[config_key] = {
                "config": config_key,
                "throughput_change_percent": throughput_change,
                "trend_direction": trend_direction,
                "stability": stability,
                "data_points": len(data_points),
                "first_run": data_points[0]["timestamp"],
                "last_run": data_points[-1]["timestamp"],
                "avg_throughput": np.mean(throughputs),
                "best_throughput": max(throughputs),
                "worst_throughput": min(throughputs),
            }

    return trends


def generate_comparison_report(comparison_data, trends, report_dir):
    """Generate comparison report with multiple runs and trend analysis."""

    # Create comparison summary
    comparison_summary = []
    for run_data in comparison_data:
        df = run_data["df"]
        summary = {
            "timestamp": run_data["timestamp"],
            "datetime": run_data["datetime"].strftime("%Y-%m-%d %H:%M:%S"),
            "total_configs": len(df),
            "avg_throughput": df["ReqPerSec"].mean(),
            "max_throughput": df["ReqPerSec"].max(),
            "avg_latency": df["Latency_Avg"].mean(),
            "json_files": run_data["json_count"],
        }
        comparison_summary.append(summary)

    # Generate comparison CSV
    comparison_csv_path = os.path.join(report_dir, "comparison_summary.csv")
    comparison_df = pd.DataFrame(comparison_summary)
    comparison_df.to_csv(comparison_csv_path, index=False)

    # Generate trends CSV
    if trends:
        trends_csv_path = os.path.join(report_dir, "performance_trends.csv")
        trends_df = pd.DataFrame(list(trends.values()))
        trends_df.to_csv(trends_csv_path, index=False)

        print(f"Generated comparison summary: {comparison_csv_path}")
        print(f"Generated trends analysis: {trends_csv_path}")

    return comparison_summary


def generate_trend_charts(trends, report_dir):
    """Generate trend visualization charts."""
    if not trends:
        return []

    charts = []

    # Group trends by client for better visualization
    client_trends = {}
    for config_key, trend_data in trends.items():
        client = config_key.split("_")[0]
        if client not in client_trends:
            client_trends[client] = []
        client_trend_data.append(trend_data)

    # Generate chart for each client
    for client, client_trend_data in client_trends.items():
        plt.figure(figsize=(12, 6))

        # Sort by average throughput for consistent ordering
        client_trend_data.sort(key=lambda x: x["avg_throughput"], reverse=True)

        configs = [
            trend["config"].replace(f"{client}_", "").replace("_", "\n")
            for trend in client_trend_data
        ]
        throughput_changes = [
            trend["throughput_change_percent"] for trend in client_trend_data
        ]

        # Color code by trend direction
        colors = []
        for trend in client_trend_data:
            if trend["trend_direction"] == "improving":
                colors.append("green")
            elif trend["trend_direction"] == "declining":
                colors.append("red")
            else:
                colors.append("gray")

        plt.bar(range(len(configs)), throughput_changes, color=colors, alpha=0.7)
        plt.xlabel("Configuration")
        plt.ylabel("Performance Change (%)")
        plt.title(f"Performance Trends: {client}")
        plt.xticks(range(len(configs)), configs, rotation=45, ha="right")
        plt.axhline(y=0, color="black", linestyle="-", alpha=0.3)
        plt.grid(True, alpha=0.3)
        plt.tight_layout()

        # Save chart
        chart_path = os.path.join(report_dir, f"trends_{client}.png")
        plt.savefig(chart_path, dpi=300, bbox_inches="tight")
        plt.close()

        charts.append(f"trends_{client}.png")

    return charts


def process_single_directory(results_dir):
    """Process a single results directory and return processed data and file groups."""
    # Find all JSON result files
    all_files = []
    try:
        for filename in os.listdir(results_dir):
            if filename.endswith(".json"):
                all_files.append(os.path.join(results_dir, filename))
    except OSError as e:
        print(f"Error reading results directory '{results_dir}': {e}")
        return None, None

    if not all_files:
        print(f"No result files (*.json) found in {results_dir}!")
        return None, None

    # Group files by configuration and find median
    file_groups = {}
    for filepath in all_files:
        filename = os.path.basename(filepath)
        try:
            implementation, mode, req_type, concurrency, file_duration, client_name = (
                parse_filename(filename)
            )

            if concurrency == 0 or req_type == "unknown":
                continue

            throughput = get_throughput_from_json(filepath)
            if throughput <= 0:
                continue

            config_key = (client_name, mode, req_type, concurrency, file_duration)
            if config_key not in file_groups:
                file_groups[config_key] = []
            file_groups[config_key].append(
                {
                    "filepath": filepath,
                    "throughput": throughput,
                    "filename": filename,
                    "implementation": implementation,
                }
            )

        except Exception as e:
            print(f"  Warning: Error processing file {filename}: {e}")
            continue

    # Find median files and process them
    data = []
    for config_key, files in file_groups.items():
        if not files:
            continue

        files.sort(key=lambda x: x["throughput"])
        median_file = files[len(files) // 2]

        client_name, mode, req_type, concurrency, file_duration = config_key

        try:
            with open(median_file["filepath"], "r") as f:
                result_json = json.load(f)

            # Extract metrics with safe handling
            def safe_float(value, default=0.0):
                if (
                    value is None
                    or value == ""
                    or (isinstance(value, str) and value.strip() == "")
                ):
                    return default
                try:
                    return float(value)
                except (ValueError, TypeError):
                    return default

            # Priority for sorting
            def get_client_priority(client):
                client_lower = str(client).lower()
                if "valkey-glide" in client_lower:
                    return 1
                elif "iovalkey" in client_lower:
                    return 2
                elif "ioredis" in client_lower:
                    return 3
                return 4

            req_per_sec = safe_float(result_json.get("requests", {}).get("average", 0))
            latency_avg = safe_float(result_json.get("latency", {}).get("average", 0))
            latency_p50 = safe_float(result_json.get("latency", {}).get("p50", 0))
            latency_p99 = safe_float(result_json.get("latency", {}).get("p99", 0))

            # Additional metrics
            rate_limit_hits = safe_float(result_json.get("rateLimitHits", 0))
            cpu_usage = safe_float(
                result_json.get("resources", {}).get("cpu", {}).get("average", 0)
            )
            memory_usage = safe_float(
                result_json.get("resources", {}).get("memory", {}).get("average", 0)
            )
            errors = result_json.get('errors', 0)
            timeouts = result_json.get('timeouts', 0)
            total_errors = result_json.get(
                "totalErrors",
                (
                    errors + timeouts
                    if isinstance(errors, (int, float))
                    and isinstance(timeouts, (int, float))
                    else 0
                ),
            )

            data.append(
                {
                    "Client": client_name,
                    "Mode": mode,
                    "RequestType": req_type,
                    "Concurrency": concurrency,
                    "Duration": file_duration,
                    "Priority": get_client_priority(client_name),
                    "ReqPerSec": safe_float(req_per_sec),
                    "Latency_Avg": safe_float(latency_avg),
                    "Latency_P50": safe_float(latency_p50),
                    "Latency_P99": safe_float(latency_p99),
                    "RateLimitHits": int(safe_float(rate_limit_hits)),
                    "CPUUsage": safe_float(cpu_usage),
                    "MemoryUsage": safe_float(memory_usage),
                    "Errors": int(errors) if isinstance(errors, (int, float)) else 0,
                    "Timeouts": (
                        int(timeouts) if isinstance(timeouts, (int, float)) else 0
                    ),
                    "TotalErrors": (
                        int(total_errors)
                        if isinstance(total_errors, (int, float))
                        else 0
                    ),
                }
            )

        except Exception as e:
            print(f"  Warning: Error processing file {median_file['filename']}: {e}")
            continue

    if not data:
        return None, None

    return pd.DataFrame(data), file_groups


def extract_median_results(results_base_dir, output_dir):
    """
    Extract median performing files for each configuration across all runs.

    Args:
        results_base_dir: Base directory containing timestamped result directories
        output_dir: Directory to store the curated median results

    Returns:
        str: Path to the created median results directory
    """
    print("Extracting median results across all runs...")

    # Find all timestamped directories
    run_dirs = find_comparison_directories(results_base_dir)
    if len(run_dirs) < 2:
        print(
            f"Warning: Only found {len(run_dirs)} run directories. Need at least 2 for median extraction."
        )
        return None

    print(f"Found {len(run_dirs)} run directories to analyze")

    # Collect all files across all runs, grouped by configuration
    config_files = {}  # config_key -> list of (filepath, throughput, run_timestamp)

    for run_info in run_dirs:
        run_dir = run_info["timestamp"]
        run_path = run_info["path"]
        json_count = run_info["json_count"]

        print(f"  Analyzing {run_dir} ({json_count} files)...")

        # Get all JSON files in this run directory
        json_files = [f for f in os.listdir(run_path) if f.endswith(".json")]

        for json_file in json_files:
            filepath = os.path.join(run_path, json_file)
            try:
                (
                    implementation,
                    mode,
                    req_type,
                    concurrency,
                    file_duration,
                    client_name,
                ) = parse_filename(json_file)

                if concurrency == 0 or req_type == "unknown":
                    continue

                throughput = get_throughput_from_json(filepath)
                # Allow zero throughput files for analysis (e.g., failed cluster runs)
                if throughput < 0:
                    continue

                # Extract rateLimitHits to detect failed runs
                rate_limit_hits = 0
                try:
                    with open(filepath, "r") as f:
                        result_json = json.load(f)
                    rate_limit_hits = result_json.get("rateLimitHits", 0)
                except Exception:
                    rate_limit_hits = 0

                config_key = (client_name, mode, req_type, concurrency, file_duration)
                if config_key not in config_files:
                    config_files[config_key] = []

                config_files[config_key].append(
                    {
                        "filepath": filepath,
                        "throughput": throughput,
                        "rate_limit_hits": rate_limit_hits,
                        "filename": json_file,
                        "run_timestamp": run_dir,
                        "implementation": implementation,
                    }
                )

            except Exception as e:
                print(f"    Warning: Error processing {json_file}: {e}")
                continue

    # Check for configurations where all runs failed (all have zero rateLimitHits)
    failed_configs = []
    for config_key, files in config_files.items():
        client_name, mode, req_type, concurrency, file_duration = config_key
        all_zero_rate_limits = all(
            file_info["rate_limit_hits"] == 0 for file_info in files
        )

        if all_zero_rate_limits and len(files) > 0:
            failed_configs.append(
                {
                    "config": config_key,
                    "files": files,
                    "reason": "All runs have zero rateLimitHits - rate limiting not working",
                }
            )

    # Report failed configurations as errors
    if failed_configs:
        print(
            f"\n❌ ERROR: Found {len(failed_configs)} configurations where all runs failed:"
        )
        for failed_config in failed_configs:
            client_name, mode, req_type, concurrency, file_duration = failed_config[
                "config"
            ]
            files = failed_config["files"]
            print(
                f"  - {client_name} {mode} {req_type} {concurrency}c {file_duration}s:"
            )
            print(f"    Reason: {failed_config['reason']}")
            print(f"    Files checked: {len(files)}")
            for file_info in files:
                print(
                    f"      {file_info['filename']}: throughput={file_info['throughput']:.1f}, rateLimitHits={file_info['rate_limit_hits']}"
                )
            print()

        # Don't raise an exception, but clearly mark these as failed
        print("⚠️  These configurations will be excluded from median extraction.")
        print(
            "⚠️  This indicates a fundamental issue with rate limiting in these configurations."
        )
        print()

    # Create output directory
    os.makedirs(output_dir, exist_ok=True)

    # For each configuration, find median and copy file (excluding failed configs)
    median_files_copied = 0
    total_configs = len(config_files)

    print(f"\nExtracting median files for {total_configs} configurations...")

    for config_key, files in config_files.items():
        # Skip configurations where all runs failed (zero rateLimitHits)
        client_name, mode, req_type, concurrency, file_duration = config_key
        all_zero_rate_limits = all(
            file_info["rate_limit_hits"] == 0 for file_info in files
        )

        if all_zero_rate_limits:
            print(
                f"  Skipping failed config: {client_name} {mode} {req_type} {concurrency}c {file_duration}s"
            )
            continue

        if len(files) < 2:
            print(
                f"  Warning: Only {len(files)} files found for config {config_key}, skipping"
            )
            continue

        # Sort by throughput and find median
        files.sort(key=lambda x: x["throughput"])
        median_idx = len(files) // 2
        median_file = files[median_idx]

        # Copy median file to output directory
        src_path = median_file["filepath"]
        dst_path = os.path.join(output_dir, median_file["filename"])

        try:
            shutil.copy2(src_path, dst_path)
            median_files_copied += 1

            client_name, mode, req_type, concurrency, file_duration = config_key
            print(
                f"  ✓ {client_name} {mode} {req_type} {concurrency}c {file_duration}s -> {median_file['filename']}"
            )
            print(
                f"    Median throughput: {median_file['throughput']:.1f} req/s (from {len(files)} runs)"
            )

        except Exception as e:
            print(f"  ✗ Error copying {median_file['filename']}: {e}")
            continue

    print(f"\nSuccessfully extracted {median_files_copied} median result files")
    print(f"Median results directory: {output_dir}")

    # Create a summary file of what was extracted
    summary_path = os.path.join(output_dir, "median_extraction_summary.txt")
    with open(summary_path, "w") as f:
        f.write("Median Result Extraction Summary\n")
        f.write("================================\n\n")
        f.write(f"Extraction Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Source Directory: {results_base_dir}\n")
        f.write(f"Run Directories Analyzed: {len(run_dirs)}\n")
        f.write(f"Total Configurations Found: {total_configs}\n")
        f.write(f"Median Files Extracted: {median_files_copied}\n\n")

        f.write("Run Directories:\n")
        for run_info in run_dirs:
            f.write(
                f"  - {run_info['timestamp']}: {run_info['json_count']} JSON files\n"
            )

        f.write(f"\nConfigurations with median results:\n")
        for config_key, files in config_files.items():
            if len(files) >= 2:
                client_name, mode, req_type, concurrency, file_duration = config_key
                files.sort(key=lambda x: x["throughput"])
                median_file = files[len(files) // 2]
                f.write(
                    f"  - {client_name} {mode} {req_type} {concurrency}c {file_duration}s: {median_file['throughput']:.1f} req/s\n"
                )

    return output_dir


def main():
    parser = argparse.ArgumentParser(
        description="Generate a benchmark report from JSON results, using median throughput runs."
    )
    parser.add_argument(
        "results_dir",
        nargs="?",
        default=DEFAULT_RESULTS_DIR,
        help=f"Directory containing the JSON result files (default: {DEFAULT_RESULTS_DIR})",
    )
    parser.add_argument(
        "--compare-runs",
        action="store_true",
        help="Compare performance across multiple result directories (requires multiple runs in parent directory)",
    )
    parser.add_argument(
        "--include-trends",
        action="store_true",
        help="Include trend analysis and performance change detection",
    )
    parser.add_argument(
        "--baseline",
        type=str,
        help="Specify a baseline directory for comparison (used with --compare-runs)",
    )
    parser.add_argument(
        "--output-format",
        choices=["html", "csv", "both"],
        default="both",
        help="Output format for the report (default: both)",
    )
    parser.add_argument(
        "--extract-median",
        action="store_true",
        help="Extract median performing files for each configuration across all runs and generate dashboard from curated dataset",
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

    # Handle median extraction mode
    if args.extract_median:
        # For median extraction, we expect the parent directory containing multiple timestamped runs
        if results_dir.endswith("/latest") or results_dir.endswith("latest"):
            # Navigate to parent results directory
            results_base_dir = os.path.dirname(results_dir)
        else:
            results_base_dir = (
                os.path.dirname(results_dir)
                if os.path.basename(results_dir).startswith("202")
                else results_dir
            )

        print(
            f"Median extraction mode: Analyzing runs in {os.path.abspath(results_base_dir)}"
        )

        # Create median results directory
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        median_dir = os.path.join(results_base_dir, f"median_results_{timestamp}")

        # Extract median files
        extracted_dir = extract_median_results(results_base_dir, median_dir)
        if extracted_dir is None:
            print("Error: Failed to extract median results")
            exit(1)

        print(f"\n" + "=" * 60)
        print("MEDIAN EXTRACTION COMPLETE")
        print("=" * 60)
        print(f"Curated dataset: {extracted_dir}")

        # Now generate dashboard from the median results
        print(f"\nGenerating dashboard from curated median dataset...")
        results_dir = extracted_dir
        # Continue with normal single-directory processing below

    # Handle comparison mode
    elif args.compare_runs:
        # For comparison, we expect the parent directory containing multiple timestamped runs
        if results_dir.endswith("/latest") or results_dir.endswith("latest"):
            # Navigate to parent results directory
            results_base_dir = os.path.dirname(results_dir)
        else:
            results_base_dir = (
                os.path.dirname(results_dir)
                if os.path.basename(results_dir).startswith("202")
                else results_dir
            )

        print(
            f"Comparison mode: Looking for multiple runs in {os.path.abspath(results_base_dir)}"
        )

        # Find all comparison directories
        comparison_dirs = find_comparison_directories(results_base_dir)

        if len(comparison_dirs) < 2:
            print(
                f"Error: Need at least 2 benchmark runs for comparison. Found {len(comparison_dirs)} runs."
            )
            print("Available directories:")
            for d in comparison_dirs:
                print(f"  - {d['timestamp']} ({d['json_count']} JSON files)")
            exit(1)

        print(f"Found {len(comparison_dirs)} benchmark runs for comparison:")
        for d in comparison_dirs:
            print(f"  - {d['timestamp']}: {d['json_count']} JSON files")

        # Process each directory
        comparison_data = []
        for comp_dir in comparison_dirs:
            print(f"\nProcessing {comp_dir['timestamp']}...")
            df = process_single_directory(comp_dir["path"])
            if df is not None and not df.empty:
                comparison_data.append(
                    {
                        "timestamp": comp_dir["timestamp"],
                        "datetime": comp_dir["datetime"],
                        "path": comp_dir["path"],
                        "df": df,
                        "json_count": comp_dir["json_count"],
                    }
                )
            else:
                print(f"  Warning: No valid data found in {comp_dir['timestamp']}")

        if len(comparison_data) < 2:
            print("Error: Need at least 2 directories with valid data for comparison.")
            exit(1)

        # Create comparison report directory
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        comparison_report_dir = os.path.join(
            results_base_dir, f"comparison_report_{timestamp}"
        )
        os.makedirs(comparison_report_dir, exist_ok=True)

        print(f"\nGenerating comparison report in: {comparison_report_dir}")

        # Calculate trends if requested
        trends = {}
        if args.include_trends:
            print("Calculating performance trends...")
            trends = calculate_performance_trends(comparison_data)
            print(f"Analyzed trends for {len(trends)} configurations")

        # Generate comparison report
        comparison_summary = generate_comparison_report(
            comparison_data, trends, comparison_report_dir
        )

        # Generate trend charts if requested
        if args.include_trends and trends:
            print("Generating trend visualization charts...")
            trend_charts = generate_trend_charts(trends, comparison_report_dir)
            print(f"Generated {len(trend_charts)} trend charts")

        # Use the latest run's data for the main HTML report
        latest_data = comparison_data[-1]
        df = latest_data["df"]

        # Generate enhanced HTML report with comparison data
        print("Generating enhanced HTML report with comparison data...")
        generate_html_report(
            df,
            comparison_report_dir,
            latest_data["path"],
            comparison_data=comparison_data,
            trends=trends if args.include_trends else None,
        )

        # Generate CSV summary
        if args.output_format in ["csv", "both"]:
            summary_csv_path = os.path.join(comparison_report_dir, SUMMARY_CSV_FILENAME)
            print(f"Generating summary CSV at: {summary_csv_path}")
            try:
                csv_columns = [
                    "Client",
                    "Mode",
                    "RequestType",
                    "Concurrency",
                    "Duration",
                    "ReqPerSec",
                    "Latency_Avg",
                    "Latency_P50",
                    "Latency_P99",
                    "RateLimitHits",
                    "CPUUsage",
                    "MemoryUsage",
                ]
                cols_to_select = [col for col in csv_columns if col in df.columns] + [
                    "Priority"
                ]
                df_csv = df[cols_to_select].copy()

                def get_client_priority(client):
                    client_lower = str(client).lower()
                    if "valkey-glide" in client_lower:
                        return 1
                    elif "iovalkey" in client_lower:
                        return 2
                    elif "ioredis" in client_lower:
                        return 3
                    return 4

                df_csv["ClientPriority"] = df_csv["Client"].apply(get_client_priority)
                df_csv = df_csv.sort_values(
                    by=["RequestType", "Mode", "Concurrency", "ClientPriority"],
                    ascending=[True, True, True, True],
                ).drop(columns=["Priority", "ClientPriority"])

                df_csv = df_csv[[col for col in csv_columns if col in df_csv.columns]]
                float_cols = df_csv.select_dtypes(include=["float"]).columns
                df_csv[float_cols] = df_csv[float_cols].round(2)

                df_csv.to_csv(
                    summary_csv_path,
                    index=False,
                    quoting=csv.QUOTE_NONNUMERIC,
                    na_rep="N/A",
                )
                print(f"Successfully wrote CSV summary to {summary_csv_path}")
            except Exception as e:
                print(f"Error writing CSV summary: {e}")

        print("-" * 50)
        print(f"Comparison report generation complete!")
        print(f"Report directory: {os.path.abspath(comparison_report_dir)}")
        print(
            f"HTML Report: {os.path.abspath(os.path.join(comparison_report_dir, REPORT_HTML_FILENAME))}"
        )
        if args.output_format in ["csv", "both"]:
            print(
                f"Summary CSV: {os.path.abspath(os.path.join(comparison_report_dir, SUMMARY_CSV_FILENAME))}"
            )
        if args.include_trends:
            print(
                f"Comparison Summary: {os.path.abspath(os.path.join(comparison_report_dir, 'comparison_summary.csv'))}"
            )
            print(
                f"Trends Analysis: {os.path.abspath(os.path.join(comparison_report_dir, 'performance_trends.csv'))}"
            )
        print("-" * 50)
        return

    # Standard single-directory processing
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

    # Process the single directory
    df, file_groups = process_single_directory(results_dir)
    if df is None or df.empty:
        print("Error: No valid data processed from the result files.")
        exit(1)  # Generate report using the processed DataFrame
    html_report_path = os.path.join(report_dir, "index.html")

    # For single directory mode, we don't need to iterate through file_groups
    # The DataFrame already contains the processed median data
    generate_html_report(df, report_dir, results_dir)

    # Generate CSV if requested
    if args.output_format in ["csv", "both"]:
        csv_path = os.path.join(report_dir, "summary.csv")
        df.to_csv(csv_path, index=False)
        print(f"Successfully wrote CSV summary to {csv_path}")
    print(f"Successfully wrote HTML report to {os.path.join(report_dir, 'index.html')}")
    print(f"Report directory: {report_dir}")


if __name__ == "__main__":
    main()
