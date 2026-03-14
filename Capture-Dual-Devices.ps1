# Capture-Dual-Devices.ps1
# Interactive dual capture with book specification

param(
    [string]$ComPortA = "COM3",
    [string]$ComPortB = "COM4",
    [switch]$DebugMode,
    [switch]$SkipReset
)

# Create logs directory
$logsDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}

# Device identification phase
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  DUAL DEVICE CAPTURE - Device ID" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This will help you identify which COM port corresponds" -ForegroundColor Yellow
Write-Host "to each physical device (LEFT vs RIGHT)." -ForegroundColor Yellow
Write-Host ""
if ($DebugMode) {
    Write-Host "DEBUG MODE: Will show all received data for analysis" -ForegroundColor Magenta
}
if ($SkipReset) {
    Write-Host "SKIP RESET: Devices will NOT be reset (already powered on)" -ForegroundColor Magenta
}
Write-Host ""
Write-Host "Parameters: -DebugMode, -SkipReset" -ForegroundColor Gray
Write-Host ""
Write-Host "Please connect both devices to different COM ports." -ForegroundColor Yellow
Write-Host ""

# Get available COM ports
Write-Host "Detecting available COM ports..." -ForegroundColor Cyan
$availablePorts = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object | Select-Object -Unique

if ($availablePorts.Count -lt 2) {
    Write-Host "ERROR: Less than 2 COM ports detected" -ForegroundColor Red
    Write-Host "Available ports: $($availablePorts -join ', ')" -ForegroundColor Yellow
    exit 1
}

Write-Host "Found $($availablePorts.Count) COM port(s)" -ForegroundColor Green
Write-Host ""

# Display ports with numbers
Write-Host "Available COM ports:" -ForegroundColor Cyan
for ($i = 0; $i -lt $availablePorts.Count; $i++) {
    Write-Host "  [$($i+1)] $($availablePorts[$i])" -ForegroundColor White
}
Write-Host ""

# Try automatic detection via button press
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AUTOMATIC DEVICE DETECTION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This will automatically detect which COM port corresponds" -ForegroundColor Yellow
Write-Host "to each device by holding buttons for 2+ seconds." -ForegroundColor Yellow
Write-Host ""

try {
    # Step 1: Reset all devices by toggling DTR (unless SkipReset is specified)
    if (-not $SkipReset) {
        Write-Host "Resetting all connected devices..." -ForegroundColor Cyan
        foreach ($portName in $availablePorts) {
            try {
                $tempPort = New-Object System.IO.Ports.SerialPort($portName, 115200, "None", 8, "One")
                $tempPort.Open()
                # Toggle DTR to reset device
                $tempPort.DtrEnable = $true
                Start-Sleep -Milliseconds 100
                $tempPort.DtrEnable = $false
                Start-Sleep -Milliseconds 500
                $tempPort.Close()
                Write-Host "  Reset sent to $portName" -ForegroundColor Gray
            }
            catch {
                Write-Host "  WARNING: Could not reset $portName - $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "  TIP: Use -SkipReset if devices are already powered on" -ForegroundColor Yellow
            }
        }

        Write-Host ""
        Write-Host "Waiting for devices to restart..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
    else {
        Write-Host ""
        Write-Host "Skipping device reset (SkipReset specified)" -ForegroundColor Yellow
        Write-Host "Make sure devices are already powered on" -ForegroundColor Yellow
        Write-Host ""
        Start-Sleep -Seconds 1
    }

    # Step 2: Open ALL available ports to monitor them
    $testPorts = @()
    $portMap = @{} # Maps port name to SerialPort object

    Write-Host "Opening all COM ports to monitor for button presses..." -ForegroundColor Cyan
    foreach ($portName in $availablePorts) {
        try {
            $testPort = New-Object System.IO.Ports.SerialPort($portName, 115200, "None", 8, "One")
            $testPort.Open()
            $testPorts += $testPort
            $portMap[$portName] = $testPort
            Write-Host "  Opened $portName" -ForegroundColor Gray
            # Clear any initial restart data
            Start-Sleep -Milliseconds 500
            $testPort.ReadExisting() | Out-Null
        }
        catch {
            Write-Host "  WARNING: Could not open $portName - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($testPorts.Count -lt 2) {
        Write-Host "ERROR: Could not open at least 2 ports for detection" -ForegroundColor Red
        foreach ($testPort in $testPorts) {
            if ($testPort.IsOpen) { $testPort.Close() }
        }
        exit 1
    }

    Write-Host ""
    Write-Host "STEP 1: Identify LEFT device" -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "HOLD a button on the LEFT device for 2+ seconds..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Waiting for long press (need 3 data bursts within 1 second of each other)..." -ForegroundColor Cyan

    # Wait for LEFT device button press with long-press detection
    $leftPort = $null
    $maxWaitTime = 60 # seconds
    $startTime = Get-Date
    $portDataCount = @{} # Track data count per port
    $portLastDataTime = @{} # Track last data time per port
    $consecutiveThreshold = 3 # Need 3 consecutive data receptions within 1 second each
    $resetTimeout = 1 # Reset counter if gap > 1 second

    # Initialize data count and time for all ports
    foreach ($testPort in $testPorts) {
        $portDataCount[$testPort.PortName] = 0
        $portLastDataTime[$testPort.PortName] = $null
    }

    while (($null -eq $leftPort) -and (((Get-Date) - $startTime).TotalSeconds -lt $maxWaitTime)) {
        foreach ($testPort in $testPorts) {
            if ($testPort.BytesToRead -gt 0) {
                $data = $testPort.ReadExisting()
                if ($data.Length -gt 10) {
                    $currentTime = Get-Date

                    # Check if data arrived within $resetTimeout seconds of previous data
                    if ($portLastDataTime[$testPort.PortName] -ne $null) {
                        $timeSinceLastData = ($currentTime - $portLastDataTime[$testPort.PortName]).TotalSeconds
                        if ($timeSinceLastData -gt $resetTimeout) {
                            # Too much time passed, reset counter
                            $portDataCount[$testPort.PortName] = 0
                            if ($DebugMode) {
                                Write-Host "DEBUG - Reset $($testPort.PortName) counter (gap: $timeSinceLastData seconds)" -ForegroundColor DarkGray
                            }
                        }
                    }

                    $portDataCount[$testPort.PortName]++
                    $portLastDataTime[$testPort.PortName] = $currentTime

                    # Check if this port has received data 3+ times within 1 second intervals
                    if ($portDataCount[$testPort.PortName] -ge $consecutiveThreshold) {
                        $leftPort = $testPort.PortName
                        Write-Host "LEFT device detected on: $leftPort" -ForegroundColor Green
                        if ($DebugMode) {
                            Write-Host "DEBUG - Port received data $($portDataCount[$testPort.PortName]) times consecutively" -ForegroundColor Cyan
                        }
                        break
                    }

                    if ($DebugMode) {
                        Write-Host "DEBUG - Data from $($testPort.PortName): $($data.Length) bytes (count: $($portDataCount[$testPort.PortName])/$consecutiveThreshold)" -ForegroundColor DarkGray
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }

    if ($null -eq $leftPort) {
        Write-Host "ERROR: No button press detected within 60 seconds" -ForegroundColor Red
        foreach ($testPort in $testPorts) {
            if ($testPort.IsOpen) { $testPort.Close() }
        }
        exit 1
    }

    Write-Host ""
    Write-Host "STEP 2: Identify RIGHT device" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "HOLD a button on the RIGHT device for 2+ seconds..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Waiting for long press (need 3 data bursts within 1 second of each other)..." -ForegroundColor Cyan

    # Wait for RIGHT device button press with long-press detection (excluding LEFT port)
    $rightPort = $null
    $maxWaitTime = 60 # seconds
    $startTime = Get-Date
    $portDataCount = @{} # Track data count per port
    $portLastDataTime = @{} # Track last data time per port
    $consecutiveThreshold = 3 # Need 3 consecutive data receptions within 1 second each
    $resetTimeout = 1 # Reset counter if gap > 1 second

    # Initialize data count and time for all ports except LEFT
    foreach ($testPort in $testPorts) {
        if ($testPort.PortName -ne $leftPort) {
            $portDataCount[$testPort.PortName] = 0
            $portLastDataTime[$testPort.PortName] = $null
        }
    }

    while (($null -eq $rightPort) -and (((Get-Date) - $startTime).TotalSeconds -lt $maxWaitTime)) {
        foreach ($testPort in $testPorts) {
            # Skip the LEFT port
            if ($testPort.PortName -eq $leftPort) { continue }

            if ($testPort.BytesToRead -gt 0) {
                $data = $testPort.ReadExisting()
                if ($data.Length -gt 10) {
                    $currentTime = Get-Date

                    # Check if data arrived within $resetTimeout seconds of previous data
                    if ($portLastDataTime[$testPort.PortName] -ne $null) {
                        $timeSinceLastData = ($currentTime - $portLastDataTime[$testPort.PortName]).TotalSeconds
                        if ($timeSinceLastData -gt $resetTimeout) {
                            # Too much time passed, reset counter
                            $portDataCount[$testPort.PortName] = 0
                            if ($DebugMode) {
                                Write-Host "DEBUG - Reset $($testPort.PortName) counter (gap: $timeSinceLastData seconds)" -ForegroundColor DarkGray
                            }
                        }
                    }

                    $portDataCount[$testPort.PortName]++
                    $portLastDataTime[$testPort.PortName] = $currentTime

                    # Check if this port has received data 3+ times within 1 second intervals
                    if ($portDataCount[$testPort.PortName] -ge $consecutiveThreshold) {
                        $rightPort = $testPort.PortName
                        Write-Host "RIGHT device detected on: $rightPort" -ForegroundColor Green
                        if ($DebugMode) {
                            Write-Host "DEBUG - Port received data $($portDataCount[$testPort.PortName]) times consecutively" -ForegroundColor Cyan
                        }
                        break
                    }

                    if ($DebugMode) {
                        Write-Host "DEBUG - Data from $($testPort.PortName): $($data.Length) bytes (count: $($portDataCount[$testPort.PortName])/$consecutiveThreshold)" -ForegroundColor DarkGray
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }

    if ($null -eq $rightPort) {
        Write-Host "ERROR: No button press detected within 30 seconds" -ForegroundColor Red
        foreach ($testPort in $testPorts) {
            if ($testPort.IsOpen) { $testPort.Close() }
        }
        exit 1
    }

    # Close all test ports
    foreach ($testPort in $testPorts) {
        if ($testPort.IsOpen) { $testPort.Close() }
    }

    Write-Host ""
    Write-Host "Configuration identified:" -ForegroundColor Cyan
    Write-Host "  LEFT device  : $leftPort" -ForegroundColor Green
    Write-Host "  RIGHT device : $rightPort" -ForegroundColor Green
    Write-Host ""
    Write-Host "Unused ports: $($($availablePorts | Where-Object { $_ -ne $leftPort -and $_ -ne $rightPort }) -join ', ')" -ForegroundColor Gray
    Write-Host ""
    Write-Host "If this is correct, press ENTER to continue..." -ForegroundColor Yellow
    Read-Host

    $ComPortA = $leftPort
    $ComPortB = $rightPort

}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    foreach ($testPort in $testPorts) {
        if ($testPort.IsOpen) { $testPort.Close() }
    }
    exit 1
}

# Now proceed with book selection
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  BOOK SELECTION" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "LEFT Device ($ComPortA):" -ForegroundColor Green
Write-Host "  What book will be opened on the LEFT device?" -ForegroundColor Yellow
Write-Host "  Options:" -ForegroundColor Cyan
Write-Host "    1. ORIGINAL" -ForegroundColor White
Write-Host "    2. OPTIMIZED" -ForegroundColor White
Write-Host "    3. Custom name" -ForegroundColor White

$choiceA = Read-Host "  Select (1-3)"

switch ($choiceA) {
    "1" { $bookA = "ORIGINAL" }
    "2" { $bookA = "OPTIMIZED" }
    "3" { $bookA = Read-Host "    Enter book name for LEFT device" }
    default {
        Write-Host "  Invalid choice, defaulting to UNKNOWN" -ForegroundColor Red
        $bookA = "UNKNOWN"
    }
}

Write-Host ""
Write-Host "RIGHT Device ($ComPortB):" -ForegroundColor Green
Write-Host "  What book will be opened on the RIGHT device?" -ForegroundColor Yellow
Write-Host "  Options:" -ForegroundColor Cyan
Write-Host "    1. ORIGINAL" -ForegroundColor White
Write-Host "    2. OPTIMIZED" -ForegroundColor White
Write-Host "    3. Custom name" -ForegroundColor White

$choiceB = Read-Host "  Select (1-3)"

switch ($choiceB) {
    "1" { $bookB = "ORIGINAL" }
    "2" { $bookB = "OPTIMIZED" }
    "3" { $bookB = Read-Host "    Enter book name for RIGHT device" }
    default {
        Write-Host "  Invalid choice, defaulting to UNKNOWN" -ForegroundColor Red
        $bookB = "UNKNOWN"
    }
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  LEFT Device  ($ComPortA): $bookA" -ForegroundColor Green
Write-Host "  RIGHT Device ($ComPortB): $bookB" -ForegroundColor Green
Write-Host ""

# Generate timestamp and create TEMP filenames
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$sanitizedBookA = $bookA -replace '[^\w\-]', '_'
$sanitizedBookB = $bookB -replace '[^\w\-]', '_'
# Capture with TEMP filenames, will be renamed at the end
$portShortA = $ComPortA -replace 'COM', ''
$portShortB = $ComPortB -replace 'COM', ''
$fileA = Join-Path $logsDir "COM${portShortA}_TEMP_${timestamp}.txt"
$fileB = Join-Path $logsDir "COM${portShortB}_TEMP_${timestamp}.txt"

Write-Host "Output files:" -ForegroundColor Green
Write-Host "  LEFT device: $fileA" -ForegroundColor Gray
Write-Host "  RIGHT device: $fileB" -ForegroundColor Gray
Write-Host ""
Write-Host "Press ENTER to start, Ctrl+C to stop" -ForegroundColor Yellow
Read-Host

Write-Host ""
Write-Host "Opening ports (devices will restart)..." -ForegroundColor Cyan

# Open ports
try {
    $portA = New-Object System.IO.Ports.SerialPort($ComPortA, 115200, "None", 8, "One")
    $portB = New-Object System.IO.Ports.SerialPort($ComPortB, 115200, "None", 8, "One")

    Write-Host "Opening $ComPortA..." -NoNewline
    $portA.Open()
    Write-Host " [OK]" -ForegroundColor Green

    Write-Host "Opening $ComPortB..." -NoNewline
    $portB.Open()
    Write-Host " [OK]" -ForegroundColor Green

    Write-Host ""
    Write-Host "Waiting for restart (3 seconds)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3

    Write-Host "Creating writers..." -ForegroundColor Cyan
    $writerA = New-Object System.IO.StreamWriter($fileA, $false, [System.Text.Encoding]::UTF8)
    $writerB = New-Object System.IO.StreamWriter($fileB, $false, [System.Text.Encoding]::UTF8)
    $writerA.AutoFlush = $true
    $writerB.AutoFlush = $true

    # Write metadata headers
    $metadataA = "CAPTURE_METADATA: Type=${sanitizedBookA}, Device=$ComPortA, Timestamp=${timestamp}"
    $metadataB = "CAPTURE_METADATA: Type=${sanitizedBookB}, Device=$ComPortB, Timestamp=${timestamp}"
    $writerA.WriteLine($metadataA)
    $writerB.WriteLine($metadataB)

    Write-Host "[OK] Capturing... Press Ctrl+C to stop" -ForegroundColor Green
    Write-Host ""

    $countA = 0
    $countB = 0
    $lastDot = Get-Date

    while ($true) {
        # Read from port A
        if ($portA.BytesToRead -gt 0) {
            $data = $portA.ReadExisting()
            $writerA.Write($data)
            $countA += $data.Length
        }

        # Read from port B
        if ($portB.BytesToRead -gt 0) {
            $data = $portB.ReadExisting()
            $writerB.Write($data)
            $countB += $data.Length
        }

        # Show progress every second
        if ((Get-Date) - $lastDot -gt [TimeSpan]::FromSeconds(1)) {
            Write-Host "`r[$countA bytes | $countB bytes] " -NoNewline -ForegroundColor Gray
            $lastDot = Get-Date
        }

        Start-Sleep -Milliseconds 50
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
}
finally {
    Write-Host ""
    Write-Host "Stopping..." -ForegroundColor Yellow

    if ($writerA) { $writerA.Close() }
    if ($writerB) { $writerB.Close() }
    if ($portA -and $portA.IsOpen) { $portA.Close() }
    if ($portB -and $portB.IsOpen) { $portB.Close() }

    Write-Host ""
    Write-Host "Files:" -ForegroundColor Cyan

    if (Test-Path $fileA) {
        $size = (Get-Item $fileA).Length
        Write-Host "  $fileA - $size bytes" -ForegroundColor Gray
    } else {
        Write-Host "  $fileA - NOT CREATED" -ForegroundColor Red
    }

    if (Test-Path $fileB) {
        $size = (Get-Item $fileB).Length
        Write-Host "  $fileB - $size bytes" -ForegroundColor Gray
    } else {
        Write-Host "  $fileB - NOT CREATED" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "Capture completed for: $bookA (LEFT) vs $bookB (RIGHT)" -ForegroundColor Green

    # Try to extract the real book names from logs and rename the files
    Write-Host ""
    Write-Host "Extracting book names from logs..." -ForegroundColor Yellow

    # Process Device A log
    try {
        if (Test-Path $fileA) {
            $logContentA = Get-Content $fileA -Raw

            # Pattern to match: [timestamp] [DBG] [EBP] Loading ePub: /FOLDER-XXXX/BOOKNAME.epub
            # Updated pattern to handle spaces and special characters in filename
            $pattern = '\[\d+\]\s+\[DBG\]\s+\[EBP\]\s+Loading\s+ePub:\s+[^\s]+/(.+\.epub)'
            $matchA = [regex]::Match($logContentA, $pattern)

            if ($matchA.Success) {
                $epubFileNameA = $matchA.Groups[1].Value.Trim()
                # Use the full epub filename (e.g., LIBRO.EPUB)
                $sanitizedEpubNameA = $epubFileNameA -replace '[^\w\-\.]', '_'

                # Generate new filename: COM3_ORIGINAL_LIBRO.EPUB_20250313_123456.txt
                $portShortA = $ComPortA -replace 'COM', ''
                $newFileA = Join-Path $logsDir "COM${portShortA}_${sanitizedBookA}_${sanitizedEpubNameA}_${timestamp}.txt"

                # Rename the file
                Move-Item -Path $fileA -Destination $newFileA -Force
                Write-Host "  LEFT device ($ComPortA): COM${portShortA}_${sanitizedBookA}_${sanitizedEpubNameA}_${timestamp}.txt" -ForegroundColor Green
                $finalFileA = $newFileA
            } else {
                Write-Host "  WARNING: Could not extract book name for LEFT device" -ForegroundColor Yellow
                Write-Host "  Keeping TEMP filename: $fileA" -ForegroundColor Yellow
                $finalFileA = $fileA
            }
        }
    }
    catch {
        Write-Host "  ERROR: Could not rename LEFT device file - $($_.Exception.Message)" -ForegroundColor Yellow
        $finalFileA = $fileA
    }

    # Process RIGHT device log
    try {
        if (Test-Path $fileB) {
            $logContentB = Get-Content $fileB -Raw

            # Pattern to match: [timestamp] [DBG] [EBP] Loading ePub: /FOLDER-XXXX/BOOKNAME.epub
            # Updated pattern to handle spaces and special characters in filename
            $pattern = '\[\d+\]\s+\[DBG\]\s+\[EBP\]\s+Loading\s+ePub:\s+[^\s]+/(.+\.epub)'
            $matchB = [regex]::Match($logContentB, $pattern)

            if ($matchB.Success) {
                $epubFileNameB = $matchB.Groups[1].Value.Trim()
                # Use the full epub filename (e.g., LIBRO.EPUB)
                $sanitizedEpubNameB = $epubFileNameB -replace '[^\w\-\.]', '_'

                # Generate new filename: COM4_OPTIMIZED_LIBRO.EPUB_20250313_123456.txt
                $portShortB = $ComPortB -replace 'COM', ''
                $newFileB = Join-Path $logsDir "COM${portShortB}_${sanitizedBookB}_${sanitizedEpubNameB}_${timestamp}.txt"

                # Rename the file
                Move-Item -Path $fileB -Destination $newFileB -Force
                Write-Host "  RIGHT device ($ComPortB): COM${portShortB}_${sanitizedBookB}_${sanitizedEpubNameB}_${timestamp}.txt" -ForegroundColor Green
                $finalFileB = $newFileB
            } else {
                Write-Host "  WARNING: Could not extract book name for RIGHT device" -ForegroundColor Yellow
                Write-Host "  Keeping TEMP filename: $fileB" -ForegroundColor Yellow
                $finalFileB = $fileB
            }
        }
    }
    catch {
        Write-Host "  ERROR: Could not rename RIGHT device file - $($_.Exception.Message)" -ForegroundColor Yellow
        $finalFileB = $fileB
    }

    Write-Host ""
    Write-Host "Final log files:" -ForegroundColor Cyan
    Write-Host "  LEFT device  ($ComPortA): $finalFileA" -ForegroundColor Gray
    Write-Host "  RIGHT device ($ComPortB): $finalFileB" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Next: Run .\Analyze-Logs-Smart.ps1 to analyze the results" -ForegroundColor Yellow
    Write-Host ""
}
