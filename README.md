# EPUB Optimization Benchmark

Tools for testing and benchmarking EPUB optimization performance on XTEink X4 e-reader devices.

## Overview

This repository contains PowerShell scripts for dual-device testing, allowing you to:
- Capture serial logs from two XTEink X4 devices simultaneously
- Analyze and compare page rendering performance
- Validate EPUB optimization improvements

## Purpose

Validate and measure the performance impact of EPUB optimization features by comparing:
- **Original EPUB files** vs **Optimized EPUB files**
- Page rendering times
- Memory usage
- Overall user experience

## Scripts

### Core Scripts

#### **Capture-Dual-Devices.ps1**
Capture logs from two devices simultaneously with book name specification.

```powershell
.\Capture-Dual-Devices.ps1
```

**Features:**
- Interactive book name specification (ORIGINAL/OPTIMIZED/Custom)
- Dual device capture (COM3 + COM4)
- Metadata embedding for automatic analysis
- Real-time byte counter
- Automatic file naming with book names and timestamps
- Error handling and recovery

#### **Capture-Single-Device.ps1**
Capture logs from a single device with book name specification.

```powershell
.\Capture-Single-Device.ps1 -ComPort "COM3"
```

**Features:**
- Interactive book name specification
- Single device capture (configurable port)
- Metadata embedding for automatic analysis
- Real-time byte counter
- Automatic file naming with book names and timestamps
- Useful for sequential testing

#### **Analyze-Logs-Specific.ps1**
Analyze captured logs and compare performance metrics.

```powershell
.\Analyze-Logs-Specific.ps1
```

**Features:**
- Automatic book name detection from metadata
- Interactive fallback if books can't be detected
- Page-by-page comparison with dynamic column names
- Extended statistics (Min, Max, Median, Std Dev, P95, P99)
- Consistency analysis with coefficient of variation
- Performance highlights and optimization impact
- Detects regressions when optimization makes things worse
- Context-aware naming (Device vs File comparison)
- CSV export and visual chart generation

#### **Diagnose-Complete.ps1**
Diagnose device connectivity and data transmission issues.

```powershell
.\Diagnose-Complete.ps1
```

**Features:**
- Port availability detection
- Data transmission verification
- Permission checking
- Troubleshooting recommendations

## Requirements

- **Windows PowerShell 5.1+** (included with Windows 10+)
- **Two XTEink X4 devices** connected via USB
- **.NET Framework** (included with Windows)
- **Debug-enabled firmware** on devices

## Quick Start

### 1. Device Setup

Connect two XTEink X4 devices via USB and verify they're detected:

```powershell
[System.IO.Ports.SerialPort]::GetPortNames()
```

Expected output:
```
COM3
COM4
```

### 2. Start Capture

**Option A: Dual Device Capture (Recommended)**

```powershell
.\Capture-Dual-Devices.ps1
```

**Follow the interactive prompts:**
1. Specify book for Device A (COM3): `1` for ORIGINAL
2. Specify book for Device B (COM4): `2` for OPTIMIZED
3. Press ENTER to start
4. Wait for devices to restart (3 seconds)
5. Open books on both devices as specified
6. Navigate through 20-30 pages synchronously
7. Press Ctrl+C to stop

**Option B: Single Device Capture**

```powershell
.\Capture-Single-Device.ps1 -ComPort "COM3"
```

For single device testing, repeat for each device with the appropriate book.

### 3. Analyze Results

```powershell
.\Analyze-Logs-Specific.ps1
```

The script will automatically:
- Detect book names from capture metadata
- Display comprehensive performance comparison
- Generate CSV export and visual charts
- Show extended statistics and optimization impact

## Example Output

```
Render Time Comparison:

Page COM3_A_ms COM4_B_ms Diff_ms Percent Winner
---- --------- --------- ------- ------- ------
   1      4805      2455    2350  48.9%   B
   2      1809      1811      -2   -0.1%   =
   3      2957      2261     696  23.5%   B

Summary:
  COM3 won: 2 pages
  COM4 won: 15 pages
  Ties: 5 pages

Averages:
  COM3 (Device A): 2112 ms
  COM4 (Device B): 1350 ms

  Average: COM4 is 762 ms faster (36.1%)
```

## Output Files

Logs are saved in `./logs/` directory:

```
logs/
├── com3_ORIGINAL_20260312_181435.txt      # Device A raw log with book name
├── com4_OPTIMIZED_20260312_181435.txt     # Device B raw log with book name
└── analysis_ORIGINAL_vs_OPTIMIZED_*.csv  # Performance comparison
```

**New file naming convention:**
- Includes book name for automatic analysis
- Metadata embedded in log files
- Clear identification of test scenario

## Configuration

### Default Serial Ports

**For Capture-Dual-Devices.ps1:**

```powershell
.\Capture-Dual-Devices.ps1 -ComPortA "COM3" -ComPortB "COM4"
```

**For Capture-Single-Device.ps1:**

```powershell
.\Capture-Single-Device.ps1 -ComPort "COM3"
```

### Book Name Options

During capture, choose from:
- **1. ORIGINAL** - Non-optimized EPUB
- **2. OPTIMIZED** - Optimized EPUB
- **3. Custom name** - Any descriptive name (e.g., "TEST_V1")

### Tie Threshold

Edit `Analyze-Logs-Specific.ps1` to change tie threshold:

```powershell
# Currently: < 1% difference = tie
$winner = if ([Math]::Abs($percent) -lt 1) { "=" }
```

## Documentation

- [USAGE.md](USAGE.md) - Quick start guide with typical workflows
- [Dual-Device-Testing-Protocol.md](Dual-Device-Testing-Protocol.md) - Testing protocol for parallel device testing
- [Visual-Observation-Template.md](Visual-Observation-Template.md) - Visual observation template for quality assessment

## Troubleshooting

### Devices not detected

1. Check USB connections
2. Install USB-Serial drivers
3. Open Device Manager: `devmgmt.msc`
4. Look under "Ports (COM & LPT)"

### No data captured

1. Verify debug logging is enabled in firmware
2. Check baudrate is 115200
3. Ensure devices are powered on
4. Run diagnosis: `.\Diagnose-Complete.ps1`

### "Port in use" error

1. Close other applications using serial ports
2. Restart devices
3. Restart PowerShell session

## License

MIT License - See [LICENSE](LICENSE) file for details

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Related Projects

- [crosspoint-reader](https://github.com/your-org/crosspoint-reader) - Main e-reader application
- EPUB optimization tools and utilities

## Version History

- **v2.0.0** (2025-03-12) - Enhanced capture system
  - Interactive book name specification
  - Single and dual device capture scripts
  - Metadata embedding for automatic analysis
  - Extended statistics and analysis
  - Context-aware performance comparisons

- **v1.0.0** (2025-03-12) - Initial release
  - Dual device capture
  - Performance analysis
  - Diagnostic tools

## Authors

Created for EPUB optimization validation and testing.
