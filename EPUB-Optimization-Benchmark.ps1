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
# FIRMWARE CACHE SYSTEM
# ============================================================

# Directory for firmware cache
$firmwareCacheDir = Join-Path $logsDir "firmware_cache"
if (-not (Test-Path $firmwareCacheDir)) {
    New-Item -ItemType Directory -Path $firmwareCacheDir | Out-Null
}

function Get-FirmwareCacheFilePath {
    param([string]$ComPort)
    return Join-Path $firmwareCacheDir "firmware_${ComPort}.json"
}

function Get-CachedFirmware {
    param(
        [string]$ComPort,
        [System.IO.Ports.SerialPort]$Port
    )

    $cacheFile = Get-FirmwareCacheFilePath -ComPort $ComPort

    # Check if cache exists (no validation of port state - cache persists)
    if (Test-Path $cacheFile) {
        try {
            $cacheData = Get-Content $cacheFile -Raw | ConvertFrom-Json

            # Check if cache is recent (within 1 hour)
            $cacheTime = [DateTime]::Parse($cacheData.Timestamp)
            if ((Get-Date) - $cacheTime -lt [TimeSpan]::FromHours(1)) {
                return @{
                    Firmware = $cacheData.firmware
                    Branch = $cacheData.branch
                    FromCache = $true
                }
            } else {
                # Cache is old, remove it
                Remove-Item $cacheFile -Force
            }
        } catch {
            # Invalid cache file, remove it
            if (Test-Path $cacheFile) {
                Remove-Item $cacheFile -Force
            }
        }
    }

    return $null
}

function Save-FirmwareCache {
    param(
        [string]$ComPort,
        [string]$Firmware,
        [string]$Branch
    )

    $cacheFile = Get-FirmwareCacheFilePath -ComPort $ComPort
    $cacheData = @{
        ComPort = $ComPort
        Firmware = $Firmware
        Branch = $Branch
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $cacheData | ConvertTo-Json | Set-Content $cacheFile -Encoding UTF8
    # Silent save - no output needed as it's transparent
}

function Get-FirmwareFromExistingLogs {
    param(
        [string]$ComPort,
        [int]$MaxFileAgeMinutes = 60
    )

    $logFiles = Get-ChildItem -Path $logsDir -Filter "*${ComPort}*.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-$MaxFileAgeMinutes) } |
        Sort-Object LastWriteTime -Descending

    if ($logFiles.Count -eq 0) {
        return $null
    }

    # Check the most recent log file
    $latestLog = $logFiles[0]
    try {
        $firstLine = Get-Content $latestLog.FullName -First 1 -ErrorAction SilentlyContinue
        if ($firstLine -match 'CAPTURE_METADATA:.*Firmware\+Branch=([^\s]+)') {
            $firmwareInfo = $matches[1] -split '\+'
            $firmwareVersion = $firmwareInfo[0]
            $firmwareBranch = if ($firmwareInfo.Count -gt 1) { $firmwareInfo[1] } else { "master" }

            # Ignore logs with Unknown firmware - treat as if not found
            if ($firmwareVersion -eq "Unknown" -or $firmwareVersion -eq "unknown") {
                return $null
            }

            return @{
                Firmware = $firmwareVersion
                Branch = $firmwareBranch
                Source = "Log: $($latestLog.Name)"
                Detected = $true
            }
        }
    }
    catch {
        # Error reading log file
    }

    return $null
}

function Get-TempFirmwareDetection {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [string]$ComPort,
        [int]$TimeoutSeconds = 8
    )

    $startTime = Get-Date
    $firmwareVersion = "Unknown"
    $firmwareBranch = "Unknown"
    $detected = $false
    $allData = New-Object System.Text.StringBuilder

    # Read any existing data first (might have firmware info)
    if ($Port.BytesToRead -gt 0) {
        $existingData = $Port.ReadExisting()
        $allData.Append($existingData) | Out-Null
    }

    while (-not $detected -and ($startTime).AddSeconds($TimeoutSeconds) -gt (Get-Date)) {
        Start-Sleep -Milliseconds 200

        if ($Port.BytesToRead -gt 0) {
            $data = $Port.ReadExisting()
            $allData.Append($data) | Out-Null

            # Check all accumulated data for firmware info
            $lines = $allData.ToString() -split "`r?`n"

            foreach ($line in $lines) {
                if ($line -match "\[DBG\]\s+\[MAIN\]\s+Starting\s+CrossPoint\s+version\s+([\d\.]+(?:-[a-z]+)?)(?:\+([^ \t]+))?") {
                    $firmwareVersion = $matches[1]
                    if ($matches[2]) {
                        $firmwareBranch = $matches[2]
                    } else {
                        $firmwareBranch = "master"
                    }
                    $detected = $true
                    break
                }
            }
        }
    }

    return @{
        Firmware = $firmwareVersion
        Branch = $firmwareBranch
        Detected = $detected
    }
}

function Detect-FirmwareFromDevice {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [string]$ComPort,
        [int]$TimeoutSeconds = 10
    )

    $startTime = Get-Date
    $firmwareVersion = "Unknown"
    $firmwareBranch = "Unknown"
    $detected = $false

    Write-Host "Detecting firmware for $ComPort..." -ForegroundColor Cyan

    while (-not $detected -and ($startTime).AddSeconds($TimeoutSeconds) -gt (Get-Date)) {
        Start-Sleep -Milliseconds 100

        if ($Port.BytesToRead -gt 0) {
            $data = $Port.ReadExisting()
            $lines = $data -split "`r?`n"

            foreach ($line in $lines) {
                if ($line -match "\[DBG\]\s+\[MAIN\]\s+Starting\s+CrossPoint\s+version\s+([\d\.]+(?:-[a-z]+)?)(?:\+([^ \t]+))?") {
                    $firmwareVersion = $matches[1]
                    if ($matches[2]) {
                        $firmwareBranch = $matches[2]
                    } else {
                        $firmwareBranch = "master"
                    }
                    $detected = $true
                    Write-Host "Detected firmware for $ComPort : $firmwareVersion+$firmwareBranch" -ForegroundColor Cyan
                    break
                }
            }
        }
    }

    if (-not $detected) {
        Write-Host "Firmware detection timeout for $ComPort - using 'Unknown'" -ForegroundColor Yellow
    }

    # Save to cache regardless of detection result
    Save-FirmwareCache -ComPort $ComPort -Firmware $firmwareVersion -Branch $firmwareBranch

    return @{
        Firmware = $firmwareVersion
        Branch = $firmwareBranch
        FromCache = $false
    }
}

function Get-FirmwareForDevice {
    param(
        [System.IO.Ports.SerialPort]$Port,
        [string]$ComPort
    )

    # Try to get from cache first (definitive association from previous session)
    $cached = Get-CachedFirmware -ComPort $ComPort -Port $Port
    if ($cached) {
        return $cached
    }

    # Not in cache, detect from device (for single device mode or skip-reset mode)
    Write-Host "No definitive association found for $ComPort - detecting firmware..." -ForegroundColor Yellow
    return Detect-FirmwareFromDevice -Port $Port -ComPort $ComPort
}

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
    Write-WithWarning "[!] CONTENT DISCREPANCY WARNING:" "Yellow"
    Write-WithWarning "  Pages marked with '[!]' have differences in images or cover generation between versions." "Yellow"
    Write-Host "  - If the WINNER had fewer images/failed cover: result may be MISLEADING" -ForegroundColor Yellow
    Write-Host "    (faster because it did less work, not truly faster)" -ForegroundColor Yellow
    Write-Host "  - If the LOSER had fewer images/failed cover: result is CONSERVATIVE" -ForegroundColor Yellow
    Write-Host "    (winner did more work and still won)" -ForegroundColor Yellow
    Write-Host ""

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
    Write-Host "Press ENTER para comenzar a capturar..." -ForegroundColor Yellow
    Read-Host

    Clear-Host
    Write-Host ""
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CAPTURE IN PROGRESS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Opening port..." -ForegroundColor Cyan

    # Open port and capture
    $captureSuccess = $false
    try {
        $port = New-Object System.IO.Ports.SerialPort($ComPort, 115200, "None", 8, "One")

        Write-Host ("Opening {0}..." -f $ComPort) -NoNewline
        $port.Open()
        Write-Host " [OK]" -ForegroundColor Green

        # Get firmware from cache or detect from device
        Write-Host "Getting firmware info..." -ForegroundColor Cyan
        $firmwareInfo = Get-FirmwareForDevice -Port $port -ComPort $ComPort
        $firmwareVersion = $firmwareInfo.Firmware
        $firmwareBranch = $firmwareInfo.Branch

        Write-Host "Creating writer..." -ForegroundColor Cyan
        $writer = New-Object System.IO.StreamWriter($fileName, $false, [System.Text.Encoding]::UTF8)
        $writer.AutoFlush = $true

        # Write metadata header immediately with firmware info
        $firmwareCombined = "${firmwareVersion}+${firmwareBranch}"
        $metadata = "CAPTURE_METADATA: Type=${sanitizedBook}, Device=$ComPort, Timestamp=${timestamp}, Firmware+Branch=${firmwareCombined}"
        $writer.WriteLine($metadata)
        $writer.Flush()

        Write-Host "[OK] Capturing... Press ESC or Q to stop" -ForegroundColor Green
        Write-Host ""

        $count = 0
        $pagesDetected = 0
        $coverStatus = $null
        $lastDot = Get-Date
        $stopRequested = $false

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
                # Write directly to file (metadata already written)
                $writer.Write($data)

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
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  DUAL DEVICE CAPTURE" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    if ($DebugMode) {
        Write-Host "  [DEBUG] Showing all received data" -ForegroundColor Magenta
        Write-Host ""
    }
    if ($SkipReset) {
        Write-Host "  [SKIP RESET] Devices will not be reset" -ForegroundColor Magenta
        Write-Host ""
    }

    # Get available COM ports
    $rawPorts = [System.IO.Ports.SerialPort]::GetPortNames()

    # Ensure we always have an array, never $null
    $availablePorts = @($rawPorts | Sort-Object | Select-Object -Unique)
    if ($null -eq $availablePorts) {
        $availablePorts = @()
    }

    if ($availablePorts.Count -lt 2) {
        Write-Host "  ERROR: Less than 2 COM ports detected ($($availablePorts -join ', '))" -ForegroundColor Red
        Write-Host ""
        Write-Host "Press ENTER to return to menu..." -ForegroundColor Gray
        Read-Host

        $global:CaptureSuccess = $false
        $null
        return
    }

    try {
        # STEP 1: Read firmware from existing logs (silent, automatic)
        $tempFirmwareMap = @{}
        $needsDetection = @()

        foreach ($portName in $availablePorts) {
            $firmwareFromLog = Get-FirmwareFromExistingLogs -ComPort $portName -MaxFileAgeMinutes 60

            if ($firmwareFromLog -and $firmwareFromLog.Detected) {
                $tempFirmwareMap[$portName] = $firmwareFromLog
            } else {
                $needsDetection += $portName
            }
        }

        # STEP 2: Detect firmware from running devices (automatic, no prompt)
        if ($needsDetection.Count -gt 0) {
            foreach ($portName in $needsDetection) {
                try {
                    $detectPort = New-Object System.IO.Ports.SerialPort($portName, 115200, "None", 8, "One")
                    $detectPort.Open()

                    # Give device time to respond and send any pending data
                    Start-Sleep -Milliseconds 1000

                    # Try to detect firmware from running device
                    $firmwareFromDevice = Get-TempFirmwareDetection -Port $detectPort -ComPort $portName -TimeoutSeconds 8
                    $tempFirmwareMap[$portName] = $firmwareFromDevice

                    if (-not $firmwareFromDevice.Detected) {
                        $tempFirmwareMap[$portName] = @{
                            Firmware = "Unknown"
                            Branch = "Unknown"
                            Detected = $false
                        }
                    }

                    $detectPort.Close()
                }
                catch {
                    $tempFirmwareMap[$portName] = @{
                        Firmware = "Unknown"
                        Branch = "Unknown"
                        Detected = $false
                    }
                }
            }
        }

        # Display all ports with firmware (single consolidated view)
        foreach ($portName in $availablePorts) {
            if ($tempFirmwareMap.ContainsKey($portName) -and $tempFirmwareMap[$portName].Detected) {
                $fw = $tempFirmwareMap[$portName]
                Write-Host "  $portName  " -ForegroundColor Gray -NoNewline
                Write-Host "$($fw.Firmware)+$($fw.Branch)" -ForegroundColor White
            } else {
                Write-Host "  $portName  " -ForegroundColor Gray -NoNewline
                Write-Host "(firmware unknown)" -ForegroundColor Yellow
            }
        }
        Write-Host ""

        # STEP 3: Reset devices if not skipped (AFTER firmware detection)
        if (-not $SkipReset) {
            Write-Host "Resetting devices..." -ForegroundColor DarkGray -NoNewline
            foreach ($portName in $availablePorts) {
                try {
                    $tempPort = New-Object System.IO.Ports.SerialPort($portName, 115200, "None", 8, "One")
                    $tempPort.Open()
                    $tempPort.DtrEnable = $true
                    Start-Sleep -Milliseconds 100
                    $tempPort.DtrEnable = $false
                    Start-Sleep -Milliseconds 500
                    $tempPort.Close()
                }
                catch {
                    Write-Host ""
                    Write-Host "  WARNING: Could not reset $portName" -ForegroundColor Yellow
                }
            }
            Write-Host " waiting for restart..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 3
            Write-Host ""
        }

        # STEP 4: Open all ports to monitor for button presses
        $testPorts = @()
        $portMap = @{}

        foreach ($portName in $availablePorts) {
            try {
                $testPort = New-Object System.IO.Ports.SerialPort($portName, 115200, "None", 8, "One")
                $testPort.Open()
                $testPorts += $testPort
                $portMap[$portName] = $testPort
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
        Write-Host "[ LEFT  ]  Hold a button for 2+ seconds..." -ForegroundColor Yellow

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
                            Write-Host "           LEFT  ->  $leftPort" -ForegroundColor Green

                            # Save DEFINITIVE association (COM → firmware) to cache (only if valid)
                            if ($tempFirmwareMap.ContainsKey($leftPort)) {
                                $leftFirmware = $tempFirmwareMap[$leftPort]
                                if ($leftFirmware.Firmware -ne "Unknown" -and $leftFirmware.Firmware -ne "unknown") {
                                    Save-FirmwareCache -ComPort $leftPort -Firmware $leftFirmware.Firmware -Branch $leftFirmware.Branch
                                }
                            }

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
        Write-Host "[ RIGHT ]  Hold a button for 2+ seconds..." -ForegroundColor Yellow

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
                            Write-Host "           RIGHT ->  $rightPort" -ForegroundColor Green

                            # Save DEFINITIVE association (COM → firmware) to cache (only if valid)
                            if ($tempFirmwareMap.ContainsKey($rightPort)) {
                                $rightFirmware = $tempFirmwareMap[$rightPort]
                                if ($rightFirmware.Firmware -ne "Unknown" -and $rightFirmware.Firmware -ne "unknown") {
                                    Save-FirmwareCache -ComPort $rightPort -Firmware $rightFirmware.Firmware -Branch $rightFirmware.Branch
                                }
                            }

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

        # Book selection
        Write-Host "  LEFT  ($leftPort)  [1=ORIGINAL  2=OPTIMIZED  3=Custom]: " -ForegroundColor White -NoNewline
        $choiceA = Read-Host
        switch ($choiceA) {
            "1" { $bookA = "ORIGINAL" }
            "2" { $bookA = "OPTIMIZED" }
            "3" { $bookA = Read-Host "  Custom name for LEFT" }
            default { $bookA = "UNKNOWN" }
        }

        Write-Host "  RIGHT ($rightPort)  [1=ORIGINAL  2=OPTIMIZED  3=Custom]: " -ForegroundColor White -NoNewline
        $choiceB = Read-Host
        switch ($choiceB) {
            "1" { $bookB = "ORIGINAL" }
            "2" { $bookB = "OPTIMIZED" }
            "3" { $bookB = Read-Host "  Custom name for RIGHT" }
            default { $bookB = "UNKNOWN" }
        }

        Write-Host ""
        Write-Host ""
        Write-Host "  LEFT  ($leftPort)  $bookA" -ForegroundColor Green
        Write-Host "  RIGHT ($rightPort)  $bookB" -ForegroundColor Green
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
        Write-Host "Press ENTER para comenzar a capturar..." -ForegroundColor Yellow
        Read-Host

        Clear-Host
        Write-Host ""
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  CAPTURING" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Opening ports..." -ForegroundColor Cyan

        $captureSuccess = $false
        try {
            $portA = New-Object System.IO.Ports.SerialPort($leftPort, 115200, "None", 8, "One")
            $portB = New-Object System.IO.Ports.SerialPort($rightPort, 115200, "None", 8, "One")

            $portA.Open()
            $portB.Open()
            Write-Host "  Ports opened" -ForegroundColor Green

            # Get firmware info from temp detection map (already detected before reset)
            if ($tempFirmwareMap.ContainsKey($leftPort)) {
                $fwA = $tempFirmwareMap[$leftPort]
                $firmwareVersionA = $fwA.Firmware
                $firmwareBranchA = $fwA.Branch
            } else {
                $firmwareVersionA = "Unknown"
                $firmwareBranchA = "Unknown"
            }

            if ($tempFirmwareMap.ContainsKey($rightPort)) {
                $fwB = $tempFirmwareMap[$rightPort]
                $firmwareVersionB = $fwB.Firmware
                $firmwareBranchB = $fwB.Branch
            } else {
                $firmwareVersionB = "Unknown"
                $firmwareBranchB = "Unknown"
            }

            # Create writers and write metadata
            $writerA = New-Object System.IO.StreamWriter($fileA, $false, [System.Text.Encoding]::UTF8)
            $writerB = New-Object System.IO.StreamWriter($fileB, $false, [System.Text.Encoding]::UTF8)
            $writerA.AutoFlush = $true
            $writerB.AutoFlush = $true

            # Write metadata headers
            $firmwareCombinedA = "${firmwareVersionA}+${firmwareBranchA}"
            $metadataA = "CAPTURE_METADATA: Type=${sanitizedBookA}, Device=$leftPort, Timestamp=${timestamp}, Firmware+Branch=${firmwareCombinedA}"
            $writerA.WriteLine($metadataA)

            $firmwareCombinedB = "${firmwareVersionB}+${firmwareBranchB}"
            $metadataB = "CAPTURE_METADATA: Type=${sanitizedBookB}, Device=$rightPort, Timestamp=${timestamp}, Firmware+Branch=${firmwareCombinedB}"
            $writerB.WriteLine($metadataB)

            Write-Host ""
            Write-Host "[Capturing... Press ESC or Q to stop]" -ForegroundColor Green
            Write-Host ""

            $countA = 0
            $countB = 0
            $pagesDetectedA = 0
            $pagesDetectedB = 0
            $coverStatusA = $null
            $coverStatusB = $null
            $lastDot = Get-Date
            $stopRequested = $false

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
                    # Write directly to file (metadata already written)
                    $writerA.Write($data)

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
                    # Write directly to file (metadata already written)
                    $writerB.Write($data)

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
        FirmwareBranch = "Unknown"
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

    # Extract firmware+branch from CAPTURE_METADATA line
    if (Test-Path $FilePath) {
        try {
            $firstLine = Get-Content $FilePath -First 1
            if ($firstLine -match 'CAPTURE_METADATA:.*Firmware\+Branch=([^\s]+)') {
                $result.FirmwareBranch = $matches[1]
            }
        } catch {
            # Keep default value if file can't be read
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

# Write a string coloring every [!] token in red, rest in $Color
function Write-WithWarning {
    param([string]$Text, [string]$Color = "White", [switch]$NoNewline)
    $parts = $Text -split '(\[!\])'
    foreach ($part in $parts) {
        if ($part -eq '[!]') {
            Write-Host $part -ForegroundColor Red -NoNewline
        } elseif ($part -ne '') {
            Write-Host $part -ForegroundColor $Color -NoNewline
        }
    }
    if (-not $NoNewline) { Write-Host "" }
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

        # Extract epub path and folder from "Loading ePub:" log line
        # e.g. "[DBG] [EBP] Loading ePub: /01 - Original/orig-01-txt-only/Book.epub"
        $epubPath   = $null
        $epubFolder = $null
        $loadingLine = Get-Content $log.Path | Where-Object { $_ -match '\[EBP\]\s+Loading ePub:' } | Select-Object -First 1
        if ($loadingLine -and $loadingLine -match 'Loading ePub:\s+(.+)$') {
            $epubPath   = $matches[1].Trim()
            # Extract immediate parent folder (e.g. "orig-01-txt-only")
            $epubFolder = ($epubPath -split '/' | Select-Object -Last 2 | Select-Object -First 1).Trim()
        }
        $log | Add-Member -MemberType NoteProperty -Name "EpubPath"   -Value $epubPath   -Force
        $log | Add-Member -MemberType NoteProperty -Name "EpubFolder" -Value $epubFolder -Force

        $logsWithTimes += $log

        # Display summary for this log
        $summary = "$($times.Count) pages, $totalImages images"
        if ($coverTime) {
            $coverStatus = if ($coverTime.Success) { "SUCCESS" } else { "FAILED" }
            $summary += " + cover ($coverStatus)"
        }
        Write-Host "  $($log.Port) ($($log.Type)): $summary" -ForegroundColor Gray
        Write-Host "     Firmware: $($log.FirmwareBranch)" -ForegroundColor DarkGray
    }

    Write-Host ""

    # IMPORTANT WARNING about image loading fairness
    Write-WithWarning "[!] COMPARISON FAIRNESS WARNING" "Yellow"
    Write-Host "  This analysis compares render times, but does NOT verify if all images" -ForegroundColor Yellow
    Write-Host "  loaded successfully. A faster time may indicate MISSING or FAILED images." -ForegroundColor Yellow
    Write-WithWarning "  Pages with missing images will be marked with '[!]' in the Winner column." "Yellow"
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

        # Always use A/B for columns, winner labels, and image columns
        $useAliases  = $true
        $colA        = "A_ms";   $colB        = "B_ms"
        $displayColA = "A_ms";   $displayColB = "B_ms"
        $winnerA     = "A";      $winnerB     = "B"
        $imgColA     = "A_img";  $imgColB     = "B_img"

        # Short display names used in all sections below
        # Rule: type only; add port if same type; Test1/Test2 if same type+port
        if ($logA.Port -eq $logB.Port -and $logA.Type -eq $logB.Type) {
            $shortNameA = "Test1"; $shortNameB = "Test2"
        } elseif ($logA.Type -eq $logB.Type) {
            $shortNameA = "$($logA.Type) ($($logA.Port))"; $shortNameB = "$($logB.Type) ($($logB.Port))"
        } else {
            $shortNameA = $logA.Type; $shortNameB = $logB.Type
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
            $diff = $timeB - $timeA
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

            # Mark page label with [!] whenever there is any image discrepancy
            if ($hasImageDiscrepancy -and $row.Page -notlike "*Cover*") {
                $row.Page = "$($row.Page) [!]"
            }

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
                $winner = $winnerB
            } elseif ($diff -gt 0) {
                $winner = $winnerA
            } else {
                $winner = "TIE"
            }

            # Determine column names for images based on comparison type
            # If comparing different book types (ORIGINAL vs OPTIMIZED), use TYPE
            # If comparing same book on different devices, use DEVICE/PORT
            # If comparing same device and book, use TEST1/TEST2
            if ($useAliases) {
                # Custom type names = use short A/B aliases
                $imagesColA = "A_img"
                $imagesColB = "B_img"
            } elseif ($uniqueTypes -gt 1) {
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

            # Add [!] only when misleading: winner did less work (failed cover or fewer images)
            if (($hasImageDiscrepancy -or $hasCoverMismatch) -and $winner -ne "TIE") {
                $isMisleadingWinner = if ($winner -eq $winnerA) {
                    $imagesA -lt $imagesB  # A won but had fewer images
                } else {
                    $imagesB -lt $imagesA  # B won but had fewer images
                }
                if ($isMisleadingWinner) {
                    $winner = "$winner [!]"
                }
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

        # Determine comparison title (display names reuse $shortNameA/B)
        if ($uniqueTypes -gt 1) {
            $comparisonTitle = "Book Version"
        } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
            $comparisonTitle = "Same Device Repeatability Test"
        } else {
            $comparisonTitle = "Device Performance"
        }
        $displayNameA = $shortNameA
        $displayNameB = $shortNameB

        Write-Host "${comparisonTitle}: " -ForegroundColor Yellow -NoNewline
        Write-Host "${displayNameA}" -ForegroundColor Green -NoNewline
        Write-Host " vs " -ForegroundColor Yellow -NoNewline
        Write-Host "${displayNameB}" -ForegroundColor Blue
        if ($useAliases) {
            Write-Host "  A = ${displayNameA}" -ForegroundColor DarkGreen
            Write-Host "  B = ${displayNameB}" -ForegroundColor DarkBlue
        }
        Write-Host ""
    }

    # Display table with color coding
    if ($comparison.Count -gt 0 -and $logsWithTimes.Count -eq 2) {
        # Build ordered properties
        $allProperties = $comparison[0].PSObject.Properties.Name
        $imageCols = $allProperties | Where-Object { ($_ -like "Images_*" -or $_ -like "*_img") -and $_ -notlike "*CoverSuccess" }
        $orderedProperties = @("Page", $colA, $colB) + $imageCols + @("Diff_ms", "Percent", "Winner")

        # Calculate column widths
        $colWidths = @{}
        foreach ($prop in $orderedProperties) {
            $maxLen = $prop.Length
            foreach ($row in $comparison) {
                $pv = $row.PSObject.Properties[$prop]
                if ($null -ne $pv -and $null -ne $pv.Value) {
                    $len = $pv.Value.ToString().Length
                    if ($len -gt $maxLen) { $maxLen = $len }
                }
            }
            $colWidths[$prop] = $maxLen
        }

        $rightAlignedCols = @($colA, $colB, $imgColA, $imgColB, "Diff_ms", "Percent")

        # Print header row
        foreach ($prop in $orderedProperties) {
            $color = if ($prop -eq $colA -or $prop -eq $imgColA) { "Green" }
                     elseif ($prop -eq $colB -or $prop -eq $imgColB) { "Blue" }
                     else { "White" }
            $w = $colWidths[$prop]
            $fmt = if ($rightAlignedCols -contains $prop) { "{0,$w}" } else { "{0,-$w}" }
            Write-Host ($fmt -f $prop) -ForegroundColor $color -NoNewline
            Write-Host "  " -NoNewline
        }
        Write-Host ""

        # Print separator
        foreach ($prop in $orderedProperties) {
            $w = $colWidths[$prop]
            $fmt = if ($rightAlignedCols -contains $prop) { "{0,$w}" } else { "{0,-$w}" }
            Write-Host ($fmt -f ("-" * $w)) -NoNewline
            Write-Host "  " -NoNewline
        }
        Write-Host ""

        # Print data rows
        foreach ($row in $comparison) {
            foreach ($prop in $orderedProperties) {
                $pv = $row.PSObject.Properties[$prop]
                $strVal = if ($null -ne $pv -and $null -ne $pv.Value) { $pv.Value.ToString() } else { "" }
                $width = $colWidths[$prop]
                $fmt = if ($rightAlignedCols -contains $prop) { "{0,$width}" } else { "{0,-$width}" }

                if ($prop -eq $colA -or $prop -eq $imgColA) {
                    $color = "Green"
                } elseif ($prop -eq $colB -or $prop -eq $imgColB) {
                    $color = "Blue"
                } elseif ($prop -eq "Winner") {
                    $bare = $strVal -replace " \[!\]", ""
                    $color = if ($bare -eq "TIE") { "Gray" }
                             elseif ($bare -eq $winnerA) { "Green" }
                             elseif ($bare -eq $winnerB) { "Blue" }
                             else { "White" }
                } else {
                    $color = "White"
                }

                if ($strVal -like "*[!]*") {
                    Write-WithWarning ($fmt -f $strVal) $color -NoNewline
                } else {
                    Write-Host ($fmt -f $strVal) -ForegroundColor $color -NoNewline
                }
                Write-Host "  " -NoNewline
            }
            Write-Host ""
        }
    } elseif ($comparison.Count -gt 0) {
        # Fallback for non-2-log comparisons
        $comparison | Format-Table -AutoSize
    }

    # Add Legend for 2-log comparison
    if ($logsWithTimes.Count -eq 2) {

        # Column legend
        Write-Host ""
        Write-Host "Legend:" -ForegroundColor Cyan
        if ($useAliases) {
            $legendW = "TIE".Length  # = 3
            Write-Host "  - $("A".PadRight($legendW)): ${displayNameA} is faster" -ForegroundColor Green
            Write-Host "  - $("B".PadRight($legendW)): ${displayNameB} is faster" -ForegroundColor Blue
        } else {
            $legendW = "Test1".Length  # = 5
            Write-Host "  - $("Test1".PadRight($legendW)): ${displayNameA} is faster" -ForegroundColor Green
            Write-Host "  - $("Test2".PadRight($legendW)): ${displayNameB} is faster" -ForegroundColor Blue
        }
        Write-Host "  - TIE: When the difference is < 1% (statistically insignificant)" -ForegroundColor Gray
        Write-Host ""

        # Image discrepancy warning
        $pagesWithWarnings = $comparison | Where-Object { $_.Winner -like "*[!]*" }

        # Summary
        $aWins = 0
        $bWins = 0
        $ties = 0

        foreach ($row in $comparison) {
            $bareWinner = $row.Winner -replace " \[!\]", ""
            if ($bareWinner -eq $winnerA) { $aWins++ }
            elseif ($bareWinner -eq $winnerB) { $bWins++ }
            elseif ($bareWinner -eq "TIE") { $ties++ }
        }

        Write-Host "Summary:" -ForegroundColor Cyan

        $summaryNameA = $shortNameA
        $summaryNameB = $shortNameB

        # Calculate widths for two-column alignment: label: {n} unit
        $labelWidth = [Math]::Max($summaryNameA.Length, [Math]::Max($summaryNameB.Length, "Ties".Length))
        $numWidth   = [Math]::Max("$aWins".Length, [Math]::Max("$bWins".Length, "$ties".Length))

        Write-Host "  $($summaryNameA.PadRight($labelWidth)): $("$aWins".PadLeft($numWidth)) wins"  -ForegroundColor Green
        Write-Host "  $($summaryNameB.PadRight($labelWidth)): $("$bWins".PadLeft($numWidth)) wins"  -ForegroundColor Blue
        Write-Host "  $("Ties".PadRight($labelWidth)): $("$ties".PadLeft($numWidth)) pages" -ForegroundColor Gray
        Write-Host ""

        # Aggregate cover and image counts
        $covSuccessA = 0; $covFailedA = 0
        $covSuccessB = 0; $covFailedB = 0
        $imgSuccessA = 0; $imgFailedA = 0
        $imgSuccessB = 0; $imgFailedB = 0
        foreach ($page in ($comparison | Where-Object { $_.Page -like "*Cover*" })) {
            $csA = $page."${colA}_CoverSuccess"
            $csB = $page."${colB}_CoverSuccess"
            if ($csA) { $covSuccessA++ } else { $covFailedA++ }
            if ($csB) { $covSuccessB++ } else { $covFailedB++ }
        }
        foreach ($page in ($comparison | Where-Object { $_.Page -notlike "*Cover*" -and ([int]$_.$imgColA -gt 0 -or [int]$_.$imgColB -gt 0) })) {
            if ([int]$page.$imgColA -gt 0) { $imgSuccessA++ } else { $imgFailedA++ }
            if ([int]$page.$imgColB -gt 0) { $imgSuccessB++ } else { $imgFailedB++ }
        }

        if ($pagesWithWarnings) {
            Write-WithWarning "[!] UNFAIR COMPARISONS DETECTED:" "Red"
        }

        $labelW = [Math]::Max("Cover ".Length, "Images".Length)
        $covStatusA = if ($covSuccessA -gt 0) { "Success" } else { "Failed" }
        $covStatusB = if ($covSuccessB -gt 0) { "Success" } else { "Failed" }
        $covLeft  = "  $("Cover".PadRight($labelW)): $shortNameA $covStatusA"
        $imgLeft  = "  $("Images".PadRight($labelW)): $shortNameA Success: $imgSuccessA, Failed: $imgFailedA"
        $pipeCol  = [Math]::Max($covLeft.Length, $imgLeft.Length)
        if (($covSuccessA + $covFailedA) -gt 0) {
            Write-Host "$($covLeft.PadRight($pipeCol))  |  $shortNameB $covStatusB" -ForegroundColor Yellow
        }
        if (($imgSuccessA + $imgFailedA) -gt 0) {
            Write-Host "$($imgLeft.PadRight($pipeCol))  |  $shortNameB Success: $imgSuccessB, Failed: $imgFailedB" -ForegroundColor Yellow
        }
        if ($pagesWithWarnings) {
            Write-Host "  If the winner failed to generate images or cover, the result may not represent true performance!" -ForegroundColor Red
        }
        if ($pagesWithWarnings -or ($covSuccessA + $covFailedA) -gt 0 -or ($imgSuccessA + $imgFailedA) -gt 0) {
            Write-Host ""
        }

        # Comparative averages
        $avgA = ($comparison | ForEach-Object { $_.$colA } | Measure-Object -Average).Average
        $avgB = ($comparison | ForEach-Object { $_.$colB } | Measure-Object -Average).Average
        $avgDiff = $avgA - $avgB
        $avgPercent = if ($avgA -gt 0) { [Math]::Round(($avgDiff / $avgA) * 100, 1) } else { 0 }

        $avgAStr = "$([Math]::Round($avgA, 0))"
        $avgBStr = "$([Math]::Round($avgB, 0))"
        $avgNumWidth = [Math]::Max($avgAStr.Length, $avgBStr.Length)

        Write-Host "Averages:" -ForegroundColor Cyan
        Write-Host "  $($summaryNameA.PadRight($labelWidth)): $($avgAStr.PadLeft($avgNumWidth)) ms" -ForegroundColor Green
        Write-Host "  $($summaryNameB.PadRight($labelWidth)): $($avgBStr.PadLeft($avgNumWidth)) ms" -ForegroundColor Blue
        Write-Host ""

        $resultNameA = $shortNameA
        $resultNameB = $shortNameB

        # [!] if the overall winner has any unfair pages
        $resultWinner = if ($avgDiff -lt 0) { $winnerA } else { $winnerB }
        $resultHasUnfair = $pagesWithWarnings | Where-Object { ($_.Winner -replace " \[!\]", "") -eq $resultWinner }
        $resultWarning = if ($resultHasUnfair) { " [!]" } else { "" }

        # Check if difference is statistically significant (> 1%)
        if ([Math]::Abs($avgPercent) -lt 1) {
            Write-Host "  Result: TIE (statistically insignificant difference: $([Math]::Round([Math]::Abs($avgDiff), 1)) ms, $([Math]::Abs($avgPercent))%)" -ForegroundColor Yellow
        } elseif ($avgDiff -lt 0) {
            Write-WithWarning "  Result: $resultNameA is $([Math]::Round([Math]::Abs($avgDiff), 1)) ms faster than $resultNameB ($([Math]::Abs($avgPercent))%)$resultWarning" "Green"
        } elseif ($avgDiff -gt 0) {
            Write-WithWarning "  Result: $resultNameB is $([Math]::Round([Math]::Abs($avgDiff), 1)) ms faster than $resultNameA ($([Math]::Abs($avgPercent))%)$resultWarning" "Blue"
        } else {
            Write-Host "  Result: TIE (equal performance)" -ForegroundColor Yellow
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

        $displayNameA = $shortNameA
        $displayNameB = $shortNameB

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

        $consistencyNameA = $shortNameA
        $consistencyNameB = $shortNameB

        $cvLabelWidth = [Math]::Max($consistencyNameA.Length, $consistencyNameB.Length)

        Write-Host ""
        Write-Host "Consistency Analysis:" -ForegroundColor Cyan
        Write-Host "  $($consistencyNameA.PadRight($cvLabelWidth)): Coef. of Variation = $([Math]::Round($cvA, 1))%" -ForegroundColor $(if ($cvA -lt 20) { "Green" } elseif ($cvA -lt 40) { "Yellow" } else { "Red" })
        Write-Host "  $($consistencyNameB.PadRight($cvLabelWidth)): Coef. of Variation = $([Math]::Round($cvB, 1))%" -ForegroundColor $(if ($cvB -lt 20) { "Green" } elseif ($cvB -lt 40) { "Yellow" } else { "Red" })
        Write-Host ""
    }

    # Optimization Impact / Performance Highlights (for 2-log comparisons only)
    if ($logsWithTimes.Count -eq 2) {
        $displayNameA = $shortNameA
        $displayNameB = $shortNameB
        if ($uniqueTypes -gt 1) {
            $sectionTitle = "Optimization Impact"

            # Diff = B - A: most negative = B improved most, most positive = B regressed most
            $mostImproved  = $comparison | Sort-Object -Property Diff_ms           | Select-Object -First 1
            $leastImproved = $comparison | Sort-Object -Property Diff_ms -Descending | Select-Object -First 1

            # Extract numeric percentage from string (e.g., "-92.6%" -> -92.6)
            $mostImprovedPercent  = [double]($mostImproved.Percent  -replace '%', '')
            $leastImprovedPercent = [double]($leastImproved.Percent -replace '%', '')

            # Positive diff = A won = B got worse
            $gotWorse = $leastImproved.Diff_ms -gt 0

            Write-Host "${sectionTitle}:" -ForegroundColor Cyan

            # Determine if [!] is misleading: winner did less work (failed cover or fewer images)
            # Most improved: B won (most negative diff)
            if ($mostImproved.Page -like "Cover*" -and $logB.CoverGenerationTime) {
                $mostIsMisleading = -not $logB.CoverGenerationTime.Success  # misleading if B (winner) failed
            } else {
                $mostIsMisleading = [int]$mostImproved.$imgColB -lt [int]$mostImproved.$imgColA
            }

            # Regression: A won (most positive diff)
            if ($leastImproved.Page -like "Cover*" -and $logA.CoverGenerationTime) {
                $leastIsMisleading = -not $logA.CoverGenerationTime.Success  # misleading if A (winner) failed
            } else {
                $leastIsMisleading = [int]$leastImproved.$imgColA -lt [int]$leastImproved.$imgColB
            }

            $impactLabelW = "Least improved".Length  # = 14, widest label

            # Most improved: B had the most negative diff
            $pageDisplay = if ($mostImproved.Page -like "Cover*") { if ($mostIsMisleading) { "Cover [!]" } else { "Cover" } } else { "Page $($mostImproved.Page)" }
            if ([Math]::Abs($mostImprovedPercent) -gt 1) {
                $warningText = if ($mostIsMisleading) { " [!]" } else { "" }
                Write-WithWarning "  $("Most improved".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $([Math]::Abs($mostImproved.Diff_ms))ms faster ($($mostImproved.Percent))$warningText" "Green"
            } else {
                Write-Host "  $("Most improved".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $([Math]::Abs($mostImproved.Diff_ms))ms faster ($($mostImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
            }

            # Worst case for B: regression or least improved
            $pageDisplay = if ($leastImproved.Page -like "Cover*") { if ($leastIsMisleading) { "Cover [!]" } else { "Cover" } } else { "Page $($leastImproved.Page)" }
            if ($gotWorse -and $leastImprovedPercent -gt 1) {
                $warningText = if ($leastIsMisleading) { " [!]" } else { "" }
                Write-WithWarning "  $("Regression".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $($leastImproved.Diff_ms)ms SLOWER ($($leastImproved.Percent))$warningText" "Red"
            } elseif ($gotWorse) {
                Write-Host "  $("Regression".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $($leastImproved.Diff_ms)ms slower ($($leastImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
            } else {
                Write-Host "  $("Least improved".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is only $([Math]::Abs($leastImproved.Diff_ms))ms faster ($($leastImproved.Percent))" -ForegroundColor Yellow
            }
        } else {
            # Same book type: Device comparison
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

            Write-WithWarning "  Best performer:  Page $($bestCase.Page) ($displayNameA) faster by $($bestCase.Diff_ms)ms ($($bestCase.Percent))$bestWarningText" "Green"
            Write-WithWarning "  Worst performer: Page $($worstCase.Page) ($displayNameB) faster by $($worstCase.Diff_ms)ms ($($worstCase.Percent))$worstWarningText" $(if ([Math]::Abs($worstCase.Diff_ms) -gt 1000) { "Red" } else { "Yellow" })

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

        $displayNameA = $shortNameA
        $displayNameB = $shortNameB

        Write-Host "Total Performance:" -ForegroundColor Cyan

        # Calculate label widths for alignment
        $label1 = "Total render time ${displayNameA}"
        $label2 = "Total render time ${displayNameB}"
        $label3 = "Time saved"
        $label4 = "Pages analyzed"

        $maxLabelWidth = [Math]::Max($label1.Length, [Math]::Max($label2.Length, [Math]::Max($label3.Length, $label4.Length)))

        # Check if the overall winner's advantage may be unfair:
        # Only flag [!] if the winner had fewer images/failed cover on [!] pages
        # (if the loser failed, the winner's advantage is conservative, not misleading)
        $hasUnfairComparisonInOptimization = $false
        $pagesWithWarnings = $comparison | Where-Object { $_.Winner -like "*[!]*" }
        foreach ($wPage in $pagesWithWarnings) {
            $pageWinner = ($wPage.Winner -replace " \[!\]", "")
            $overallWinnerWonThisPage = ($totalTimeSaved -lt 0 -and $pageWinner -eq $winnerA) -or
                                        ($totalTimeSaved -gt 0 -and $pageWinner -eq $winnerB)
            if ($overallWinnerWonThisPage) {
                $imgAval = $wPage.PSObject.Properties[$imgColA]
                $imgBval = $wPage.PSObject.Properties[$imgColB]
                $imgA = if ($null -ne $imgAval) { [int]$imgAval.Value } else { 0 }
                $imgB = if ($null -ne $imgBval) { [int]$imgBval.Value } else { 0 }
                # Winner had fewer images = potentially unfair advantage
                if (($totalTimeSaved -lt 0 -and $imgA -lt $imgB) -or
                    ($totalTimeSaved -gt 0 -and $imgB -lt $imgA)) {
                    $hasUnfairComparisonInOptimization = $true
                }
            }
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
                    Write-WithWarning "  $($label3.PadRight($maxLabelWidth)): $($timeSaved_formatted) ($percentSaved%) - $displayNameA is faster$unfairMarker" "Green"
                } else {
                    Write-WithWarning "  $($label3.PadRight($maxLabelWidth)): $($timeSaved_formatted) ($percentSaved%) - $displayNameB is faster$unfairMarker" "Green"
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

    # Export to JSON (2-log comparisons only - includes full metadata)
    if ($logsWithTimes.Count -eq 2) {
        # Parse firmware and branch from "1.1.1-dev+master" format
        $fwPartsA = $logA.FirmwareBranch -split '\+', 2
        $fwPartsB = $logB.FirmwareBranch -split '\+', 2

        # Determine comparison type string
        $compType = if ($useAliases) { "custom" }
                    elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) { "repeatability" }
                    elseif ($uniqueTypes -gt 1) { "book_type" }
                    else { "device" }

        # Clean book name for display
        $cleanBook = ($logA.BookName -replace '\.epub(_\d{8}(_\d{6})?)?$', '') -replace '_+', ' '

        $jsonMeta = [ordered]@{
            timestamp       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            book            = $cleanBook.Trim()
            comparison_type = $compType
            a = [ordered]@{
                label       = $logA.Type
                port        = $logA.Port
                firmware    = if ($fwPartsA.Count -gt 0) { $fwPartsA[0] } else { $logA.FirmwareBranch }
                branch      = if ($fwPartsA.Count -gt 1) { $fwPartsA[1] } else { "unknown" }
                log_file    = Split-Path $logA.Path -Leaf
                epub_path   = $logA.EpubPath
                epub_folder = $logA.EpubFolder
            }
            b = [ordered]@{
                label       = $logB.Type
                port        = $logB.Port
                firmware    = if ($fwPartsB.Count -gt 0) { $fwPartsB[0] } else { $logB.FirmwareBranch }
                branch      = if ($fwPartsB.Count -gt 1) { $fwPartsB[1] } else { "unknown" }
                log_file    = Split-Path $logB.Path -Leaf
                epub_path   = $logB.EpubPath
                epub_folder = $logB.EpubFolder
            }
        }

        $jsonSummary = [ordered]@{
            total_pages      = $comparison.Count
            a_wins           = $aWins
            b_wins           = $bWins
            ties             = $ties
            total_time_a_ms  = [int]$totalTimeA
            total_time_b_ms  = [int]$totalTimeB
            avg_a_ms         = [Math]::Round($avgA, 1)
            avg_b_ms         = [Math]::Round($avgB, 1)
            avg_diff_ms      = [Math]::Round($avgB - $avgA, 1)
            avg_diff_percent = if ($avgA -gt 0) { [Math]::Round((($avgB - $avgA) / $avgA) * 100, 1) } else { 0 }
            has_unfair_pages = [bool]($comparison | Where-Object { $_.Winner -like "*[!]*" })
        }

        $jsonPages = @()
        foreach ($row in $comparison) {
            $bareWinner = $row.Winner -replace " \[!\]", ""
            $isUnfair   = $row.Winner -like "*[!]*"

            $pageObj = [ordered]@{
                page         = $row.Page
                a_ms         = [int]$row.$colA
                b_ms         = [int]$row.$colB
                a_images     = [int]$row.$imgColA
                b_images     = [int]$row.$imgColB
                diff_ms      = [int]$row.Diff_ms
                diff_percent = [double]($row.Percent -replace '%', '')
                winner       = $bareWinner
                unfair       = $isUnfair
            }

            # Add cover success only for the Cover row
            $csA = $row.PSObject.Properties["${colA}_CoverSuccess"]
            $csB = $row.PSObject.Properties["${colB}_CoverSuccess"]
            if ($null -ne $csA -and $csA.Value -ne $null -and $csA.Value -ne '') {
                $pageObj.a_cover_success = [bool]$csA.Value
                $pageObj.b_cover_success = [bool]$csB.Value
            }

            $jsonPages += $pageObj
        }

        $jsonOutput = [ordered]@{
            meta    = $jsonMeta
            summary = $jsonSummary
            pages   = $jsonPages
        }

        $jsonFile = $outputFile -replace '\.csv$', '.json'
        $jsonOutput | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-Host "JSON exported: $jsonFile" -ForegroundColor Green

        # ── Markdown report ──────────────────────────────────────────────────
        $md = [System.Text.StringBuilder]::new()

        # Header
        $null = $md.AppendLine("# EPUB Optimization Benchmark Report")
        $null = $md.AppendLine("")

        # Metadata table
        $null = $md.AppendLine("## Comparison")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| | Label | Firmware | Branch | Port |")
        $null = $md.AppendLine("|---|---|---|---|---|")
        $branchA = if ($fwPartsA.Count -gt 1) { $fwPartsA[1] } else { 'unknown' }
        $branchB = if ($fwPartsB.Count -gt 1) { $fwPartsB[1] } else { 'unknown' }
        $null = $md.AppendLine("| **A** | $($logA.Type) | $($fwPartsA[0]) | $branchA | $($logA.Port) |")
        $null = $md.AppendLine("| **B** | $($logB.Type) | $($fwPartsB[0]) | $branchB | $($logB.Port) |")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("**Book:** $($cleanBook.Trim())  ")
        $null = $md.AppendLine("**Date:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ")
        $null = $md.AppendLine("**Type:** $compType  ")
        $null = $md.AppendLine("")

        # Unfair pages warning (if any)
        $unfairPages = $comparison | Where-Object { $_.Winner -like "*[!]*" }
        if ($unfairPages) {
            $null = $md.AppendLine("> [!WARNING]")
            $null = $md.AppendLine("> Pages marked with [!] have content discrepancies (different image counts or cover generation results).")
            $null = $md.AppendLine("> - If the **winner** had fewer images/failed cover: result may be **misleading** (did less work)")
            $null = $md.AppendLine("> - If the **loser** had fewer images/failed cover: result is **conservative** (winner did more work and still won)")
            $null = $md.AppendLine("")
        }

        # Render time table
        $null = $md.AppendLine("## Render Time Comparison")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Page | A_ms | B_ms | A_img | B_img | Diff_ms | Percent | Winner |")
        $null = $md.AppendLine("|------|-----:|-----:|------:|------:|--------:|--------:|--------|")

        foreach ($row in $comparison) {
            $w = $row.Winner -replace " \[!\]", ""
            $flag = if ($row.Winner -like "*[!]*") { " [!]" } else { "" }
            $winnerMd = switch ($w) {
                "TIE" { "TIE" }
                $winnerA { "**A**$flag" }
                $winnerB { "**B**$flag" }
                default { $w }
            }
            $imgA = $row.PSObject.Properties[$imgColA]; $imgAv = if ($null -ne $imgA) { $imgA.Value } else { "" }
            $imgB = $row.PSObject.Properties[$imgColB]; $imgBv = if ($null -ne $imgB) { $imgB.Value } else { "" }
            $null = $md.AppendLine("| $($row.Page) | $($row.$colA) | $($row.$colB) | $imgAv | $imgBv | $($row.Diff_ms) | $($row.Percent) | $winnerMd |")
        }
        $null = $md.AppendLine("")

        # Summary
        $null = $md.AppendLine("## Summary")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Metric | Value |")
        $null = $md.AppendLine("|--------|------:|")
        $null = $md.AppendLine("| A wins ($($logA.Type)) | $aWins |")
        $null = $md.AppendLine("| B wins ($($logB.Type)) | $bWins |")
        $null = $md.AppendLine("| Ties | $ties |")
        $null = $md.AppendLine("| Total pages analyzed | $($comparison.Count) |")
        $null = $md.AppendLine("")

        # Total Performance
        $null = $md.AppendLine("## Performance")
        $null = $md.AppendLine("")
        $timeA_s = [Math]::Round($totalTimeA / 1000, 2)
        $timeB_s = [Math]::Round($totalTimeB / 1000, 2)
        $null = $md.AppendLine("| Metric | A | B |")
        $null = $md.AppendLine("|--------|--:|--:|")
        $null = $md.AppendLine("| Total time | ${timeA_s}s ($totalTimeA ms) | ${timeB_s}s ($totalTimeB ms) |")
        $null = $md.AppendLine("| Average per page | $([Math]::Round($avgA, 0)) ms | $([Math]::Round($avgB, 0)) ms |")
        $null = $md.AppendLine("")

        $diffAbs   = [Math]::Abs($totalTimeA - $totalTimeB)
        $diffS     = [Math]::Round($diffAbs / 1000, 2)
        $diffPct   = if ($totalTimeA -gt 0) { [Math]::Round(($diffAbs / $totalTimeA) * 100, 1) } else { 0 }
        $avgDiffAbs = [Math]::Round([Math]::Abs($avgB - $avgA), 1)
        $avgPctAbs  = [Math]::Round([Math]::Abs(($avgB - $avgA) / $avgA * 100), 1)

        if ($diffPct -gt 1) {
            if ($totalTimeB -lt $totalTimeA) {
                $perfLine = "**B is faster overall: saves ${diffS}s ($diffPct%) in total render time**"
            } else {
                $perfLine = "**A is faster overall: saves ${diffS}s ($diffPct%) in total render time**"
            }
        } else {
            $perfLine = "**Overall difference is statistically insignificant (< 1%)**"
        }
        $null = $md.AppendLine($perfLine)
        if ($avgPctAbs -gt 1) {
            if ($avgB -lt $avgA) {
                $null = $md.AppendLine("  Average per page: B is $avgDiffAbs ms faster ($avgPctAbs%)")
            } else {
                $null = $md.AppendLine("  Average per page: A is $avgDiffAbs ms faster ($avgPctAbs%)")
            }
        }
        $null = $md.AppendLine("")

        # Unfair comparisons detail
        if ($unfairPages) {
            $null = $md.AppendLine("## Unfair Comparisons Detail")
            $null = $md.AppendLine("")
            foreach ($up in $unfairPages) {
                $upWinner = $up.Winner -replace " \[!\]", ""
                $upImgA = $up.PSObject.Properties[$imgColA]; $upImgAv = if ($null -ne $upImgA) { [int]$upImgA.Value } else { 0 }
                $upImgB = $up.PSObject.Properties[$imgColB]; $upImgBv = if ($null -ne $upImgB) { [int]$upImgB.Value } else { 0 }
                $upCs = $up.PSObject.Properties["${colA}_CoverSuccess"]
                if ($null -ne $upCs -and $upCs.Value -ne $null -and $upCs.Value -ne '') {
                    $statusA = if ([bool]$upCs.Value) { "SUCCESS" } else { "FAILED" }
                    $statusB = if ([bool]$up.PSObject.Properties["${colB}_CoverSuccess"].Value) { "SUCCESS" } else { "FAILED" }
                    $null = $md.AppendLine("- **Page $($up.Page)**: Cover generation - A: $statusA, B: $statusB | Winner: $upWinner")
                } else {
                    $null = $md.AppendLine("- **Page $($up.Page)**: Image count - A: $upImgAv, B: $upImgBv | Winner: $upWinner")
                    if ($upWinner -eq $winnerA -and $upImgAv -lt $upImgBv) {
                        $null = $md.AppendLine("  > [!] A won but had fewer images - result may be misleading")
                    } elseif ($upWinner -eq $winnerB -and $upImgBv -lt $upImgAv) {
                        $null = $md.AppendLine("  > [!] B won but had fewer images - result may be misleading")
                    } else {
                        $null = $md.AppendLine("  > [i] Winner had more images - result is conservative")
                    }
                }
            }
            $null = $md.AppendLine("")
        }

        # Footer
        $null = $md.AppendLine("---")
        $null = $md.AppendLine("*Generated by EPUB Optimization Benchmark - $($jsonMeta.timestamp)*")

        $mdFile = $outputFile -replace '\.csv$', '.md'
        $md.ToString() | Set-Content -Path $mdFile -Encoding UTF8
        Write-Host "MD  exported: $mdFile" -ForegroundColor Green
    }

    # Ask if user wants to see charts (only for 2-log comparisons)
    if ($logsWithTimes.Count -eq 2) {
        Write-Host ""
        Write-Host ""
        $response = Read-Host "Show performance charts? (s/n)"

        if ($response -eq "s" -or $response -eq "S") {
            $displayNameA = $shortNameA
            $displayNameB = $shortNameB

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
                    $bareWinnerChart = $row.Winner -replace " \[!\]", ""
                    if ($bareWinnerChart -eq "TIE") {
                        Write-Host $row.Winner -ForegroundColor Gray
                    } elseif ($bareWinnerChart -eq $winnerA) {
                        $winnerShort = if ($winnerA.Length -gt 8) { $winnerA.Substring(0, 6) + ".." } else { $winnerA }
                        Write-WithWarning "$winnerShort$(if ($row.Winner -like '*[!]*') { ' [!]' })" "Green"
                    } else {
                        $winnerShort = if ($winnerB.Length -gt 8) { $winnerB.Substring(0, 6) + ".." } else { $winnerB }
                        Write-WithWarning "$winnerShort$(if ($row.Winner -like '*[!]*') { ' [!]' })" "Blue"
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
