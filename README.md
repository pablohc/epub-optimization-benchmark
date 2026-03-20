# EPUB Optimization Benchmark

Tools for capturing and analyzing EPUB rendering performance on e-ink devices via serial logging.
Designed to validate the impact of EPUB optimization by comparing page render times between
an original and an optimized version of the same book.

## Overview

The benchmark captures serial debug output from one or two e-reader devices simultaneously,
then analyzes and compares page-by-page render times. Results are exported as JSON, CSV,
and Markdown reports.

## Requirements

- Windows PowerShell 5.1+ (included with Windows 10+)
- One or two e-reader devices connected via USB (COM ports)
- Debug-enabled firmware on the device(s)
- Python 3.x (for statistical analysis only)

## Repository Structure

```
EPUB-Optimization-Benchmark.ps1   Main script — capture + analysis (interactive menu)
statistical_analysis.py            Statistical analysis across multiple sessions
run_analysis.bat                   Double-click launcher for statistical_analysis.py
USAGE.md                           Detailed usage guide for all workflows
STATISTICAL_TESTING_PLAN.md        Statistical methodology and analysis approach
Dual-Device-Testing-Protocol.md    Physical testing protocol for dual-device sessions
Visual-Observation-Template.md     Template for manual visual quality observations
logs/                              All captured logs and generated analysis files
logs/firmware_cache/               Cached firmware detection results (auto-managed)
```

## Quick Start

### 1. Connect Devices

Connect your device(s) via USB and verify the COM ports are detected:

```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```

### 2. Run the Benchmark Script

```powershell
.\EPUB-Optimization-Benchmark.ps1
```

The interactive menu will guide you through capture and analysis:

```
[1] Capture - Single Device
[2] Capture - Dual Devices
[3] Analyze Logs
[0] Exit
```

For dual-device testing (recommended), select `[2]`, assign ORIGINAL and OPTIMIZED to each
device, navigate through pages on both devices simultaneously, then press Ctrl+C to stop.
Analysis runs automatically after capture.

### 3. Statistical Analysis (multi-session)

After accumulating several sessions, run the statistical analysis across all of them:

```powershell
py statistical_analysis.py
```

Or double-click `run_analysis.bat`.

## Output Files

All files are saved to `logs/`:

| File | Description |
|------|-------------|
| `COM{port}_{TYPE}_{BOOK}_{timestamp}.txt` | Raw serial log |
| `analysis_{...}_{timestamp}.json` | Machine-readable analysis (page-level data) |
| `analysis_{...}_{timestamp}.csv` | Tabular comparison for spreadsheets |
| `analysis_{...}_{timestamp}.md` | Human-readable formatted report |
| `statistical_pages.csv` | Cross-session page-level data (from statistical_analysis.py) |
| `statistical_books.csv` | Cross-session book-level summary (from statistical_analysis.py) |

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-DebugMode` | Show all received serial data during capture |
| `-SkipReset` | Skip device reset before capture starts |

```powershell
.\EPUB-Optimization-Benchmark.ps1 -DebugMode -SkipReset
```

## Page Markers

Analysis reports use markers to flag special conditions:

| Marker | Meaning |
|--------|---------|
| `[X]` | JPEG decode failure |
| `[!]` | Image count discrepancy or cover generation mismatch |
| `[-]` | Progressive JPEG detected (lower quality) |
| `[~]` | Page offset effect |
| `[R]` | E-ink half-refresh cycle |

## Documentation

- [USAGE.md](USAGE.md) — Detailed workflows and all options
- [STATISTICAL_TESTING_PLAN.md](STATISTICAL_TESTING_PLAN.md) — Statistical methodology
- [Dual-Device-Testing-Protocol.md](Dual-Device-Testing-Protocol.md) — Physical testing protocol
- [Visual-Observation-Template.md](Visual-Observation-Template.md) — Manual quality observation form
