# EPUB Optimization Benchmark — Usage Guide

## Running the Main Script

```powershell
.\EPUB-Optimization-Benchmark.ps1
```

Optional parameters:

| Parameter | Effect |
|-----------|--------|
| `-DebugMode` | Print all received serial bytes to console during capture |
| `-SkipReset` | Do not reset the device before capture starts |

---

## Main Menu

```
[1] Capture - Single Device
[2] Capture - Dual Devices
[3] Analyze Logs
[0] Exit
```

---

## Workflow A: Dual Device Capture (Recommended)

Best for ORIGINAL vs OPTIMIZED comparisons. Both devices capture simultaneously, eliminating
timing variables between sessions.

**Steps:**

1. Select `[2] Capture - Dual Devices`
2. Select the COM port for the LEFT device (e.g. COM3)
3. Select the COM port for the RIGHT device (e.g. COM4)
4. Choose the book type for each device:
   - `[1] ORIGINAL` — non-optimized EPUB
   - `[2] OPTIMIZED` — optimized EPUB
   - `[3] Custom` — any label (e.g. a firmware variant name)
5. The script resets both devices and starts capturing
6. Open the same book on both devices and navigate through pages simultaneously
7. Press `Ctrl+C` to stop capture
8. Analysis runs automatically and exports JSON, CSV, and Markdown to `logs/`

The script remembers selected ports and book types within the same session.

---

## Workflow B: Single Device Capture

For sequential testing or when only one device is available.

**Steps:**

1. Select `[1] Capture - Single Device`
2. Select the COM port
3. Choose the book type (`ORIGINAL`, `OPTIMIZED`, or custom)
4. Navigate through pages on the device
5. Press `Ctrl+C` to stop
6. Repeat for the second device/version
7. Use `[3] Analyze Logs` to compare the two captures

---

## Workflow C: Analyze Existing Logs

Select `[3] Analyze Logs` to analyze previously captured log files.

The script groups logs by session (same timestamp) and lists them with letter labels.

**Selection options:**

| Input | Effect |
|-------|--------|
| Session letter (e.g. `a`) | Select all logs from that session |
| Two numbers (e.g. `1,3`) | Compare two specific log files |
| `ALL` | Batch-analyze all valid sessions (export only, no display) |

After selecting logs, choose a chart type:

```
[1] Bar Chart       — page render times comparison
[2] Trend Chart     — render times over time
[3] Statistics Chart — performance metrics comparison
[4] All Charts
```

---

## Book Type Options

| Option | Label | Use for |
|--------|-------|---------|
| `1` | `ORIGINAL` | Non-optimized EPUB |
| `2` | `OPTIMIZED` | Optimized EPUB |
| `3` | Custom | Any other variant (firmware A/B, different encoder settings, etc.) |

---

## File Naming Convention

Captured log files follow this pattern:

```
COM{port}_{TYPE}_{BOOKNAME}_{timestamp}.txt
```

Example:
```
COM3_ORIGINAL_My_Book_Title.epub_20260320_143022.txt
COM4_OPTIMIZED_My_Book_Title.epub_20260320_143022.txt
```

Analysis output files share the same timestamp:
```
analysis_ORIGINAL_vs_OPTIMIZED_My_Book_Title_20260320_143022.json
analysis_ORIGINAL_vs_OPTIMIZED_My_Book_Title_20260320_143022.csv
analysis_ORIGINAL_vs_OPTIMIZED_My_Book_Title_20260320_143022.md
```

---

## Page Markers in Analysis Output

| Marker | Meaning |
|--------|---------|
| `[X]` | JPEG decode failure on that page |
| `[!]` | Image count discrepancy or cover generation mismatch between versions |
| `[-]` | Progressive JPEG detected (may indicate lower quality) |
| `[~]` | Page offset effect (e-ink display artifact) |
| `[R]` | E-ink half-refresh cycle detected |

Pages marked `[X]` or `[!]` indicate an unfair comparison — the two versions did not perform
the same work, so timing differences should be interpreted with caution.

---

## Statistical Analysis (Multi-Session)

After accumulating multiple ORIGINAL vs OPTIMIZED sessions, run a cross-session statistical
analysis to validate results with confidence intervals and significance tests.

```powershell
py statistical_analysis.py
```

Or double-click `run_analysis.bat`.

The script reads all `analysis_ORIGINAL_vs_OPTIMIZED_*.json` files from `logs/` and produces:

- Per-category page analysis with paired t-test and 95% CI
- Per-book summary with total time saved and composition breakdown
- Global savings breakdown by content type
- Cover impact analysis for text-heavy books

Output files: `logs/statistical_pages.csv`, `logs/statistical_books.csv`

See [STATISTICAL_TESTING_PLAN.md](STATISTICAL_TESTING_PLAN.md) for methodology details.

---

## Firmware Cache

On first connection, the script queries each device for its firmware version and branch.
Results are cached in `logs/firmware_cache/firmware_COM{port}.json` (1-hour expiry) to avoid
repeated detection delays in subsequent sessions.

The cache is managed automatically — no manual action required.

---

## Troubleshooting

**Devices not detected**
- Check USB connections and drivers
- Open Device Manager (`devmgmt.msc`) → Ports (COM & LPT)

**No data captured**
- Verify debug logging is enabled in firmware
- Confirm baud rate is 115200
- Ensure devices are powered on before capture starts

**"Port in use" error**
- Close any other application using that COM port (Arduino IDE, PlatformIO monitor, etc.)
- Restart the PowerShell session

**Analysis shows no pages**
- Verify the log file contains `Rendered page in Xms` entries
- Check that both log files have the same book name in their metadata
