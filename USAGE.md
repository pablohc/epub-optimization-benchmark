# EPUB Optimization Benchmark - Quick Start Guide

## Overview
This toolkit allows you to capture and analyze performance logs from e-book reader devices to compare ORIGINAL vs OPTIMIZED EPUB files.

## Scripts Available

### 1. Capture Scripts

#### **Capture-Dual-Devices.ps1**
Capture logs from TWO devices simultaneously.
- **Use case:** Direct comparison between two devices
- **Example:** Compare Device A (ORIGINAL) vs Device B (OPTIMIZED)
- **Output:** Two log files with book names in filenames

```powershell
.\Capture-Dual-Devices.ps1
# Interactive prompts will ask for book names on each device
```

#### **Capture-Single-Device.ps1**
Capture logs from ONE device at a time.
- **Use case:** Sequential testing or single device analysis
- **Example:** Test one device now, another device later
- **Output:** Single log file with book name in filename

```powershell
.\Capture-Single-Device.ps1 -ComPort "COM3"
# Interactive prompt will ask for book name
```

### 2. Analysis Script

#### **Analyze-Logs-Specific.ps1**
Analyze captured logs and generate performance comparisons.

```powershell
.\Analyze-Logs-Specific.ps1
# Automatically detects books or asks interactively
```

## Typical Workflows

### Workflow 1: Dual Device Testing (Recommended)
```
1. Run Capture-Dual-Devices.ps1
   - Specify ORIGINAL for Device A
   - Specify OPTIMIZED for Device B
   - Start capturing, open books on both devices
   - Stop capture when done

2. Run Analyze-Logs-Specific.ps1
   - Automatically detects book names from metadata
   - Shows comprehensive performance comparison
   - Generates CSV and charts
```

### Workflow 2: Sequential Single Device Testing
```
1. Run Capture-Single-Device.ps1 -ComPort "COM3"
   - Specify ORIGINAL
   - Capture first device

2. Run Capture-Single-Device.ps1 -ComPort "COM4"
   - Specify OPTIMIZED
   - Capture second device

3. Run Analyze-Logs-Specific.ps1
   - Select the two log files manually if needed
   - Get comparison results
```

### Workflow 3: Device Validation
```
1. Run Capture-Dual-Devices.ps1
   - Specify ORIGINAL for BOTH devices
   - Test if both devices perform equally

2. Run Analyze-Logs-Specific.ps1
   - Shows "Device Performance Comparison"
   - Validates device consistency
```

## File Naming Convention

**New format (with metadata):**
```
com3_ORIGINAL_20260312_234500.txt
com4_OPTIMIZED_20260312_234500.txt
```

**Old format (still supported):**
```
com3_A_20260312_234500.txt
com4_B_20260312_234500.txt
```

## Book Name Options

During capture, you can specify:
- **ORIGINAL** - Non-optimized EPUB
- **OPTIMIZED** - Optimized EPUB
- **Custom name** - Any other name (e.g., "TEST_V1", "EXPERIMENTAL")

## Analysis Features

The analysis script provides:
- **Automatic detection** of book names from metadata
- **Interactive fallback** if books can't be detected
- **Extended statistics**: Min, Max, Median, Std Dev, P95, P99
- **Consistency analysis**: Coefficient of Variation
- **Performance highlights**: Best/worst cases
- **Optimization impact**: Detects regressions
- **Visual charts**: Bar charts and trend lines
- **CSV export**: For further analysis

## Tips

1. **Always specify the correct book name** during capture for accurate analysis
2. **Use dual capture** when possible for more consistent results
3. **Capture 20-30 pages** minimum for meaningful statistics
4. **Same book on both devices** validates device performance
5. **Different books** measures optimization effectiveness