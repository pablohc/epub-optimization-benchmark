# EPUB-Optimization-Benchmark.ps1
# Integrated toolkit for EPUB Optimization testing
# Menu-driven interface for capture and analysis

param(
    [switch]$DebugMode,
    [switch]$SkipReset
)

# Create logs directory
$logsDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}

# Initialize global capture success flag
$global:CaptureSuccess = $false

# ============================================================
# MENU FUNCTIONS
# ============================================================

function Show-MainMenu {
    Clear-Host
    Write-Host ""
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  EPUB OPTIMIZATION BENCHMARK" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Select an option:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [1] Capture - Single Device" -ForegroundColor White
    Write-Host "  [2] Capture - Dual Devices" -ForegroundColor White
    Write-Host "  [3] Analyze Logs" -ForegroundColor White
    Write-Host ""
    Write-Host "  [0] Exit" -ForegroundColor Gray
    Write-Host ""
}

function Show-CaptureCompleteMenu {
    Write-Host ""
    Write-Host "What would you like to do next?" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [0] Capture another book" -ForegroundColor Green
    Write-Host "  [1] Analyze captured logs" -ForegroundColor White
    Write-Host "  [2] Return to main menu" -ForegroundColor White
    Write-Host "  [3] Exit" -ForegroundColor Gray
    Write-Host ""
}

function Show-UnfairComparisonWarning {
    Write-Host ""
    Write-Host "  WARNING: Pages marked with [!] have differences that make comparisons unfair" -ForegroundColor Yellow
    Write-Host "    Faster times may be due to missing images or failed cover generation," -ForegroundColor Yellow
    Write-Host "    not real performance improvements" -ForegroundColor Yellow
}

# ============================================================
# SINGLE DEVICE CAPTURE
# ============================================================

function Start-SingleDeviceCapture {
    Clear-Host
    Write-Host ""
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  SINGLE DEVICE CAPTURE - Port Detection" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Detecting available COM ports..." -ForegroundColor Cyan

    # Get port names and sort them
    $rawPorts = [System.IO.Ports.SerialPort]::GetPortNames()
    $availablePorts = @($rawPorts)
    $availablePorts = [string[]]($availablePorts | Sort-Object)

    if ($availablePorts.Count -eq 0) {
        Write-Host "ERROR: No COM ports detected" -ForegroundColor Red
        Write-Host "Please connect a device and try again" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host
        $global:CaptureSuccess = $false
        return
    }

    Write-Host "Found $($availablePorts.Count) COM port(s)" -ForegroundColor Green
    Write-Host ""

    # Display ports with numbers
    Write-Host "Available COM ports:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $availablePorts.Count; $i++) {
        $port = $availablePorts[$i]
        $num = $i + 1
        Write-Host ("  [{0}] {1}" -f $num, $port) -ForegroundColor White
    }
    Write-Host ""

    # Select port
    if ($availablePorts.Count -eq 1) {
        $ComPort = $availablePorts[0]
        Write-Host ("Auto-selected: {0} (only port available)" -f $ComPort) -ForegroundColor Green
        Write-Host ""
    } else {
        $maxSelect = $availablePorts.Count
        $selection = 0
        while ($selection -lt 1 -or $selection -gt $maxSelect) {
            $selection = Read-Host "Select port (1-$maxSelect)"
            if ($selection -notmatch '^\d+$') { $selection = 0 }
        }
        $ComPort = $availablePorts[$selection - 1]
        Write-Host ("Selected: {0}" -f $ComPort) -ForegroundColor Green
        Write-Host ""
    }

    # Book selection
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  BOOK SELECTION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("Device: {0}" -f $ComPort) -ForegroundColor Green
    Write-Host "What book will be opened on this device?" -ForegroundColor Yellow
    Write-Host "Options:" -ForegroundColor Cyan
    Write-Host "  1. ORIGINAL" -ForegroundColor White
    Write-Host "  2. OPTIMIZED" -ForegroundColor White
    Write-Host "  3. Custom name" -ForegroundColor White

    $choice = Read-Host "Select (1-3)"

    switch ($choice) {
        "1" { $book = "ORIGINAL" }
        "2" { $book = "OPTIMIZED" }
        "3" { $book = Read-Host "  Enter book name" }
        default {
            Write-Host "Invalid choice, defaulting to UNKNOWN" -ForegroundColor Red
            $book = "UNKNOWN"
        }
    }

    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor Cyan
    Write-Host ("  Device: {0}" -f $ComPort) -ForegroundColor Green
    Write-Host "  Book: $book" -ForegroundColor Green
    Write-Host ""

    # Generate timestamp and create TEMP filename
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $sanitizedBook = $book -replace '[^\w\-]', '_'
    $portShort = $ComPort -replace 'COM', ''
    $fileName = Join-Path $logsDir "COM${portShort}_TEMP_${timestamp}.txt"

    Write-Host "Output file:" -ForegroundColor Green
    Write-Host "  $fileName" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Press ENTER to start, ESC or Q to stop" -ForegroundColor Yellow
    Read-Host

    Clear-Host
    Write-Host ""
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CAPTURE IN PROGRESS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Opening port (device will restart)..." -ForegroundColor Cyan

    # Open port and capture
    $captureSuccess = $false
    try {
        $port = New-Object System.IO.Ports.SerialPort($ComPort, 115200, "None", 8, "One")

        Write-Host ("Opening {0}..." -f $ComPort) -NoNewline
        $port.Open()
        Write-Host " [OK]" -ForegroundColor Green

        Write-Host ""
        Write-Host "Waiting for restart (3 seconds)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3

        Write-Host "Creating writer..." -ForegroundColor Cyan
        $writer = New-Object System.IO.StreamWriter($fileName, $false, [System.Text.Encoding]::UTF8)
        $writer.AutoFlush = $true

        Write-Host "[OK] Capturing... Press ESC or Q to stop" -ForegroundColor Green
        Write-Host ""

        # Firmware detection variables
        $initialBuffer = New-Object System.Text.StringBuilder
        $firmwareVersion = "Unknown"
        $firmwareBranch = "Unknown"
        $firmwareDetected = $false
        $maxFirmwareWait = 10  # Wait up to 10 seconds for firmware info
        $firmwareSearchStartTime = Get-Date

        $count = 0
        $pagesDetected = 0
        $coverStatus = $null
        $lastDot = Get-Date
        $stopRequested = $false
        $metadataWritten = $false

        while (-not $stopRequested) {
            # Check for key press to stop capture
            if ($Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey("AllowCtrlC,IncludeKeyDown,NoEcho")
                if ($key.VirtualKeyCode -eq 27 -or $key.Character -eq 'q' -or $key.Character -eq 'Q') {
                    $stopRequested = $true
                    break
                }
            }

            if ($port.BytesToRead -gt 0) {
                $data = $port.ReadExisting()

                # Buffer initial data for firmware detection (before writing to file)
                if (-not $metadataWritten) {
                    $initialBuffer.Append($data) | Out-Null

                    # Try to detect firmware version in incoming data
                    if (-not $firmwareDetected) {
                        $newLines = $data -split "`r?`n"
                        foreach ($line in $newLines) {
                            if ($line -match "\[DBG\]\s+\[MAIN\]\s+Starting\s+CrossPoint\s+version\s+([\d\.]+(?:-[a-z]+)?)(?:\+([^ \t]+))?") {
                                $firmwareVersion = $matches[1]
                                if ($matches[2]) {
                                    $firmwareBranch = $matches[2]
                                } else {
                                    $firmwareBranch = "master"
                                }
                                $firmwareDetected = $true
                                Write-Host ""
                                Write-Host "Detected Firmware: $firmwareVersion (branch: $firmwareBranch)" -ForegroundColor Cyan
                                break
                            }
                        }
                    }

                    # Check if we should write metadata now (firmware detected or timeout)
                    $timeSinceStart = (Get-Date) - $firmwareSearchStartTime
                    if ($firmwareDetected -or $timeSinceStart.TotalSeconds -gt $maxFirmwareWait) {
                        # Write metadata header with firmware info
                        $metadata = "CAPTURE_METADATA: Type=${sanitizedBook}, Device=$ComPort, Timestamp=${timestamp}, Firmware=${firmwareVersion}, Branch=${firmwareBranch}"
                        $writer.WriteLine($metadata)

                        # Write buffered data
                        $writer.Write($initialBuffer.ToString())
                        $metadataWritten = $true

                        if (-not $firmwareDetected) {
                            Write-Host ""
                            Write-Host "Firmware detection timeout - using 'Unknown'" -ForegroundColor Yellow
                        }
                    }
                } else {
                    # Normal mode: write directly to file
                    $writer.Write($data)
                }

                $count += $data.Length

                # Count pages rendered using the same logic as the analyzer
                $newLines = $data -split "`r?`n"
                foreach ($line in $newLines) {
                    if ($line -match "Rendered page in (\d+)ms") {
                        $pagesDetected++
                    }
                    # Detect cover generation status using same patterns as analyzer
                    if ($line -match "\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+yes") {
                        $coverStatus = "SUCCESS"
                    } elseif ($line -match "\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+no") {
                        $coverStatus = "FAILED"
                    }
                }
            }

            if ((Get-Date) - $lastDot -gt [TimeSpan]::FromSeconds(1)) {
                $coverInfo = if ($coverStatus) { " | cover: $coverStatus" } else { "" }
                Write-Host "`r[$count bytes | $pagesDetected pages$coverInfo] " -NoNewline -ForegroundColor Gray
                $lastDot = Get-Date
            }

            Start-Sleep -Milliseconds 50
        }
    } catch {
        Write-Host ""
        # Exception occurred, check if file was created
        $captureSuccess = $false
    }
    finally {
        Write-Host ""
        Write-Host "Stopping..." -ForegroundColor Yellow

        if ($writer) { $writer.Close() }
        if ($port -and $port.IsOpen) { $port.Close() }

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  CAPTURE COMPLETED" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Temp File:" -ForegroundColor Cyan

        if (Test-Path $fileName) {
            $size = (Get-Item $fileName).Length
            Write-Host "  $fileName - $size bytes" -ForegroundColor Gray
            # Mark as success if file exists and has content
            if ($size -gt 0) {
                $captureSuccess = $true
            }
        } else {
            Write-Host "  $fileName - NOT CREATED" -ForegroundColor Red
        }

        Write-Host ""
        Write-Host ("Capture completed for: {0} on {1}" -f $book, $ComPort) -ForegroundColor Green

        # Extract book name and rename
        Write-Host ""
        Write-Host "Extracting book name from log..." -ForegroundColor Yellow

        try {
            if (Test-Path $fileName) {
                $logContent = Get-Content $fileName -Raw
                $pattern = '\[\d+\]\s+\[DBG\]\s+\[EBP\]\s+Loading\s+ePub:\s+[^\r\n]+?/([^/\r\n]+\.epub)'
                $match = [regex]::Match($logContent, $pattern)

                if ($match.Success) {
                    $epubFileName = $match.Groups[1].Value.Trim()
                    $sanitizedEpubName = $epubFileName -replace '[^\w\-\.]', '_'
                    $newFileName = Join-Path $logsDir "COM${portShort}_${sanitizedBook}_${sanitizedEpubName}_${timestamp}.txt"
                    Move-Item -Path $fileName -Destination $newFileName -Force
                    Write-Host "  Renamed to: COM${portShort}_${sanitizedBook}_${sanitizedEpubName}_${timestamp}.txt" -ForegroundColor Green
                    $finalFileName = $newFileName
                } else {
                    Write-Host "  WARNING: Could not extract book name" -ForegroundColor Yellow
                    $finalFileName = $fileName
                }
            }
        }
        catch {
            Write-Host "  ERROR: Could not rename file" -ForegroundColor Yellow
            $finalFileName = $fileName
        }

        Write-Host ""
        Write-Host "Final log file: $finalFileName" -ForegroundColor Cyan
        Write-Host ""


        $captureSuccess = $true
    }

    $global:CaptureSuccess = $captureSuccess
    return
}

# ============================================================
# DUAL DEVICE CAPTURE
# ============================================================

function Start-DualDeviceCapture {
    # Initialize return value
    $script:captureResult = $false

    Clear-Host
    Write-Host ""
    Write-Host ""
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
    Write-Host "Please connect both devices to different COM ports." -ForegroundColor Yellow
    Write-Host ""

    # Get available COM ports
    Write-Host "Detecting available COM ports..." -ForegroundColor Cyan
    $rawPorts = [System.IO.Ports.SerialPort]::GetPortNames()

    # Ensure we always have an array, never $null
    $availablePorts = @($rawPorts | Sort-Object | Select-Object -Unique)
    if ($null -eq $availablePorts) {
        $availablePorts = @()
    }


    if ($availablePorts.Count -lt 2) {
        Write-Host "ERROR: Less than 2 COM ports detected" -ForegroundColor Red
        Write-Host "Available ports: $($availablePorts -join ', ')" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host

        $global:CaptureSuccess = $false
        $null
        return
    }

    Write-Host "Found $($availablePorts.Count) COM port(s)" -ForegroundColor Green
    Write-Host ""

    # Display ports with numbers
    Write-Host "Available COM ports:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $availablePorts.Count; $i++) {
        Write-Host "  [$($i+1)] $($availablePorts[$i])" -ForegroundColor White
    }
    Write-Host ""

    # Automatic device detection
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  AUTOMATIC DEVICE DETECTION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    try {
        # Reset devices if not skipped
        if (-not $SkipReset) {
            Write-Host "Resetting all connected devices..." -ForegroundColor Cyan
            foreach ($portName in $availablePorts) {
                try {
                    $tempPort = New-Object System.IO.Ports.SerialPort($portName, 115200, "None", 8, "One")
                    $tempPort.Open()
                    $tempPort.DtrEnable = $true
                    Start-Sleep -Milliseconds 100
                    $tempPort.DtrEnable = $false
                    Start-Sleep -Milliseconds 500
                    $tempPort.Close()
                    Write-Host "  Reset sent to $portName" -ForegroundColor Gray
                }
                catch {
                    Write-Host "  WARNING: Could not reset $portName" -ForegroundColor Yellow
                }
            }

            Write-Host ""
            Write-Host "Waiting for devices to restart..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }

        # Open all ports to monitor
        $testPorts = @()
        $portMap = @{}

        Write-Host "Opening all COM ports to monitor for button presses..." -ForegroundColor Cyan
        foreach ($portName in $availablePorts) {
            try {
                $testPort = New-Object System.IO.Ports.SerialPort($portName, 115200, "None", 8, "One")
                $testPort.Open()
                $testPorts += $testPort
                $portMap[$portName] = $testPort
                Write-Host "  Opened $portName" -ForegroundColor Gray
                Start-Sleep -Milliseconds 500
                $testPort.ReadExisting() | Out-Null
            }
            catch {
                Write-Host "  WARNING: Could not open $portName" -ForegroundColor Yellow
            }
        }

        if ($testPorts.Count -lt 2) {
            Write-Host "ERROR: Could not open at least 2 ports" -ForegroundColor Red
            Write-Host ""
            Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
            Read-Host
            foreach ($testPort in $testPorts) {
                if ($testPort.IsOpen) { $testPort.Close() }
            }
            return $false
        }

        # Detect LEFT device
        Write-Host ""
        Write-Host "STEP 1: Identify LEFT device" -ForegroundColor Cyan
        Write-Host "==============================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "HOLD a button on the LEFT device for 2+ seconds..." -ForegroundColor Yellow
        Write-Host ""

        $leftPort = $null
        $maxWaitTime = 60
        $startTime = Get-Date
        $portDataCount = @{}
        $portLastDataTime = @{}
        $consecutiveThreshold = 3
        $resetTimeout = 1

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

                        if ($portLastDataTime[$testPort.PortName] -ne $null) {
                            $timeSinceLastData = ($currentTime - $portLastDataTime[$testPort.PortName]).TotalSeconds
                            if ($timeSinceLastData -gt $resetTimeout) {
                                $portDataCount[$testPort.PortName] = 0
                            }
                        }

                        $portDataCount[$testPort.PortName]++
                        $portLastDataTime[$testPort.PortName] = $currentTime

                        if ($portDataCount[$testPort.PortName] -ge $consecutiveThreshold) {
                            $leftPort = $testPort.PortName
                            Write-Host "LEFT device detected on: $leftPort" -ForegroundColor Green
                            break
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
            Write-Host ""
            Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
            Read-Host
            return $false
        }

        # Detect RIGHT device
        Write-Host ""
        Write-Host "STEP 2: Identify RIGHT device" -ForegroundColor Cyan
        Write-Host "===============================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "HOLD a button on the RIGHT device for 2+ seconds..." -ForegroundColor Yellow
        Write-Host ""

        $rightPort = $null
        $startTime = Get-Date
        foreach ($testPort in $testPorts) {
            if ($testPort.PortName -ne $leftPort) {
                $portDataCount[$testPort.PortName] = 0
                $portLastDataTime[$testPort.PortName] = $null
            }
        }

        while (($null -eq $rightPort) -and (((Get-Date) - $startTime).TotalSeconds -lt $maxWaitTime)) {
            foreach ($testPort in $testPorts) {
                if ($testPort.PortName -eq $leftPort) { continue }

                if ($testPort.BytesToRead -gt 0) {
                    $data = $testPort.ReadExisting()
                    if ($data.Length -gt 10) {
                        $currentTime = Get-Date

                        if ($portLastDataTime[$testPort.PortName] -ne $null) {
                            $timeSinceLastData = ($currentTime - $portLastDataTime[$testPort.PortName]).TotalSeconds
                            if ($timeSinceLastData -gt $resetTimeout) {
                                $portDataCount[$testPort.PortName] = 0
                            }
                        }

                        $portDataCount[$testPort.PortName]++
                        $portLastDataTime[$testPort.PortName] = $currentTime

                        if ($portDataCount[$testPort.PortName] -ge $consecutiveThreshold) {
                            $rightPort = $testPort.PortName
                            Write-Host "RIGHT device detected on: $rightPort" -ForegroundColor Green
                            break
                        }
                    }
                }
            }
            Start-Sleep -Milliseconds 200
        }

        # Close test ports
        foreach ($testPort in $testPorts) {
            if ($testPort.IsOpen) { $testPort.Close() }
        }

        if ($null -eq $rightPort) {
            Write-Host "ERROR: No button press detected for RIGHT device" -ForegroundColor Red
            Write-Host ""
            Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
            Read-Host
            return $false
        }

        Write-Host ""
        Write-Host "Configuration identified:" -ForegroundColor Cyan
        Write-Host "  LEFT device  : $leftPort" -ForegroundColor Green
        Write-Host "  RIGHT device : $rightPort" -ForegroundColor Green
        Write-Host ""
        Write-Host "If this is correct, press ENTER to continue..." -ForegroundColor Yellow
        Read-Host

        # Book selection
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  BOOK SELECTION" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "LEFT Device ($leftPort):" -ForegroundColor Green
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
            default { $bookA = "UNKNOWN" }
        }

        Write-Host ""
        Write-Host "RIGHT Device ($rightPort):" -ForegroundColor Green
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
            default { $bookB = "UNKNOWN" }
        }

        Write-Host ""
        Write-Host "Configuration:" -ForegroundColor Cyan
        Write-Host "  LEFT Device  ($leftPort): $bookA" -ForegroundColor Green
        Write-Host "  RIGHT Device ($rightPort): $bookB" -ForegroundColor Green
        Write-Host ""

        # Start capture
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $sanitizedBookA = $bookA -replace '[^\w\-]', '_'
        $sanitizedBookB = $bookB -replace '[^\w\-]', '_'
        $portShortA = $leftPort -replace 'COM', ''
        $portShortB = $rightPort -replace 'COM', ''
        $fileA = Join-Path $logsDir "COM${portShortA}_TEMP_${timestamp}.txt"
        $fileB = Join-Path $logsDir "COM${portShortB}_TEMP_${timestamp}.txt"

        Write-Host "Output files:" -ForegroundColor Green
        Write-Host "  LEFT device: $fileA" -ForegroundColor Gray
        Write-Host "  RIGHT device: $fileB" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Press ENTER to start, ESC or Q to stop" -ForegroundColor Yellow
        Read-Host

        Clear-Host
        Write-Host ""
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  CAPTURE IN PROGRESS" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Opening ports (devices will restart)..." -ForegroundColor Cyan

        $captureSuccess = $false
        try {
            $portA = New-Object System.IO.Ports.SerialPort($leftPort, 115200, "None", 8, "One")
            $portB = New-Object System.IO.Ports.SerialPort($rightPort, 115200, "None", 8, "One")

            Write-Host "Opening $leftPort..." -NoNewline
            $portA.Open()
            Write-Host " [OK]" -ForegroundColor Green

            Write-Host "Opening $rightPort..." -NoNewline
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

            Write-Host "[OK] Capturing... Press ESC or Q to stop" -ForegroundColor Green
            Write-Host ""

            # Firmware detection variables for dual capture
            $initialBufferA = New-Object System.Text.StringBuilder
            $initialBufferB = New-Object System.Text.StringBuilder
            $firmwareVersionA = "Unknown"
            $firmwareBranchA = "Unknown"
            $firmwareVersionB = "Unknown"
            $firmwareBranchB = "Unknown"
            $firmwareDetectedA = $false
            $firmwareDetectedB = $false
            $maxFirmwareWait = 10
            $firmwareSearchStartTime = Get-Date

            $countA = 0
            $countB = 0
            $pagesDetectedA = 0
            $pagesDetectedB = 0
            $coverStatusA = $null
            $coverStatusB = $null
            $lastDot = Get-Date
            $stopRequested = $false
            $metadataWrittenA = $false
            $metadataWrittenB = $false

            while (-not $stopRequested) {
                # Check for key press to stop capture
                if ($Host.UI.RawUI.KeyAvailable) {
                    $key = $Host.UI.RawUI.ReadKey("AllowCtrlC,IncludeKeyDown,NoEcho")
                    if ($key.VirtualKeyCode -eq 27 -or $key.Character -eq 'q' -or $key.Character -eq 'Q') {
                        $stopRequested = $true
                        break
                    }
                }

                if ($portA.BytesToRead -gt 0) {
                    $data = $portA.ReadExisting()

                    # Buffer initial data for firmware detection (before writing to file)
                    if (-not $metadataWrittenA) {
                        $initialBufferA.Append($data) | Out-Null

                        # Try to detect firmware version in incoming data
                        if (-not $firmwareDetectedA) {
                            $newLines = $data -split "`r?`n"
                            foreach ($line in $newLines) {
                                if ($line -match "\[DBG\]\s+\[MAIN\]\s+Starting\s+CrossPoint\s+version\s+([\d\.]+(?:-[a-z]+)?)(?:\+([^ \t]+))?") {
                                    $firmwareVersionA = $matches[1]
                                    if ($matches[2]) {
                                        $firmwareBranchA = $matches[2]
                                    } else {
                                        $firmwareBranchA = "master"
                                    }
                                    $firmwareDetectedA = $true
                                    Write-Host ""
                                    Write-Host "LEFT Device Detected Firmware: $firmwareVersionA (branch: $firmwareBranchA)" -ForegroundColor Cyan
                                    break
                                }
                            }
                        }

                        # Check if we should write metadata now (firmware detected or timeout)
                        $timeSinceStart = (Get-Date) - $firmwareSearchStartTime
                        if ($firmwareDetectedA -or $timeSinceStart.TotalSeconds -gt $maxFirmwareWait) {
                            # Write metadata header with firmware info
                            $metadataA = "CAPTURE_METADATA: Type=${sanitizedBookA}, Device=$leftPort, Timestamp=${timestamp}, Firmware=${firmwareVersionA}, Branch=${firmwareBranchA}"
                            $writerA.WriteLine($metadataA)

                            # Write buffered data
                            $writerA.Write($initialBufferA.ToString())
                            $metadataWrittenA = $true

                            if (-not $firmwareDetectedA) {
                                Write-Host ""
                                Write-Host "LEFT Device Firmware detection timeout - using 'Unknown'" -ForegroundColor Yellow
                            }
                        }
                    } else {
                        # Normal mode: write directly to file
                        $writerA.Write($data)
                    }

                    $countA += $data.Length

                    # Count pages rendered using the same logic as the analyzer
                    $newLines = $data -split "`r?`n"
                    foreach ($line in $newLines) {
                        if ($line -match "Rendered page in (\d+)ms") {
                            $pagesDetectedA++
                        }
                        # Detect cover generation status
                        if ($line -match "\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+yes") {
                            $coverStatusA = "SUCCESS"
                        } elseif ($line -match "\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+no") {
                            $coverStatusA = "FAILED"
                        }
                    }
                }

                if ($portB.BytesToRead -gt 0) {
                    $data = $portB.ReadExisting()

                    # Buffer initial data for firmware detection (before writing to file)
                    if (-not $metadataWrittenB) {
                        $initialBufferB.Append($data) | Out-Null

                        # Try to detect firmware version in incoming data
                        if (-not $firmwareDetectedB) {
                            $newLines = $data -split "`r?`n"
                            foreach ($line in $newLines) {
                                if ($line -match "\[DBG\]\s+\[MAIN\]\s+Starting\s+CrossPoint\s+version\s+([\d\.]+(?:-[a-z]+)?)(?:\+([^ \t]+))?") {
                                    $firmwareVersionB = $matches[1]
                                    if ($matches[2]) {
                                        $firmwareBranchB = $matches[2]
                                    } else {
                                        $firmwareBranchB = "master"
                                    }
                                    $firmwareDetectedB = $true
                                    Write-Host ""
                                    Write-Host "RIGHT Device Detected Firmware: $firmwareVersionB (branch: $firmwareBranchB)" -ForegroundColor Cyan
                                    break
                                }
                            }
                        }

                        # Check if we should write metadata now (firmware detected or timeout)
                        $timeSinceStart = (Get-Date) - $firmwareSearchStartTime
                        if ($firmwareDetectedB -or $timeSinceStart.TotalSeconds -gt $maxFirmwareWait) {
                            # Write metadata header with firmware info
                            $metadataB = "CAPTURE_METADATA: Type=${sanitizedBookB}, Device=$rightPort, Timestamp=${timestamp}, Firmware=${firmwareVersionB}, Branch=${firmwareBranchB}"
                            $writerB.WriteLine($metadataB)

                            # Write buffered data
                            $writerB.Write($initialBufferB.ToString())
                            $metadataWrittenB = $true

                            if (-not $firmwareDetectedB) {
                                Write-Host ""
                                Write-Host "RIGHT Device Firmware detection timeout - using 'Unknown'" -ForegroundColor Yellow
                            }
                        }
                    } else {
                        # Normal mode: write directly to file
                        $writerB.Write($data)
                    }

                    $countB += $data.Length

                    # Count pages rendered using the same logic as the analyzer
                    $newLines = $data -split "`r?`n"
                    foreach ($line in $newLines) {
                        if ($line -match "Rendered page in (\d+)ms") {
                            $pagesDetectedB++
                        }
                        # Detect cover generation status
                        if ($line -match "\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+yes") {
                            $coverStatusB = "SUCCESS"
                        } elseif ($line -match "\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+no") {
                            $coverStatusB = "FAILED"
                        }
                    }
                }

                if ((Get-Date) - $lastDot -gt [TimeSpan]::FromSeconds(1)) {
                    $coverInfoA = if ($coverStatusA) { " | cover: $coverStatusA" } else { "" }
                    $coverInfoB = if ($coverStatusB) { " | cover: $coverStatusB" } else { "" }
                    Write-Host "`r[$countA bytes | $countB bytes] [$pagesDetectedA pages$coverInfoA | $pagesDetectedB pages$coverInfoB] " -NoNewline -ForegroundColor Gray
                    $lastDot = Get-Date
                }

                Start-Sleep -Milliseconds 50
            }
        } catch {
            Write-Host ""
            # Exception occurred, check if files were created
        }
        finally {
            Write-Host ""
            Write-Host "Stopping..." -ForegroundColor Yellow

            if ($writerA) { $writerA.Close() }
            if ($writerB) { $writerB.Close() }
            if ($portA -and $portA.IsOpen) { $portA.Close() }
            if ($portB -and $portB.IsOpen) { $portB.Close() }

            Write-Host ""
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "  CAPTURE COMPLETED" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Temp Files:" -ForegroundColor Cyan

            $fileAExists = $false
            $fileBExists = $false

            if (Test-Path $fileA) {
                $size = (Get-Item $fileA).Length
                Write-Host "  $fileA - $size bytes" -ForegroundColor Gray
                if ($size -gt 0) { $fileAExists = $true }
            } else {
                Write-Host "  $fileA - NOT CREATED" -ForegroundColor Red
            }

            if (Test-Path $fileB) {
                $size = (Get-Item $fileB).Length
                Write-Host "  $fileB - $size bytes" -ForegroundColor Gray
                if ($size -gt 0) { $fileBExists = $true }
            } else {
                Write-Host "  $fileB - NOT CREATED" -ForegroundColor Red
            }

            # Mark as success if at least one file was created with content
            if ($fileAExists -or $fileBExists) {
                $captureSuccess = $true
            }

            if ($captureSuccess) {
                Write-Host ""
                Write-Host "Capture completed for: $bookA (LEFT) vs $bookB (RIGHT)" -ForegroundColor Green

                # Rename files with extracted book names
                Write-Host ""
                Write-Host "Extracting book names from logs..." -ForegroundColor Yellow

                try {
                    if (Test-Path $fileA) {
                        $logContentA = Get-Content $fileA -Raw
                        $pattern = '\[\d+\]\s+\[DBG\]\s+\[EBP\]\s+Loading\s+ePub:\s+[^\r\n]+?/([^/\r\n]+\.epub)'
                        $matchA = [regex]::Match($logContentA, $pattern)

                        if ($matchA.Success) {
                            $epubFileNameA = $matchA.Groups[1].Value.Trim()
                            $sanitizedEpubNameA = $epubFileNameA -replace '[^\w\-\.]', '_'
                            $newFileA = Join-Path $logsDir "COM${portShortA}_${sanitizedBookA}_${sanitizedEpubNameA}_${timestamp}.txt"
                            Move-Item -Path $fileA -Destination $newFileA -Force
                            Write-Host "  LEFT device ($leftPort): COM${portShortA}_${sanitizedBookA}_${sanitizedEpubNameA}_${timestamp}.txt" -ForegroundColor Green
                            $finalFileA = $newFileA
                        } else {
                            Write-Host "  WARNING: Could not extract book name for LEFT device" -ForegroundColor Yellow
                            $finalFileA = $fileA
                        }
                    }
                }
                catch {
                    Write-Host "  ERROR: Could not rename LEFT device file" -ForegroundColor Yellow
                    $finalFileA = $fileA
                }

                try {
                    if (Test-Path $fileB) {
                        $logContentB = Get-Content $fileB -Raw
                        $pattern = '\[\d+\]\s+\[DBG\]\s+\[EBP\]\s+Loading\s+ePub:\s+[^\r\n]+?/([^/\r\n]+\.epub)'
                        $matchB = [regex]::Match($logContentB, $pattern)

                        if ($matchB.Success) {
                            $epubFileNameB = $matchB.Groups[1].Value.Trim()
                            $sanitizedEpubNameB = $epubFileNameB -replace '[^\w\-\.]', '_'
                            $newFileB = Join-Path $logsDir "COM${portShortB}_${sanitizedBookB}_${sanitizedEpubNameB}_${timestamp}.txt"
                            Move-Item -Path $fileB -Destination $newFileB -Force
                            Write-Host "  RIGHT device ($rightPort): COM${portShortB}_${sanitizedBookB}_${sanitizedEpubNameB}_${timestamp}.txt" -ForegroundColor Green
                            $finalFileB = $newFileB
                        } else {
                            Write-Host "  WARNING: Could not extract book name for RIGHT device" -ForegroundColor Yellow
                            $finalFileB = $fileB
                        }
                    }
                }
                catch {
                    Write-Host "  ERROR: Could not rename RIGHT device file" -ForegroundColor Yellow
                    $finalFileB = $fileB
                }

                Write-Host ""
                Write-Host "Final log files:" -ForegroundColor Cyan
                Write-Host "  LEFT device  ($leftPort): $finalFileA" -ForegroundColor Gray
                Write-Host "  RIGHT device ($rightPort): $finalFileB" -ForegroundColor Gray
                Write-Host ""
                Write-Host ""
                Write-Host ""
            }
        }
    } catch {
        Write-Host ""
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        foreach ($testPort in $testPorts) {
            if ($testPort.IsOpen) { $testPort.Close() }
        }
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host

        $captureSuccess = $false
    }

    $global:CaptureSuccess = $captureSuccess
    return
}

# ============================================================
# ANALYZE LOGS
# ============================================================

# Helper function to extract cover generation time from log
function Get-CoverGenerationTime {
    param(
        [string]$FilePath,
        [switch]$DebugMode
    )

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    $content = Get-Content $FilePath

    # Pattern to find the start of cover generation
    $startPattern = "\[(\d+)\]\s+\[DBG\]\s+\[EBP\]\s+Generating thumb.*cover image"

    # Try to find success first
    $endSuccessPattern = "\[(\d+)\]\s+\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+yes"
    $endSuccessMatch = $content | Select-String -Pattern $endSuccessPattern | Select-Object -First 1

    # Try to find failure
    $endFailurePattern = "\[(\d+)\]\s+\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+no"
    $endFailureMatch = $content | Select-String -Pattern $endFailurePattern | Select-Object -First 1

    $startMatch = $content | Select-String -Pattern $startPattern | Select-Object -First 1

    if ($startMatch) {
        $startTime = [int]$startMatch.Matches[0].Groups[1].Value

        if ($endSuccessMatch) {
            $endTime = [int]$endSuccessMatch.Matches[0].Groups[1].Value
            $durationMs = $endTime - $startTime
            $durationSec = [Math]::Round($durationMs / 1000, 2)

            $result = [PSCustomObject]@{
                StartTime = $startTime
                EndTime = $endTime
                DurationMs = $durationMs
                DurationSec = $durationSec
                Success = $true
                Found = $true
            }

            return $result
        }

        if ($endFailureMatch) {
            $endTime = [int]$endFailureMatch.Matches[0].Groups[1].Value
            $durationMs = $endTime - $startTime
            $durationSec = [Math]::Round($durationMs / 1000, 2)

            $result = [PSCustomObject]@{
                StartTime = $startTime
                EndTime = $endTime
                DurationMs = $durationMs
                DurationSec = $durationSec
                Success = $false
                Found = $true
            }

            return $result
        }
    }

    if ($DebugMode) {
        Write-Host "  Cover generation NOT detected in log" -ForegroundColor Yellow
    }

    return $null
}

# Function to parse log filename
# Format: COM3_ORIGINAL_LIBRO.EPUB_20250313_123456.txt
function Parse-LogFilename {
    param($FilePath)

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $parts = $fileName -split '_'

    $result = [PSCustomObject]@{
        Path = $FilePath
        FileName = $fileName  # Add complete filename
        Port = $null
        Type = $null
        BookName = $null
        Timestamp = $null
        Firmware = "Unknown"
        Branch = "Unknown"
        IsValid = $false
    }

    # Try to parse the new format: COM3_TYPE_BOOKNAME_TIMESTAMP
    if ($parts.Count -ge 4) {
        $result.Port = $parts[0]
        $result.Type = $parts[1]
        $result.Timestamp = $parts[-1]

        # Extract book name (everything between type and timestamp)
        $bookParts = $parts[2..($parts.Count - 2)]
        $result.BookName = $bookParts -join '_'

        # Validate port format
        if ($result.Port -match '^COM\d+$') {
            $result.IsValid = $true
        }
    }

    # Extract firmware and branch from CAPTURE_METADATA line
    if (Test-Path $FilePath) {
        try {
            $firstLine = Get-Content $FilePath -First 1
            if ($firstLine -match 'CAPTURE_METADATA:.*Firmware=([^,]+),\s*Branch=([^\s]+)') {
                $result.Firmware = $matches[1]
                $result.Branch = $matches[2]
            }
        } catch {
            # Keep default values if file can't be read
        }
    }

    return $result
}

# Function to extract render times from log
function Get-RenderTimes {
    param($FilePath)

    if (-not (Test-Path $FilePath)) {
        return @()
    }

    $content = Get-Content $FilePath

    # Find lines with "Rendered page" - these will be like: "[DBG] [ERS] Rendered page in 1791ms"
    # Then look backwards to find the timestamp
    $renderedPageLines = @()
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match "Rendered page in (\d+)ms") {
            # Found a render time line, extract the time
            $time = [int]$matches[1]

            # Look backwards for the timestamp (previous non-empty line ending with "]")
            $timestamp = 0
            for ($j = $i - 1; $j -ge 0 -and $timestamp -eq 0; $j--) {
                if ($content[$j] -match "^\[(\d+)\]$" -or $content[$j] -match "^\[(\d+)\]\s") {
                    $timestamp = [int]$matches[1]
                    break
                }
            }

            $renderedPageLines += [PSCustomObject]@{
                Timestamp = $timestamp
                Time = $time
            }
        }
    }

    return $renderedPageLines
}

# Function to extract images decoded per page from logs
function Get-ImagesPerPage {
    param($FilePath)

    if (-not (Test-Path $FilePath)) {
        return @()
    }

    $content = Get-Content $FilePath

    # Find all "Rendered page" entries to get page boundaries
    # Process line by line, looking for "Rendered page" and then finding the timestamp
    $renderedPages = @()
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match "Rendered page in (\d+)ms") {
            $time = [int]$matches[1]

            # Look backwards for the timestamp
            $timestamp = 0
            for ($j = $i - 1; $j -ge 0 -and $timestamp -eq 0; $j--) {
                if ($content[$j] -match "^\[(\d+)\]$" -or $content[$j] -match "^\[(\d+)\]\s") {
                    $timestamp = [int]$matches[1]
                    break
                }
            }

            $renderedPages += [PSCustomObject]@{
                Timestamp = $timestamp
                Time = $time
            }
        }
    }

    # Find all image decode successful entries (more flexible patterns)
    $decodeSuccess = @()
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match "\[(\d+)\].*\[IMG\].*Decoding.*page.*complete") {
            $decodeSuccess += [PSCustomObject]@{
                Timestamp = [int]$matches[1]
                Line = $content[$i]
            }
        } elseif ($content[$i] -match "\[(\d+)\].*\[IMG\].*Decode successful") {
            $decodeSuccess += [PSCustomObject]@{
                Timestamp = [int]$matches[1]
                Line = $content[$i]
            }
        }
    }

    $results = @()

    # For each rendered page, count images decoded BEFORE that page render
    for ($i = 0; $i -lt $renderedPages.Count; $i++) {
        $currentPageTime = $renderedPages[$i].Timestamp

        # Get the previous page's time (or 0 for first page)
        if ($i -gt 0) {
            $previousPageTime = $renderedPages[$i - 1].Timestamp
        } else {
            $previousPageTime = 0
        }

        # Count image decodes between previous page and current page
        $imageCount = 0
        foreach ($decode in $decodeSuccess) {
            $decodeTime = $decode.Timestamp
            if ($decodeTime -gt $previousPageTime -and $decodeTime -lt $currentPageTime) {
                $imageCount++
            }
        }

        $results += [PSCustomObject]@{
            PageIndex = $i
            ImageCount = $imageCount
            Images = @()
        }
    }

    return $results
}

# Function to calculate median
function Get-Median {
    param($Values)

    $sorted = $Values | Sort-Object
    $count = $sorted.Count

    if ($count -eq 0) { return 0 }

    $mid = [Math]::Floor($count / 2)

    if ($count % 2 -eq 0) {
        return ($sorted[$mid - 1] + $sorted[$mid]) / 2
    } else {
        return $sorted[$mid]
    }
}

# Function to calculate standard deviation
function Get-StdDev {
    param($Values, $Mean)

    if ($Values.Count -eq 0) { return 0 }

    $sumOfSquares = 0
    foreach ($val in $Values) {
        $sumOfSquares += [Math]::Pow($val - $Mean, 2)
    }

    return [Math]::Sqrt($sumOfSquares / $Values.Count)
}

# Function to calculate percentile
function Get-Percentile {
    param($Values, $Percentile)

    $sorted = $Values | Sort-Object
    $count = $sorted.Count

    if ($count -eq 0) { return 0 }

    $index = [Math]::Ceiling(($Percentile / 100) * $count) - 1
    $index = [Math]::Max(0, [Math]::Min($index, $count - 1))

    return $sorted[$index]
}

function Start-AnalyzeLogs {
    Clear-Host
    Write-Host ""
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  SMART LOG ANALYZER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Check logs directory
    if (-not (Test-Path $logsDir)) {
        Write-Host "ERROR: Logs directory not found: $logsDir" -ForegroundColor Red
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host
        return
    }

    # Get all log files
    $logFiles = Get-ChildItem $logsDir -Filter "*.txt" | Sort-Object LastWriteTime -Descending

    if ($logFiles.Count -eq 0) {
        Write-Host "ERROR: No log files found in $logsDir" -ForegroundColor Red
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host
        return
    }

    # Parse all log files
    Write-Host "Scanning logs..." -ForegroundColor Yellow

    $parsedLogs = @()
    foreach ($logFile in $logFiles) {
        $parsed = Parse-LogFilename $logFile.FullName
        if ($parsed.IsValid) {
            $parsedLogs += $parsed
        }
    }

    if ($parsedLogs.Count -eq 0) {
        Write-Host "ERROR: No valid log files found" -ForegroundColor Red
        Write-Host ""
        Write-Host "Expected filename format: COM3_ORIGINAL_BOOKNAME.EPUB_20250313_123456.txt" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host
        return
    }

    # Group logs by timestamp (test session)
    $groupedLogs = $parsedLogs | Group-Object -Property Timestamp

    Write-Host "Found $($parsedLogs.Count) log files, $($groupedLogs.Count) different test sessions" -ForegroundColor Green
    Write-Host ""

    # Display grouped logs
    Write-Host "Logs grouped by test session (timestamp):" -ForegroundColor Cyan
    Write-Host ""

    $logIndex = 0
    $logMap = @{} # Map index to parsed log

    foreach ($group in $groupedLogs) {
        # Format timestamp for display
        $timestamp = $group.Name
        $formatted = $timestamp

        # Check if it's a full timestamp (YYYYMMDDHHmmss) or just time (HHmmss)
        if ($timestamp -match '^(\d{8})(\d{6})$') {
            # Full timestamp with date and time
            $datePart = $matches[1]
            $timePart = $matches[2]
            $formatted = "$($datePart.Substring(0,4))-$($datePart.Substring(4,2))-$($datePart.Substring(6,2)) $($timePart.Substring(0,2)):$($timePart.Substring(2,2)):$($timePart.Substring(4,2))"
        } elseif ($timestamp -match '^(\d{6})$') {
            # Just time (HHmmss) - get date from file modification time
            $timePart = $matches[1]
            $firstLog = $group.Group | Select-Object -First 1
            $fileDate = (Get-Item $firstLog.Path).LastWriteTime
            $dateStr = $fileDate.ToString("yyyy-MM-dd")
            $formatted = "$dateStr $($timePart.Substring(0,2)):$($timePart.Substring(2,2)):$($timePart.Substring(4,2))"
        }

        Write-Host "  [$formatted]" -ForegroundColor Yellow

        foreach ($log in $group.Group) {
            $logIndex++
            $logMap[$logIndex] = $log

            Write-Host "    [$logIndex] $($log.FileName)" -ForegroundColor White
        }
        Write-Host ""
    }

    # Interactive selection
    Write-Host "Select logs to compare (comma-separated, e.g.: 1,3 or 1-4):" -ForegroundColor Yellow
    $selection = Read-Host "Selection"

    # Parse selection
    $selectedIndices = @()
    foreach ($part in $selection -split ',') {
        if ($part -match '^(\d+)-(\d+)$') {
            # Range
            $start = [int]$matches[1]
            $end = [int]$matches[2]
            for ($i = $start; $i -le $end; $i++) {
                if ($logMap.ContainsKey($i)) {
                    $selectedIndices += $i
                }
            }
        } elseif ($part -match '^\d+$') {
            # Single number
            $index = [int]$part
            if ($logMap.ContainsKey($index)) {
                $selectedIndices += $index
            }
        }
    }

    if ($selectedIndices.Count -lt 2) {
        Write-Host "ERROR: Please select at least 2 logs to compare" -ForegroundColor Red
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host
        return
    }

    # Get selected logs
    $selectedLogs = $selectedIndices | ForEach-Object { $logMap[$_] }

    Write-Host ""
    Write-Host "Selected logs:" -ForegroundColor Green
    foreach ($log in $selectedLogs) {
        Write-Host "  $($log.FileName)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host ""

    # Extract all data: render times, images, and cover generation
    Write-Host "Extracting data..." -ForegroundColor Yellow

    $logsWithTimes = @()
    foreach ($log in $selectedLogs) {
        # Extract render times
        $times = Get-RenderTimes $log.Path
        $log | Add-Member -MemberType NoteProperty -Name "RenderTimes" -Value $times -Force

        # Extract images per page
        $images = Get-ImagesPerPage $log.Path
        $log | Add-Member -MemberType NoteProperty -Name "ImagesPerPage" -Value $images -Force
        $totalImages = ($images | ForEach-Object { $_.ImageCount } | Measure-Object -Sum).Sum

        # Extract cover generation time
        $coverTime = Get-CoverGenerationTime $log.Path -DebugMode:$false
        $log | Add-Member -MemberType NoteProperty -Name "CoverGenerationTime" -Value $coverTime -Force

        $logsWithTimes += $log

        # Display summary for this log
        $summary = "$($times.Count) pages, $totalImages images"
        if ($coverTime) {
            $coverStatus = if ($coverTime.Success) { "SUCCESS" } else { "FAILED" }
            $summary += " + cover ($coverStatus)"
        }
        $firmwareInfo = "$($log.Firmware) [$($log.Branch)]"
        Write-Host "  $($log.Port) ($($log.Type)): $summary" -ForegroundColor Gray
        Write-Host "     Firmware: $firmwareInfo" -ForegroundColor DarkGray
    }

    Write-Host ""

    # IMPORTANT WARNING about image loading fairness
    Write-Host "[!] COMPARISON FAIRNESS WARNING" -ForegroundColor Yellow
    Write-Host "  This analysis compares render times, but does NOT verify if all images" -ForegroundColor Yellow
    Write-Host "  loaded successfully. A faster time may indicate MISSING or FAILED images." -ForegroundColor Yellow
    Write-Host "  Pages with missing images will be marked with '[!]' in the Winner column." -ForegroundColor Yellow
    Write-Host ""
    Write-Host ""

    # Check if all selected logs are for the same book
    $uniqueBooks = ($selectedLogs | Select-Object -ExpandProperty BookName -Unique).Count

    if ($uniqueBooks -gt 1) {
        Write-Host "WARNING: Comparing different books!" -ForegroundColor Yellow
        Write-Host "This comparison may not be meaningful." -ForegroundColor Yellow
        Write-Host ""
        Write-Host ""
    }

    # Determine comparison type (based on Type - ORIGINAL/OPTIMIZED, not BookName)
    $uniqueTypes = ($selectedLogs | Select-Object -ExpandProperty Type -Unique).Count
    $uniquePorts = ($selectedLogs | Select-Object -ExpandProperty Port -Unique).Count

    # Generate descriptive comparison type
    if ($uniqueTypes -gt 1 -and $uniquePorts -gt 1) {
        $comparisonType = "Different book, different device"
    } elseif ($uniqueTypes -gt 1 -and $uniquePorts -eq 1) {
        $comparisonType = "Different book, same device"
    } elseif ($uniqueTypes -eq 1 -and $uniquePorts -gt 1) {
        $comparisonType = "Same book, different device"
    } else {
        $comparisonType = "Same configuration"
    }

    Write-Host "Comparison type: $comparisonType" -ForegroundColor Cyan
    Write-Host ""

    # Find minimum number of pages
    $minPages = ($logsWithTimes | ForEach-Object { $_.RenderTimes.Count } | Measure-Object -Minimum).Minimum

    if ($minPages -eq 0) {
        Write-Host "ERROR: No render times found in selected logs" -ForegroundColor Red
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host
        return
    }

    # Generate comparison table
    $comparison = @()

    # Determine column names based on comparison type
    $colA = $null
    $colB = $null
    $displayColA = $null
    $displayColB = $null

    if ($logsWithTimes.Count -eq 2) {
        $logA = $logsWithTimes[0]
        $logB = $logsWithTimes[1]

        if ($logA.Port -eq $logB.Port -and $logA.Type -eq $logB.Type) {
            # Same device and book = use Test1/Test2 to avoid duplicate column names
            $colA = "Test1_ms"
            $colB = "Test2_ms"
            $displayColA = "Test1"
            $displayColB = "Test2"
        } else {
            # Different devices or books = use Port_Type format
            $colA = "$($logA.Port)_$($logA.Type)_ms"
            $colB = "$($logB.Port)_$($logB.Type)_ms"
            $displayColA = "$($logA.Port) ($($logA.Type))"
            $displayColB = "$($logB.Port) ($($logB.Type))"
        }
    }

    for ($i = 0; $i -lt $minPages; $i++) {
        $row = [PSCustomObject]@{
            Page = ($i + 1)
        }

        # Add each log's render time to the row
        if ($logsWithTimes.Count -eq 2) {
            $logA = $logsWithTimes[0]
            $logB = $logsWithTimes[1]
            $row | Add-Member -MemberType NoteProperty -Name $colA -Value $logA.RenderTimes[$i].Time -Force
            $row | Add-Member -MemberType NoteProperty -Name $colB -Value $logB.RenderTimes[$i].Time -Force
        } else {
            foreach ($log in $logsWithTimes) {
                $colName = "$($log.Port)_$($log.Type)_ms"
                $row | Add-Member -MemberType NoteProperty -Name $colName -Value $log.RenderTimes[$i].Time -Force
            }
        }

        $comparison += $row
    }

    # Add Cover row if both logs have cover generation time data
    $hasCoverRow = $false
    if ($logsWithTimes.Count -eq 2) {
        $logA = $logsWithTimes[0]
        $logB = $logsWithTimes[1]

        # Add cover row if at least one has cover generation data
        if ($logA.CoverGenerationTime -or $logB.CoverGenerationTime) {
            # Determine page label based on cover generation status
            $coverLabel = "Cover"
            if ($logA.CoverGenerationTime -and $logB.CoverGenerationTime) {
                # Both have cover data
                if (-not $logA.CoverGenerationTime.Success -or -not $logB.CoverGenerationTime.Success) {
                    # At least one failed - mark as unfair comparison
                    $coverLabel = "Cover [!]" # One or both failed to generate cover
                }
            } else {
                # Only one has cover data - mark as unfair
                $coverLabel = "Cover [!]" # Can't compare fairly
            }

            $coverRow = [PSCustomObject]@{
                Page = $coverLabel
            }

            # Add cover generation times (in milliseconds) using same column names
            if ($logA.CoverGenerationTime) {
                $coverRow | Add-Member -MemberType NoteProperty -Name $colA -Value $logA.CoverGenerationTime.DurationMs -Force
                # Add success flag as hidden property
                $coverRow | Add-Member -MemberType NoteProperty -Name "${colA}_CoverSuccess" -Value $logA.CoverGenerationTime.Success -Force
            } else {
                $coverRow | Add-Member -MemberType NoteProperty -Name $colA -Value "N/A" -Force
                $coverRow | Add-Member -MemberType NoteProperty -Name "${colA}_CoverSuccess" -Value $false -Force
            }

            if ($logB.CoverGenerationTime) {
                $coverRow | Add-Member -MemberType NoteProperty -Name $colB -Value $logB.CoverGenerationTime.DurationMs -Force
                # Add success flag as hidden property
                $coverRow | Add-Member -MemberType NoteProperty -Name "${colB}_CoverSuccess" -Value $logB.CoverGenerationTime.Success -Force
            } else {
                $coverRow | Add-Member -MemberType NoteProperty -Name $colB -Value "N/A" -Force
                $coverRow | Add-Member -MemberType NoteProperty -Name "${colB}_CoverSuccess" -Value $false -Force
            }

            # Add to comparison at the beginning
            $comparison = @($coverRow) + $comparison
            $hasCoverRow = $true
        }
    }

    # Display analysis message based on whether we have cover data
    if ($hasCoverRow) {
        Write-Host "Analyzing first $minPages pages + cover..." -ForegroundColor Yellow
    } else {
        Write-Host "Analyzing first $minPages pages..." -ForegroundColor Yellow
    }
    Write-Host ""

    # Add Diff, Percent, Winner columns if comparing 2 logs
    if ($logsWithTimes.Count -eq 2) {
        $logA = $logsWithTimes[0]
        $logB = $logsWithTimes[1]
        # Note: $colA and $colB are already set above (lines 454-464) based on comparison type

        foreach ($row in $comparison) {
            $timeA = $row.$colA
            $timeB = $row.$colB
            $diff = $timeA - $timeB
            $percent = if ($timeA -gt 0) { [Math]::Round(($diff / $timeA) * 100, 1) } else { 0 }

            # Check for image discrepancies (missing images = potentially unfair comparison)
            $imagesA = 0
            $imagesB = 0

            if ($row.Page -is [int]) {
                # Regular page: get images from ImagesPerPage array
                $pageIndex = $row.Page - 1

                if ($pageIndex -lt $logA.ImagesPerPage.Count) {
                    $imagesA = $logA.ImagesPerPage[$pageIndex].ImageCount
                }

                if ($pageIndex -lt $logB.ImagesPerPage.Count) {
                    $imagesB = $logB.ImagesPerPage[$pageIndex].ImageCount
                }
            } elseif ($row.Page -like "*Cover*") {
                # Cover row (handles both "Cover" and "Cover [!]")
                # For cover: Use different validation - check if cover generation succeeded/failed
                # NOT the same as counting images in regular pages
                # Set image counts based on cover generation success:
                # - If succeeded: count as 1 (cover image was processed)
                # - If failed: count as 0 (cover image was NOT processed)
                # This allows fair comparison of cover generation performance

                # Note: CoverSuccess properties are already added to the row as hidden fields
                $coverSuccessA = $row."${colA}_CoverSuccess"
                $coverSuccessB = $row."${colB}_CoverSuccess"

                # Set image count based on whether cover generation succeeded
                # True = 1 (cover was generated), False = 0 (cover failed to generate)
                if ($coverSuccessA -eq $true) { $imagesA = 1 } elseif ($coverSuccessA -eq $false) { $imagesA = 0 }
                if ($coverSuccessB -eq $true) { $imagesB = 1 } elseif ($coverSuccessB -eq $false) { $imagesB = 0 }

                # If one log doesn't have cover data at all, mark as 0
                if ($null -eq $coverSuccessA) { $imagesA = 0 }
                if ($null -eq $coverSuccessB) { $imagesB = 0 }
            }

            $hasImageDiscrepancy = $imagesA -ne $imagesB

            # Check for cover generation status mismatch (unfair comparison)
            $hasCoverMismatch = $false
            if ($row.Page -like "*Cover*") {
                # This is a cover row - check if both succeeded or both failed
                $coverSuccessA = $row."${colA}_CoverSuccess"
                $coverSuccessB = $row."${colB}_CoverSuccess"
                if ($coverSuccessA -ne $coverSuccessB) {
                    $hasCoverMismatch = $true
                }
            }

            # Determine winner
            if ([Math]::Abs($percent) -lt 1) {
                $winner = "TIE"
            } elseif ($diff -lt 0) {
                $winner = $logA.Type
            } elseif ($diff -gt 0) {
                $winner = $logB.Type
            } else {
                $winner = "TIE"
            }

            # Determine column names for images based on comparison type
            # If comparing different book types (ORIGINAL vs OPTIMIZED), use TYPE
            # If comparing same book on different devices, use DEVICE/PORT
            # If comparing same device and book, use TEST1/TEST2
            if ($uniqueTypes -gt 1) {
                # Book Type Comparison: Images_ORIGINAL, Images_OPTIMIZED
                $imagesColA = "Images_$($logA.Type)"
                $imagesColB = "Images_$($logB.Type)"
            } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
                # Same Device Repeatability: Images_Test1, Images_Test2
                $imagesColA = "Images_Test1"
                $imagesColB = "Images_Test2"
            } else {
                # Device Comparison: Images_COM3, Images_COM4
                $imagesColA = "Images_$($logA.Port)"
                $imagesColB = "Images_$($logB.Port)"
            }

            # Add warning marker to winner if images don't match or cover generation status differs
            if ($hasImageDiscrepancy -or $hasCoverMismatch) {
                $winner = "$winner [!]"
            }

            # Add dynamic image count columns
            $row | Add-Member -MemberType NoteProperty -Name $imagesColA -Value $imagesA -Force
            $row | Add-Member -MemberType NoteProperty -Name $imagesColB -Value $imagesB -Force

            $row | Add-Member -MemberType NoteProperty -Name "Diff_ms" -Value $diff -Force
            $row | Add-Member -MemberType NoteProperty -Name "Percent" -Value "$percent%" -Force
            $row | Add-Member -MemberType NoteProperty -Name "Winner" -Value $winner -Force
        }
    }

    # Display comparison table
    Write-Host "Render Time Comparison:" -ForegroundColor Cyan
    Write-Host ""

    # Add comparison title for 2-log comparisons
    if ($logsWithTimes.Count -eq 2) {
        $logA = $logsWithTimes[0]
        $logB = $logsWithTimes[1]

        # Determine display names and comparison title
        if ($uniqueTypes -gt 1) {
            $displayNameA = "$($logA.Type) [$($logA.Firmware)]"
            $displayNameB = "$($logB.Type) [$($logB.Firmware)]"
            $comparisonTitle = "Book Version"
        } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
            # Same device, same book = different tests
            $displayNameA = "Test 1 ($($logA.Port)) [$($logA.Firmware)]"
            $displayNameB = "Test 2 ($($logB.Port)) [$($logB.Firmware)]"
            $comparisonTitle = "Same Device Repeatability Test"
        } else {
            $displayNameA = "$($logA.Port) [$($logA.Firmware)]"
            $displayNameB = "$($logB.Port) [$($logB.Firmware)]"
            $comparisonTitle = "Device Performance"
        }

        Write-Host "${comparisonTitle}: ${displayNameA} vs ${displayNameB}" -ForegroundColor Yellow
        Write-Host ""
    }

    # Build column headers
    $headers = @("Page")
    if ($logsWithTimes.Count -eq 2 -and $displayColA -and $displayColB) {
        # Use the display names we determined earlier
        $headers += $displayColA
        $headers += $displayColB
    } else {
        # Fallback to port/type format
        foreach ($log in $logsWithTimes) {
            $headers += "$($log.Port) ($($log.Type))"
        }
    }

    # Display table with custom formatting
    # Build ordered list of properties to display, excluding hidden properties
    if ($comparison.Count -gt 0) {
        $orderedProperties = @("Page")

        # Add time columns
        if ($logsWithTimes.Count -eq 2) {
            $orderedProperties += $colA
            $orderedProperties += $colB

            # Add image columns if they exist
            $allProperties = $comparison[0].PSObject.Properties.Name
            $imageCols = $allProperties | Where-Object { $_ -like "Images_*" -and $_ -notlike "*CoverSuccess" }
            $orderedProperties += $imageCols

            # Add comparison columns
            $orderedProperties += "Diff_ms", "Percent", "Winner"
        } else {
            # Single or multiple logs: add all time columns
            foreach ($log in $logsWithTimes) {
                $timeCol = "$($log.Port)_$($log.Type)_ms"
                if ($allProperties -contains $timeCol) {
                    $orderedProperties += $timeCol
                }
            }
        }

        $comparison | Format-Table -Property $orderedProperties -AutoSize
    } else {
        $comparison | Format-Table -AutoSize
    }

    # Add Legend for 2-log comparison
    if ($logsWithTimes.Count -eq 2) {

        # Column legend
        Write-Host "Legend:" -ForegroundColor Cyan
        Write-Host "  - $displayNameA : When $displayNameA is faster" -ForegroundColor Green
        Write-Host "  - $displayNameB : When $displayNameB is faster" -ForegroundColor Blue
        Write-Host "  - TIE : When the difference is < 1% (statistically insignificant)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "[!] UNFAIR COMPARISON WARNING:" -ForegroundColor Yellow
        Write-Host "  Pages marked with [!] may have unfair performance differences:" -ForegroundColor Yellow
        Write-Host "  - Cover generation: FAILED vs SUCCESS (faster time may mean missing cover processing)" -ForegroundColor Yellow
        Write-Host "  - Missing images: One version loaded fewer images than the other" -ForegroundColor Yellow
        Write-Host "  These differences represent MISSING/FAILED content, NOT real performance improvements!" -ForegroundColor Yellow
        Write-Host ""

        # Image discrepancy warning
        $pagesWithWarnings = $comparison | Where-Object { $_.Winner -like "*[!]*" }

        if ($pagesWithWarnings) {
            Write-Host "[!] UNFAIR COMPARISONS DETECTED:" -ForegroundColor Red

            foreach ($page in $pagesWithWarnings) {
                if ($page.Page -like "*Cover*") {
                    $coverSuccessA = $page."${colA}_CoverSuccess"
                    $coverSuccessB = $page."${colB}_CoverSuccess"
                    $statusA = if ($coverSuccessA) { "SUCCESS" } else { "FAILED" }
                    $statusB = if ($coverSuccessB) { "SUCCESS" } else { "FAILED" }

                    # Determine display names based on comparison type
                    if ($uniqueTypes -gt 1) {
                        $coverNameA = $logA.Type
                        $coverNameB = $logB.Type
                    } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
                        $coverNameA = "Test 1"
                        $coverNameB = "Test 2"
                    } else {
                        $coverNameA = $logA.Port
                        $coverNameB = $logB.Port
                    }

                    Write-Host "  Cover: $coverNameA cover generation $statusA, $coverNameB cover generation $statusB" -ForegroundColor Yellow
                }
            }

            Write-Host "  These comparisons may not reflect real performance differences!" -ForegroundColor Red
            Write-Host ""
        }

        # Summary
        $aWins = 0
        $bWins = 0
        $ties = 0

        foreach ($row in $comparison) {
            if ($row.Winner -eq $logA.Type) { $aWins++ }
            elseif ($row.Winner -eq $logB.Type) { $bWins++ }
            elseif ($row.Winner -eq "TIE") { $ties++ }
        }

        Write-Host "Summary:" -ForegroundColor Cyan

        # Determine display names for summary
        if ($uniqueTypes -gt 1) {
            $summaryNameA = $logA.Type
            $summaryNameB = $logB.Type
        } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
            $summaryNameA = "Test 1"
            $summaryNameB = "Test 2"
        } else {
            $summaryNameA = "$($logA.Port) ($($logA.Type))"
            $summaryNameB = "$($logB.Port) ($($logB.Type))"
        }

        # Calculate max label width for alignment
        $maxLabelWidth = [Math]::Max($summaryNameA.Length, [Math]::Max($summaryNameB.Length, 4))
        $labelWidth = $maxLabelWidth + 1

        Write-Host "  $($summaryNameA.PadRight($labelWidth)): $aWins wins" -ForegroundColor Green
        Write-Host "  $($summaryNameB.PadRight($labelWidth)): $bWins wins" -ForegroundColor Blue
        Write-Host "  $("Ties".PadRight($labelWidth)): $ties pages" -ForegroundColor Gray
        Write-Host ""

        # Comparative averages
        $avgA = ($comparison | ForEach-Object { $_.$colA } | Measure-Object -Average).Average
        $avgB = ($comparison | ForEach-Object { $_.$colB } | Measure-Object -Average).Average
        $avgDiff = $avgA - $avgB
        $avgPercent = if ($avgA -gt 0) { [Math]::Round(($avgDiff / $avgA) * 100, 1) } else { 0 }

        Write-Host "Averages:" -ForegroundColor Cyan
        Write-Host "  $($summaryNameA.PadRight($labelWidth)): $([Math]::Round($avgA, 0)) ms" -ForegroundColor Green
        Write-Host "  $($summaryNameB.PadRight($labelWidth)): $([Math]::Round($avgB, 0)) ms" -ForegroundColor Blue
        Write-Host ""

        # Determine display names for result message
        if ($uniqueTypes -gt 1) {
            $resultNameA = $logA.Type
            $resultNameB = $logB.Type
            $resultType = "book version"
        } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
            $resultNameA = "Test 1"
            $resultNameB = "Test 2"
            $resultType = "test"
        } else {
            $resultNameA = $logA.Port
            $resultNameB = $logB.Port
            $resultType = "device"
        }

        # Check if difference is statistically significant (> 1%)
        if ([Math]::Abs($avgPercent) -lt 1) {
            Write-Host "  Result: TIE (statistically insignificant difference: $([Math]::Round([Math]::Abs($avgDiff), 1)) ms, $([Math]::Abs($avgPercent))%)" -ForegroundColor Yellow
        } elseif ($avgDiff -lt 0) {
            Write-Host "  Result: $resultNameA is $([Math]::Round([Math]::Abs($avgDiff), 1)) ms faster than $resultNameB ($([Math]::Abs($avgPercent))%)" -ForegroundColor Green
        } elseif ($avgDiff -gt 0) {
            Write-Host "  Result: $resultNameB is $([Math]::Round([Math]::Abs($avgDiff), 1)) ms faster than $resultNameA ($([Math]::Abs($avgPercent))%)" -ForegroundColor Blue
        } else {
            Write-Host "  Result: TIE (both $resultType" + "s have equal performance)" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    # Extended Statistics
    Write-Host ""
    Write-Host "Extended Statistics:" -ForegroundColor Cyan

    if ($logsWithTimes.Count -eq 2) {
        # Two-log comparison: show side-by-side table
        $timesA = $comparison | ForEach-Object { $_.$colA }
        $timesB = $comparison | ForEach-Object { $_.$colB }

        $avgA = ($timesA | Measure-Object -Average).Average
        $minA = ($timesA | Measure-Object -Minimum).Minimum
        $maxA = ($timesA | Measure-Object -Maximum).Maximum
        $medianA = Get-Median $timesA
        $stdDevA = Get-StdDev $timesA $avgA
        $p95A = Get-Percentile $timesA 95
        $p99A = Get-Percentile $timesA 99

        $avgB = ($timesB | Measure-Object -Average).Average
        $minB = ($timesB | Measure-Object -Minimum).Minimum
        $maxB = ($timesB | Measure-Object -Maximum).Maximum
        $medianB = Get-Median $timesB
        $stdDevB = Get-StdDev $timesB $avgB
        $p95B = Get-Percentile $timesB 95
        $p99B = Get-Percentile $timesB 99

        $cvA = if ($avgA -gt 0) { ($stdDevA / $avgA) * 100 } else { 0 }
        $cvB = if ($avgB -gt 0) { ($stdDevB / $avgB) * 100 } else { 0 }

        # Determine display names based on comparison type
        if ($uniqueTypes -gt 1) {
            $displayNameA = $logA.Type
            $displayNameB = $logB.Type
        } else {
            $displayNameA = "Device A"
            $displayNameB = "Device B"
        }

        # Calculate column widths
        $labelWidth = 20
        $valueWidth = 12

        # Header
        Write-Host (" " * $labelWidth) -NoNewline
        Write-Host ($displayNameA.PadLeft($valueWidth)) -NoNewline -ForegroundColor Green
        Write-Host (" " * 4) -NoNewline
        Write-Host ($displayNameB.PadLeft($valueWidth)) -ForegroundColor Blue
        Write-Host ("-" * $labelWidth) -NoNewline -ForegroundColor Gray
        Write-Host ("-" * $valueWidth) -NoNewline -ForegroundColor Gray
        Write-Host (" " * 4) -NoNewline
        Write-Host ("-" * $valueWidth) -ForegroundColor Gray

        # Metrics
        $metrics = @(
            @{Label = "Min"; ValueA = $minA; ValueB = $minB},
            @{Label = "Max"; ValueA = $maxA; ValueB = $maxB},
            @{Label = "Avg"; ValueA = $avgA; ValueB = $avgB},
            @{Label = "Median"; ValueA = $medianA; ValueB = $medianB},
            @{Label = "Std Dev"; ValueA = $stdDevA; ValueB = $stdDevB},
            @{Label = "P95"; ValueA = $p95A; ValueB = $p95B},
            @{Label = "P99"; ValueA = $p99A; ValueB = $p99B}
        )

        foreach ($metric in $metrics) {
            Write-Host ($metric.Label.PadRight($labelWidth)) -NoNewline -ForegroundColor Cyan
            Write-Host ("$([Math]::Round($metric.ValueA)) ms").PadLeft($valueWidth) -NoNewline -ForegroundColor Gray
            Write-Host (" " * 4) -NoNewline
            Write-Host ("$([Math]::Round($metric.ValueB)) ms").PadLeft($valueWidth) -ForegroundColor Gray
        }
    }

    # Consistency Analysis (for 2-log comparisons only)
    if ($logsWithTimes.Count -eq 2) {
        $timesA = $comparison | ForEach-Object { $_.$colA }
        $timesB = $comparison | ForEach-Object { $_.$colB }
        $avgA = ($timesA | Measure-Object -Average).Average
        $avgB = ($timesB | Measure-Object -Average).Average

        # Recalculate standard deviations
        $stdDevA = Get-StdDev $timesA $avgA
        $stdDevB = Get-StdDev $timesB $avgB

        $cvA = if ($avgA -gt 0) { ($stdDevA / $avgA) * 100 } else { 0 }
        $cvB = if ($avgB -gt 0) { ($stdDevB / $avgB) * 100 } else { 0 }

        # Determine display names for consistency analysis
        if ($uniqueTypes -gt 1) {
            $consistencyNameA = "$($logA.Type) [$($logA.Firmware)]"
            $consistencyNameB = "$($logB.Type) [$($logB.Firmware)]"
        } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
            $consistencyNameA = "Test 1 [$($logA.Firmware)]"
            $consistencyNameB = "Test 2 [$($logB.Firmware)]"
        } else {
            $consistencyNameA = "$($logA.Port) [$($logA.Firmware)]"
            $consistencyNameB = "$($logB.Port) [$($logB.Firmware)]"
        }

        Write-Host ""
        Write-Host "Consistency Analysis:" -ForegroundColor Cyan
        Write-Host "  ${consistencyNameA}: Coef. of Variation = $([Math]::Round($cvA, 1))%" -ForegroundColor $(if ($cvA -lt 20) { "Green" } elseif ($cvA -lt 40) { "Yellow" } else { "Red" })
        Write-Host "  ${consistencyNameB}: Coef. of Variation = $([Math]::Round($cvB, 1))%" -ForegroundColor $(if ($cvB -lt 20) { "Green" } elseif ($cvB -lt 40) { "Yellow" } else { "Red" })
        Write-Host ""
    }

    # Optimization Impact / Performance Highlights (for 2-log comparisons only)
    if ($logsWithTimes.Count -eq 2) {
        # Determine display names based on comparison type
        if ($uniqueTypes -gt 1) {
            $displayNameA = "$($logA.Type) [$($logA.Firmware)]"
            $displayNameB = "$($logB.Type) [$($logB.Firmware)]"
            $sectionTitle = "Optimization Impact"

            # Find pages where OPTIMIZED improved the most
            $mostImproved = $comparison | Sort-Object -Property Diff_ms -Descending | Select-Object -First 1
            $leastImproved = $comparison | Sort-Object -Property Diff_ms | Select-Object -First 1

            # Extract numeric percentage from string (e.g., "0.1%" -> 0.1)
            $mostImprovedPercent = [double]($mostImproved.Percent -replace '%', '')
            $leastImprovedPercent = [double]($leastImproved.Percent -replace '%', '')

            # Check if the "least improved" actually got worse (negative diff)
            $gotWorse = $leastImproved.Diff_ms -lt 0

            Write-Host "${sectionTitle}:" -ForegroundColor Cyan

            # Check for warnings
            $mostImprovedHasWarning = $mostImproved.Winner -like "*[!]*"
            $leastImprovedHasWarning = $leastImproved.Winner -like "*[!]*"
            $hasUnfairComparison = $mostImprovedHasWarning -or $leastImprovedHasWarning

            # Only show "faster" if improvement > 1%
            if ($mostImprovedPercent -gt 1) {
                $warningText = if ($mostImprovedHasWarning) { " [!]" } else { "" }
                $pageDisplay = if ($mostImproved.Page -like "Cover*") { $mostImproved.Page } else { "Page $($mostImproved.Page)" }
                Write-Host "  Most improved:  $pageDisplay - $displayNameB is $($mostImproved.Diff_ms)ms faster ($($mostImproved.Percent))$warningText" -ForegroundColor Green
            } else {
                $pageDisplay = if ($mostImproved.Page -like "Cover*") { $mostImproved.Page } else { "Page $($mostImproved.Page)" }
                Write-Host "  Most improved:  $pageDisplay - $displayNameB is $($mostImproved.Diff_ms)ms ($($mostImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
            }

            if ($gotWorse -and [Math]::Abs($leastImprovedPercent) -gt 1) {
                $warningText = if ($leastImprovedHasWarning) { " [!]" } else { "" }
                $pageDisplay = if ($leastImproved.Page -like "Cover*") { $leastImproved.Page } else { "Page $($leastImproved.Page)" }
                Write-Host "  Regression:     $pageDisplay - $displayNameB is $($leastImproved.Diff_ms)ms SLOWER ($($leastImproved.Percent))$warningText" -ForegroundColor Red
            } elseif ($gotWorse) {
                $pageDisplay = if ($leastImproved.Page -like "Cover*") { $leastImproved.Page } else { "Page $($leastImproved.Page)" }
                Write-Host "  Regression:     $pageDisplay - $displayNameB is $($leastImproved.Diff_ms)ms ($($leastImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
            } else {
                $pageDisplay = if ($leastImproved.Page -like "Cover*") { $leastImproved.Page } else { "Page $($leastImproved.Page)" }
                Write-Host "  Least improved: $pageDisplay - $displayNameB is only $($leastImproved.Diff_ms)ms faster ($($leastImproved.Percent))" -ForegroundColor Yellow
            }
        } else {
            # Same book type: Device comparison
            $displayNameA = "$($logA.Port) [$($logA.Firmware)]"
            $displayNameB = "$($logB.Port) [$($logB.Firmware)]"
            $sectionTitle = "Performance Highlights"

            # Traditional best/worst based on pure difference
            $bestCase = $comparison | Sort-Object -Property Diff_ms | Select-Object -First 1
            $worstCase = $comparison | Sort-Object -Property Diff_ms -Descending | Select-Object -First 1

            Write-Host "${sectionTitle}:" -ForegroundColor Cyan

            # Check for warnings
            $bestCaseHasWarning = $bestCase.Winner -like "*[!]*"
            $worstCaseHasWarning = $worstCase.Winner -like "*[!]*"

            $bestWarningText = if ($bestCaseHasWarning) { " [!]" } else { "" }
            $worstWarningText = if ($worstCaseHasWarning) { " [!]" } else { "" }

            Write-Host "  Best performer:  Page $($bestCase.Page) - $displayNameA faster by $($bestCase.Diff_ms)ms ($($bestCase.Percent))$bestWarningText" -ForegroundColor Green
            Write-Host "  Worst performer: Page $($worstCase.Page) - $displayNameB faster by $($worstCase.Diff_ms)ms ($($worstCase.Percent))$worstWarningText" -ForegroundColor $(if ([Math]::Abs($worstCase.Diff_ms) -gt 1000) { "Red" } else { "Yellow" })

            # Show warning if any highlighted page has issues
            if ($bestCaseHasWarning -or $worstCaseHasWarning) {
                Show-UnfairComparisonWarning
            }
        }
        Write-Host ""
    }

    # Total Performance (for 2-log comparisons only)
    if ($logsWithTimes.Count -eq 2) {
        $timesA = $comparison | ForEach-Object { $_.$colA }
        $timesB = $comparison | ForEach-Object { $_.$colB }

        $totalTimeA = ($timesA | Measure-Object -Sum).Sum
        $totalTimeB = ($timesB | Measure-Object -Sum).Sum
        $totalTimeSaved = $totalTimeA - $totalTimeB
        $totalPages = $comparison.Count

        # Determine display names based on comparison type
        if ($uniqueTypes -gt 1) {
            $displayNameA = $logA.Type
            $displayNameB = $logB.Type
        } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
            $displayNameA = "Test 1"
            $displayNameB = "Test 2"
        } else {
            $displayNameA = "$($logA.Port)"
            $displayNameB = "$($logB.Port)"
        }

        Write-Host "Total Performance:" -ForegroundColor Cyan

        # Calculate label widths for alignment
        $label1 = "Total render time ${displayNameA}"
        $label2 = "Total render time ${displayNameB}"
        $label3 = "Time saved"
        $label4 = "Pages analyzed"

        $maxLabelWidth = [Math]::Max($label1.Length, [Math]::Max($label2.Length, [Math]::Max($label3.Length, $label4.Length)))

        # Check if we have unfair comparisons from Optimization Impact section
        $hasUnfairComparisonInOptimization = $false
        if ($uniqueTypes -gt 1) {
            $mostImproved = $comparison | Sort-Object -Property Diff_ms -Descending | Select-Object -First 1
            $leastImproved = $comparison | Sort-Object -Property Diff_ms | Select-Object -First 1
            $mostImprovedHasWarning = $mostImproved.Winner -like "*[!]*"
            $leastImprovedHasWarning = $leastImproved.Winner -like "*[!]*"
            $hasUnfairComparisonInOptimization = $mostImprovedHasWarning -or $leastImprovedHasWarning
        }

        # Prepare values for decimal alignment
        $timeA_str = [Math]::Round($totalTimeA / 1000, 2).ToString("0.00")
        $timeB_str = [Math]::Round($totalTimeB / 1000, 2).ToString("0.00")

        # Calculate max width for time values before decimal
        $maxTimeIntWidth = [Math]::Max($timeA_str.Split('.')[0].Length, $timeB_str.Split('.')[0].Length)

        # Format time values with decimal alignment
        $timeA_formatted = "{0}.{1}s" -f $timeA_str.Split('.')[0].PadLeft($maxTimeIntWidth), $timeA_str.Split('.')[1]
        $timeB_formatted = "{0}.{1}s" -f $timeB_str.Split('.')[0].PadLeft($maxTimeIntWidth), $timeB_str.Split('.')[1]

        Write-Host "  $($label1.PadRight($maxLabelWidth)): $($timeA_formatted) ($totalTimeA ms)" -ForegroundColor White
        Write-Host "  $($label2.PadRight($maxLabelWidth)): $($timeB_formatted) ($totalTimeB ms)" -ForegroundColor White

        if ($totalTimeSaved -ne 0) {
            $percentSaved = if ($totalTimeA -gt 0) { [Math]::Round(([Math]::Abs($totalTimeSaved) / $totalTimeA) * 100, 1) } else { 0 }

            # Format time saved with decimal alignment
            $timeSaved_str = [Math]::Round([Math]::Abs($totalTimeSaved) / 1000, 2).ToString("0.00")
            $timeSaved_int = $timeSaved_str.Split('.')[0]
            $timeSaved_dec = $timeSaved_str.Split('.')[1]
            $timeSaved_formatted = "{0}.{1}s" -f $timeSaved_int.PadLeft($maxTimeIntWidth), $timeSaved_dec

            # Only show "faster" if difference > 1%
            if ($percentSaved -gt 1) {
                $unfairMarker = if ($hasUnfairComparisonInOptimization) { " [!]" } else { "" }
                if ($totalTimeSaved -lt 0) {
                    Write-Host "  $($label3.PadRight($maxLabelWidth)): $($timeSaved_formatted) ($percentSaved%) - $displayNameA is faster$unfairMarker" -ForegroundColor Green
                } else {
                    Write-Host "  $($label3.PadRight($maxLabelWidth)): $($timeSaved_formatted) ($percentSaved%) - $displayNameB is faster$unfairMarker" -ForegroundColor Green
                }
            } else {
                Write-Host "  $($label3.PadRight($maxLabelWidth)): $($timeSaved_formatted) ($percentSaved%) - statistically insignificant" -ForegroundColor Gray
            }
        }
        Write-Host "  $($label4.PadRight($maxLabelWidth)): $totalPages" -ForegroundColor White
        Write-Host ""

        # Show warning if there are unfair comparisons
        if ($hasUnfairComparisonInOptimization) {
            Show-UnfairComparisonWarning
        }
        Write-Host ""
    }

    # Export to CSV
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    # Clean book names: remove .epub extension and individual timestamps
    $cleanBookNames = ($logsWithTimes | ForEach-Object {
        $name = $_.BookName
        $name = $name -replace '\.epub(_\d{8}(_\d{6})?)?$', ''
        $name
    }) -join '_vs_'

    $sanitizedBookNames = $cleanBookNames -replace '[^\w\-]', '_'
    $outputFile = Join-Path $logsDir "analysis_${sanitizedBookNames}_${timestamp}.csv"

    $comparison | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "CSV exported: $outputFile" -ForegroundColor Green

    # Ask if user wants to see charts (only for 2-log comparisons)
    if ($logsWithTimes.Count -eq 2) {
        Write-Host ""
        Write-Host ""
        $response = Read-Host "Show performance charts? (s/n)"

        if ($response -eq "s" -or $response -eq "S") {
            # Determine display names based on comparison type
            if ($uniqueTypes -gt 1) {
                $displayNameA = $logA.Type
                $displayNameB = $logB.Type
            } else {
                $displayNameA = "Device A"
                $displayNameB = "Device B"
            }

            Write-Host ""
            Write-Host "Select chart type:" -ForegroundColor Cyan
            Write-Host "  1. Bar chart - Side-by-side comparison of each page's render time" -ForegroundColor White
            Write-Host "  2. Trend chart - Shows how render times vary across pages (dot plot)" -ForegroundColor White
            Write-Host "  3. Statistics comparison - Compares Min, Max, Avg, Median, Std Dev, P95" -ForegroundColor White
            Write-Host "  4. All charts - Shows all visualization types" -ForegroundColor White
            $chartType = Read-Host "Choose (1-4)"

            # Shorten names for chart if needed
            $nameA = if ($displayNameA.Length -gt 10) { $displayNameA.Substring(0, 8) + ".." } else { $displayNameA }
            $nameB = if ($displayNameB.Length -gt 10) { $displayNameB.Substring(0, 8) + ".." } else { $displayNameB }

            if ($chartType -eq "1" -or $chartType -eq "4") {
                Write-Host ""
                Write-Host ""
                Write-Host "Bar Chart - Page Render Times Comparison" -ForegroundColor Cyan
                Write-Host "Comparing: $displayNameA vs $displayNameB" -ForegroundColor Yellow
                Write-Host "Each bar shows render time in milliseconds." -ForegroundColor Gray
                Write-Host ""

                foreach ($row in $comparison) {
                    $timeA = $row.$colA
                    $timeB = $row.$colB

                    # Skip if times are null or invalid
                    if ($null -eq $timeA -or $null -eq $timeB -or $timeA -eq "N/A" -or $timeB -eq "N/A") {
                        $pageLabel = if ($row.Page -like "*Cover*") { "Cover  : " } elseif ($row.Page -is [int]) { "Page $($row.Page.ToString().PadLeft(2)): " } else { "$($row.Page): " }
                        Write-Host "  $pageLabel N/A (no timing data)" -ForegroundColor Gray
                        continue
                    }

                    # Ensure times are numeric
                    if (-not ($timeA -is [int] -or $timeA -is [double] -or $timeA -is [decimal])) { $timeA = 0 }
                    if (-not ($timeB -is [int] -or $timeB -is [double] -or $timeB -is [decimal])) { $timeB = 0 }

                    $maxTime = [Math]::Max($timeA, $timeB)

                    # Scale to 21 characters max
                    $scaleA = if ($maxTime -gt 0) { [int](($timeA / $maxTime) * 21) } else { 0 }
                    $scaleB = if ($maxTime -gt 0) { [int](($timeB / $maxTime) * 21) } else { 0 }

                    # Display "Cover  :" or "Page X:" with proper alignment
                    $pageLabel = if ($row.Page -like "*Cover*") { "Cover  : " } elseif ($row.Page -is [int]) { "Page $($row.Page.ToString().PadLeft(2)): " } else { "$($row.Page): " }
                    Write-Host "  $pageLabel" -NoNewline -ForegroundColor Cyan

                    # Bar A
                    Write-Host "$nameA [" -NoNewline -ForegroundColor Green
                    Write-Host ("#" * $scaleA) -NoNewline -ForegroundColor Green
                    Write-Host (" " * (21 - $scaleA)) -NoNewline
                    Write-Host "] " -NoNewline -ForegroundColor Green
                    Write-Host "$($timeA.ToString().PadLeft(4))ms" -NoNewline -ForegroundColor Gray
                    Write-Host " | " -NoNewline -ForegroundColor Gray

                    # Bar B
                    Write-Host "$nameB [" -NoNewline -ForegroundColor Blue
                    Write-Host ("#" * $scaleB) -NoNewline -ForegroundColor Blue
                    Write-Host (" " * (21 - $scaleB)) -NoNewline
                    Write-Host "] " -NoNewline -ForegroundColor Blue
                    Write-Host "$($timeB.ToString().PadLeft(4))ms " -NoNewline -ForegroundColor Gray

                    # Winner with color coding
                    if ($row.Winner -eq "TIE") {
                        Write-Host $row.Winner -ForegroundColor Gray
                    } elseif ($row.Winner -match $logA.Type) {
                        $winnerShort = if ($logA.Type.Length -gt 8) { $logA.Type.Substring(0, 6) + ".." } else { $logA.Type }
                        Write-Host $winnerShort -ForegroundColor Green
                    } else {
                        $winnerShort = if ($logB.Type.Length -gt 8) { $logB.Type.Substring(0, 6) + ".." } else { $logB.Type }
                        Write-Host $winnerShort -ForegroundColor Blue
                    }
                }
                Write-Host ""
                Write-Host "Legend: Longer bars indicate slower page load times" -ForegroundColor Gray
                Write-Host ""
            }

            if ($chartType -eq "2" -or $chartType -eq "4") {
                Write-Host ""
                Write-Host ""
                Write-Host "Trend Chart - Page Render Times Over Time" -ForegroundColor Cyan
                Write-Host "Comparing: $displayNameA vs $displayNameB" -ForegroundColor Yellow
                Write-Host "Shows how render times change across pages." -ForegroundColor Gray
                Write-Host ""

                # Find global maximum for scaling
                $globalMax = 0
                foreach ($row in $comparison) {
                    $timeA = $row.$colA
                    $timeB = $row.$colB

                    # Skip null or invalid values
                    if ($null -eq $timeA -or $timeA -eq "N/A" -or -not ($timeA -is [int] -or $timeA -is [double] -or $timeA -is [decimal])) { $timeA = 0 }
                    if ($null -eq $timeB -or $timeB -eq "N/A" -or -not ($timeB -is [int] -or $timeB -is [double] -or $timeB -is [decimal])) { $timeB = 0 }

                    $globalMax = [Math]::Max([Math]::Max($globalMax, $timeA), $timeB)
                }

                foreach ($row in $comparison) {
                    $timeA = $row.$colA
                    $timeB = $row.$colB

                    # Skip if times are null or invalid
                    if ($null -eq $timeA -or $null -eq $timeB -or $timeA -eq "N/A" -or $timeB -eq "N/A") {
                        $pageLabel = if ($row.Page -like "*Cover*") { "Cover  : " } elseif ($row.Page -is [int]) { "Page $($row.Page.ToString().PadLeft(2)): " } else { "$($row.Page): " }
                        Write-Host "  $pageLabel N/A (no timing data)" -ForegroundColor Gray
                        continue
                    }

                    # Ensure times are numeric
                    if (-not ($timeA -is [int] -or $timeA -is [double] -or $timeA -is [decimal])) { $timeA = 0 }
                    if (-not ($timeB -is [int] -or $timeB -is [double] -or $timeB -is [decimal])) { $timeB = 0 }

                    # Scale to 20 characters max
                    $scaleA = if ($globalMax -gt 0) { [int](($timeA / $globalMax) * 20) } else { 0 }
                    $scaleB = if ($globalMax -gt 0) { [int](($timeB / $globalMax) * 20) } else { 0 }

                    # Display "Cover  :" or "Page X:" with proper alignment
                    $pageLabel = if ($row.Page -like "*Cover*") { "Cover  : " } elseif ($row.Page -is [int]) { "Page $($row.Page.ToString().PadLeft(2)): " } else { "$($row.Page): " }
                    Write-Host "  $pageLabel" -NoNewline -ForegroundColor Cyan

                    # Trend line A
                    Write-Host "$nameA [" -NoNewline -ForegroundColor Green
                    Write-Host (" " * $scaleA) -NoNewline
                    Write-Host "*" -NoNewline -ForegroundColor Green
                    Write-Host (" " * (20 - $scaleA)) -NoNewline
                    Write-Host "]" -NoNewline -ForegroundColor Green
                    Write-Host " $($timeA.ToString().PadLeft(4))ms" -NoNewline -ForegroundColor Gray
                    Write-Host " | " -NoNewline -ForegroundColor Gray

                    # Trend line B
                    Write-Host "$nameB [" -NoNewline -ForegroundColor Blue
                    Write-Host (" " * $scaleB) -NoNewline
                    Write-Host "*" -NoNewline -ForegroundColor Blue
                    Write-Host (" " * (20 - $scaleB)) -NoNewline
                    Write-Host "]" -NoNewline -ForegroundColor Blue
                    Write-Host " $($timeB.ToString().PadLeft(4))ms" -ForegroundColor Gray
                }
                Write-Host ""
                Write-Host "Legend: Dots (position from left) show relative speed. Further left = faster page" -ForegroundColor Gray
                Write-Host ""
            }

            # Statistics Comparison Chart
            if ($chartType -eq "3" -or $chartType -eq "4") {
                Write-Host ""
                Write-Host ""
                Write-Host "Statistics Chart - Performance Metrics Comparison" -ForegroundColor Cyan
                Write-Host "Comparing: $displayNameA vs $displayNameB" -ForegroundColor Yellow
                Write-Host "Bar lengths show relative magnitude. Lower values generally indicate better performance" -ForegroundColor Gray
                Write-Host ""

                # Calculate statistics for the chart
                $timesA = $comparison | ForEach-Object { $_.$colA }
                $timesB = $comparison | ForEach-Object { $_.$colB }

                $minA = ($timesA | Measure-Object -Minimum).Minimum
                $maxA = ($timesA | Measure-Object -Maximum).Maximum
                $medianA = Get-Median $timesA
                $stdDevA = Get-StdDev $timesA ($timesA | Measure-Object -Average).Average
                $p95A = Get-Percentile $timesA 95

                $minB = ($timesB | Measure-Object -Minimum).Minimum
                $maxB = ($timesB | Measure-Object -Maximum).Maximum
                $medianB = Get-Median $timesB
                $stdDevB = Get-StdDev $timesB ($timesB | Measure-Object -Average).Average
                $p95B = Get-Percentile $timesB 95

                # Calculate coefficient of variation
                $avgA = ($timesA | Measure-Object -Average).Average
                $avgB = ($timesB | Measure-Object -Average).Average
                $cvA = if ($avgA -gt 0) { ($stdDevA / $avgA) * 100 } else { 0 }
                $cvB = if ($avgB -gt 0) { ($stdDevB / $avgB) * 100 } else { 0 }

                # Find global maximum for scaling
                $minA = if ($null -eq $minA) { 0 } else { $minA }
                $minB = if ($null -eq $minB) { 0 } else { $minB }
                $maxA = if ($null -eq $maxA) { 0 } else { $maxA }
                $maxB = if ($null -eq $maxB) { 0 } else { $maxB }
                $medianA = if ($null -eq $medianA) { 0 } else { $medianA }
                $medianB = if ($null -eq $medianB) { 0 } else { $medianB }
                $avgA = if ($null -eq $avgA) { 0 } else { $avgA }
                $avgB = if ($null -eq $avgB) { 0 } else { $avgB }
                $stdDevA = if ($null -eq $stdDevA) { 0 } else { $stdDevA }
                $stdDevB = if ($null -eq $stdDevB) { 0 } else { $stdDevB }
                $p95A = if ($null -eq $p95A) { 0 } else { $p95A }
                $p95B = if ($null -eq $p95B) { 0 } else { $p95B }

                # Calculate global max safely
                $values = @($maxA, $maxB, $medianA, $medianB, $avgA, $avgB)
                $globalMax = ($values | Measure-Object -Maximum).Maximum

                # Define metrics to display
                $metrics = @(
                    @{Name = "Min"; ValueA = $minA; ValueB = $minB},
                    @{Name = "Max"; ValueA = $maxA; ValueB = $maxB},
                    @{Name = "Avg"; ValueA = $avgA; ValueB = $avgB},
                    @{Name = "Median"; ValueA = $medianA; ValueB = $medianB},
                    @{Name = "Std Dev"; ValueA = $stdDevA; ValueB = $stdDevB},
                    @{Name = "P95"; ValueA = $p95A; ValueB = $p95B}
                )

                # Display chart for each metric
                foreach ($metric in $metrics) {
                    # Scale bars (30 chars max)
                    $scaleA = if ($globalMax -gt 0) { [int](($metric.ValueA / $globalMax) * 30) } else { 0 }
                    $scaleB = if ($globalMax -gt 0) { [int](($metric.ValueB / $globalMax) * 30) } else { 0 }

                    # Column A
                    Write-Host "  $($metric.Name.PadRight(8)): $($displayNameA.PadLeft(9)) [" -NoNewline -ForegroundColor Green
                    Write-Host ("#" * $scaleA) -NoNewline -ForegroundColor Green
                    Write-Host (" " * (30 - $scaleA)) -NoNewline
                    Write-Host "] $([Math]::Round($metric.ValueA, 1).ToString().PadLeft(7))ms" -ForegroundColor Gray

                    # Column B
                    Write-Host "  $($metric.Name.PadRight(8)): $($displayNameB.PadLeft(9)) [" -NoNewline -ForegroundColor Blue
                    Write-Host ("#" * $scaleB) -NoNewline -ForegroundColor Blue
                    Write-Host (" " * (30 - $scaleB)) -NoNewline
                    Write-Host "] $([Math]::Round($metric.ValueB, 1).ToString().PadLeft(7))ms" -ForegroundColor Blue
                    Write-Host ""
                }

                # Consistency Analysis (Coefficient of Variation)
                Write-Host "  Consistency (Coef. of Variation):" -ForegroundColor Cyan
                Write-Host ""

                $cvMax = [Math]::Max($cvA, $cvB)
                $scaleCVA = if ($cvMax -gt 0) { [int](($cvA / $cvMax) * 30) } else { 0 }
                $scaleCVB = if ($cvMax -gt 0) { [int](($cvB / $cvMax) * 30) } else { 0 }

                Write-Host "  $($displayNameA.PadLeft(15)) [" -NoNewline -ForegroundColor Green
                Write-Host ("#" * $scaleCVA) -NoNewline -ForegroundColor $(if ($cvA -lt 20) { "Green" } elseif ($cvA -lt 40) { "Yellow" } else { "Red" })
                Write-Host (" " * (30 - $scaleCVA)) -NoNewline
                Write-Host "] $([Math]::Round($cvA, 1))%" -ForegroundColor $(if ($cvA -lt 20) { "Green" } elseif ($cvA -lt 40) { "Yellow" } else { "Red" })

                Write-Host "  $($displayNameB.PadLeft(15)) [" -NoNewline -ForegroundColor Blue
                Write-Host ("#" * $scaleCVB) -NoNewline -ForegroundColor $(if ($cvB -lt 20) { "Green" } elseif ($cvB -lt 40) { "Yellow" } else { "Red" })
                Write-Host (" " * (30 - $scaleCVB)) -NoNewline
                Write-Host "] $([Math]::Round($cvB, 1))%" -ForegroundColor $(if ($cvB -lt 20) { "Green" } elseif ($cvB -lt 40) { "Yellow" } else { "Red" })

                # Statistics explanation
                Write-Host ""
                Write-Host "Legend:" -ForegroundColor Gray
                Write-Host "  Min/Max: Fastest/Slowest page render times" -ForegroundColor Gray
                Write-Host "  Avg/Median: Average/Middle page render time" -ForegroundColor Gray
                Write-Host "  Std Dev: How much render times vary (lower = more consistent)" -ForegroundColor Gray
                Write-Host "  P95: 95th percentile (95%% of pages render faster than this)" -ForegroundColor Gray
                Write-Host "  Coef. of Variation: Std Dev / Avg (lower = more consistent performance)" -ForegroundColor Gray
                Write-Host ""
            }
        }
    }

    Write-Host ""
    Write-Host ""
    Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
    Read-Host
}

# ============================================================
# MAIN MENU LOOP
# ============================================================

$running = $true

while ($running) {
    Show-MainMenu
    $choice = Read-Host "Select option"

    switch ($choice) {
        "1" {
            $null = Start-SingleDeviceCapture
            if ($global:CaptureSuccess -eq $true) {
                Show-CaptureCompleteMenu
                $postCapture = Read-Host "Select option"
                switch ($postCapture) {
                    "0" { Start-SingleDeviceCapture }
                    "1" { Start-AnalyzeLogs }
                    "2" {
                        # Return to main menu - do nothing, loop continues
                    }
                    "3" { $running = $false }
                }
            }
        }
        "2" {
            $null = Start-DualDeviceCapture
            if ($global:CaptureSuccess -eq $true) {
                Show-CaptureCompleteMenu
                $postCapture = Read-Host "Select option"
                switch ($postCapture) {
                    "0" { Start-SingleDeviceCapture }
                    "1" { Start-AnalyzeLogs }
                    "2" {
                        # Return to main menu - do nothing, loop continues
                    }
                    "3" { $running = $false }
                }
            } else {
                # Capture failed, return to menu
            }
        }
        "3" {
            Start-AnalyzeLogs
        }
        "0" {
            $running = $false
        }
        default {
            Write-Host "Invalid option. Press ENTER to try again..." -ForegroundColor Red
            Read-Host
        }
    }
}

Write-Host ""
Write-Host "Exiting EPUB Optimization Benchmark..." -ForegroundColor Cyan
Write-Host ""
