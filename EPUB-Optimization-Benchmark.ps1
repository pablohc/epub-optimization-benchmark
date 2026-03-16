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

# Session port memory for dual device capture (persists within a script run)
$global:SessionLeftPort = $null
$global:SessionRightPort = $null

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

        # STEP 4: Identify LEFT/RIGHT devices (reuse session ports if available)
        $leftPort = $null
        $rightPort = $null
        $reusingSession = $false

        if ($global:SessionLeftPort -and $global:SessionRightPort -and
            $availablePorts -contains $global:SessionLeftPort -and
            $availablePorts -contains $global:SessionRightPort) {

            Write-Host "  Same devices from previous capture:" -ForegroundColor Cyan
            Write-Host "    LEFT  ->  $($global:SessionLeftPort)" -ForegroundColor Green
            Write-Host "    RIGHT ->  $($global:SessionRightPort)" -ForegroundColor Green
            Write-Host ""
            Write-Host "  [ENTER] Continue  [R] Re-identify devices: " -ForegroundColor Yellow -NoNewline
            $reuseChoice = Read-Host
            if ($reuseChoice -inotmatch "^r") {
                $leftPort = $global:SessionLeftPort
                $rightPort = $global:SessionRightPort
                $reusingSession = $true
                Write-Host ""
            }
        }

        if (-not $reusingSession) {

        # Open all ports to monitor for button presses
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

        # Save identified ports for this session
        $global:SessionLeftPort = $leftPort
        $global:SessionRightPort = $rightPort

        } # end if (-not $reusingSession)

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

    # Find all "Decoding and caching" entries to capture image keys per page
    $decodingImages = @()
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match "\[(\d+)\].*\[IMG\] Decoding and caching: .+/(img_\d+_\d+)\.\w+") {
            $decodingImages += [PSCustomObject]@{
                Timestamp = [int]$matches[1]
                ImgKey    = $matches[2]
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

        # Collect image cache keys for this page
        $pageImageKeys = @()
        foreach ($img in $decodingImages) {
            if ($img.Timestamp -gt $previousPageTime -and $img.Timestamp -lt $currentPageTime) {
                $pageImageKeys += $img.ImgKey
            }
        }

        $results += [PSCustomObject]@{
            PageIndex  = $i
            ImageCount = $imageCount
            Images     = $pageImageKeys
        }
    }

    return $results
}

# Returns a hashtable of page index (0-based) -> bool indicating if a 0xD4 half refresh
# occurred during that page's render cycle (between consecutive "Rendered page in" lines).
function Get-PagesWithHalfRefresh {
    param($FilePath)
    $result = @{}
    if (-not (Test-Path $FilePath)) { return $result }
    $content = Get-Content $FilePath
    $pageIndex = 0
    $prevLine  = 0
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match "Rendered page in \d+ms") {
            $hasR = $false
            for ($j = $prevLine; $j -lt $i; $j++) {
                if ($content[$j] -match "0xD4") { $hasR = $true; break }
            }
            $result[$pageIndex] = $hasR
            $prevLine = $i + 1
            $pageIndex++
        }
    }
    return $result
}

# Maps img_S_I cache keys -> original image filenames by parsing section build events.
# [ERS] Loading file: ..., index: N  tells us the section index.
# [EHP] Found image: src=.../FILENAME lines (in order) tell us img_S_0, img_S_1, etc.
function Get-SectionImageMap {
    param($FilePath)

    $map = @{}
    if (-not (Test-Path $FilePath)) { return $map }

    $content = Get-Content $FilePath
    $sectionIndex      = -1
    $imgIndexInSection = 0

    for ($i = 0; $i -lt $content.Count; $i++) {
        # Section start: "[ERS] Loading file: ..., index: N"
        if ($content[$i] -match "\[ERS\] Loading file:.*,\s*index:\s*(\d+)") {
            $sectionIndex      = [int]$matches[1]
            $imgIndexInSection = 0
        }
        # Image found during parsing: "[EHP] Found image: src=.../FILENAME"
        elseif ($sectionIndex -ge 0 -and $content[$i] -match "\[EHP\] Found image: src=[^\s]*/([^\s/]+\.(jpg|jpeg|png|gif|bmp|webp))") {
            $filename = $matches[1]
            $key      = "img_${sectionIndex}_${imgIndexInSection}"
            $map[$key] = $filename
            $imgIndexInSection++
        }
    }

    # Supplement: extract key->filename directly from decoding events
    # "[IMG] Decoding and caching: .../img_S_I.ext" - key is embedded in path
    foreach ($line in $content) {
        if ($line -match "\[IMG\] Decoding and caching: .+/((img_\d+_\d+)\.(jpg|jpeg|png|gif|bmp|webp))") {
            $key = $matches[2]; $filename = $matches[1]
            if (-not $map.ContainsKey($key)) { $map[$key] = $filename }
        }
    }

    return $map
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
    $sessionMap = @{} # Map session letter to list of indices (ORIGINAL first)
    $sessionLetters = 'abcdefghijklmnopqrstuvwxyz'
    $sessionCounter = 0

    # Build map of analyzed log-file pairs from existing analysis JSON output files
    # Key: "logA.txt|logB.txt" (sorted), Value: analysis date string
    $analyzedLogPairs = @{}
    $analysisJsonFiles = Get-ChildItem $logsDir -Filter "analysis_*.json" -ErrorAction SilentlyContinue
    foreach ($jsonFile in $analysisJsonFiles) {
        try {
            $jdata = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json
            $lfa = $jdata.meta.a.log_file
            $lfb = $jdata.meta.b.log_file
            if ($lfa -and $lfb) {
                $pair = @($lfa, $lfb) | Sort-Object
                $pairKey = $pair -join '|'
                if (-not $analyzedLogPairs.ContainsKey($pairKey) -or $jsonFile.LastWriteTime -gt $analyzedLogPairs["${pairKey}_dt"]) {
                    $analyzedLogPairs[$pairKey] = $jsonFile.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                    $analyzedLogPairs["${pairKey}_dt"] = $jsonFile.LastWriteTime
                }
            }
        } catch { }
    }

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

        # Sort logs within session: ORIGINAL first, then OPTIMIZED, then others
        # Use -match to handle type variants like ORIGINAL-10R-ASYNC, OPTIMIZED-10R-ASYNC
        $sortedLogs = $group.Group | Sort-Object {
            if ($_.Type -match '^ORIGINAL') { 0 }
            elseif ($_.Type -match '^OPTIMIZED') { 1 }
            else { 99 }
        }

        # Check if any pair of logs from this session has a matching analysis output file
        $sessionLogFiles = @($sortedLogs | ForEach-Object { Split-Path $_.Path -Leaf })
        $isSessionAnalyzed = $false
        $sessionAnalyzedAt = ""
        for ($i = 0; $i -lt $sessionLogFiles.Count - 1; $i++) {
            for ($j = $i + 1; $j -lt $sessionLogFiles.Count; $j++) {
                $pair = @($sessionLogFiles[$i], $sessionLogFiles[$j]) | Sort-Object
                $pairKey = $pair -join '|'
                if ($analyzedLogPairs.ContainsKey($pairKey)) {
                    $isSessionAnalyzed = $true
                    $sessionAnalyzedAt = $analyzedLogPairs[$pairKey]
                }
            }
        }

        $sessionLetter = [string]$sessionLetters[$sessionCounter]
        $sessionCounter++

        Write-Host "  [$($sessionLetter.ToUpper())] [$formatted]" -ForegroundColor Yellow -NoNewline
        if ($isSessionAnalyzed) {
            Write-Host "  [Analyzed $sessionAnalyzedAt]" -ForegroundColor Green
        } else {
            Write-Host ""
        }

        $sessionIndices = @()
        foreach ($log in $sortedLogs) {
            $logIndex++
            $logMap[$logIndex] = $log
            $sessionIndices += $logIndex

            Write-Host "    [$logIndex] $($log.FileName)" -ForegroundColor White
        }
        $sessionMap["$sessionLetter"] = $sessionIndices
        Write-Host ""
    }

    # Interactive selection (retry loop)
    Write-Host "Select logs to compare:" -ForegroundColor Yellow
    Write-Host "  - Enter a session letter (e.g.: a or A) to select all logs from that session" -ForegroundColor Gray
    Write-Host "  - Enter two numbers (e.g.: 1,3) to compare specific logs" -ForegroundColor Gray
    Write-Host ""

    $selectedIndices = @()
    while ($selectedIndices.Count -lt 2) {
        $promptLine = [Console]::CursorTop
        $selection = Read-Host "Selection"
        $selection = $selection.Trim()

        $selectedIndices = @()
        $invalid = $false

        if ($selection -match '^[a-zA-Z]$') {
            if ($sessionMap.ContainsKey($selection.ToLower())) {
                $selectedIndices = $sessionMap[$selection.ToLower()]
            } else {
                $invalid = $true
            }
        } else {
            foreach ($part in $selection -split ',') {
                $part = $part.Trim()
                if ($part -match '^(\d+)-(\d+)$') {
                    $start = [int]$matches[1]
                    $end = [int]$matches[2]
                    for ($i = $start; $i -le $end; $i++) {
                        if ($logMap.ContainsKey($i)) { $selectedIndices += $i }
                    }
                } elseif ($part -match '^\d+$') {
                    $index = [int]$part
                    if ($logMap.ContainsKey($index)) { $selectedIndices += $index }
                }
            }
            if ($selectedIndices.Count -lt 2) { $invalid = $true }
        }

        if ($invalid) {
            Write-Host "Invalid option. Press ENTER to try again..." -ForegroundColor Red -NoNewline
            [Console]::ReadKey($true) | Out-Null
            # Clear the error line and the "Selection: X" line, restore cursor
            $clearLine = ' ' * [Console]::WindowWidth
            [Console]::SetCursorPosition(0, [Console]::CursorTop)
            [Console]::Write($clearLine)
            [Console]::SetCursorPosition(0, $promptLine)
            [Console]::Write($clearLine)
            [Console]::SetCursorPosition(0, $promptLine)
        }
    }

    # Get selected logs
    $selectedLogs = $selectedIndices | ForEach-Object { $logMap[$_] }

    Clear-Host
    Write-Host ""
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  ANALYZING SELECTED LOGS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
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

        # Build section image map (img_S_I -> original filename)
        $sectionImgMap = Get-SectionImageMap $log.Path
        $log | Add-Member -MemberType NoteProperty -Name "SectionImageMap" -Value $sectionImgMap -Force

        # Detect which pages had a half refresh (0xD4) in their render cycle
        $halfRefreshPages = Get-PagesWithHalfRefresh $log.Path
        $log | Add-Member -MemberType NoteProperty -Name "HalfRefreshPages" -Value $halfRefreshPages -Force
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
        $log | Add-Member -MemberType NoteProperty -Name "EpubPath"    -Value $epubPath    -Force
        $log | Add-Member -MemberType NoteProperty -Name "EpubFolder"  -Value $epubFolder  -Force
        $log | Add-Member -MemberType NoteProperty -Name "TotalImages" -Value $totalImages -Force

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

    # Build global sets of all image base names decoded across ALL pages in each log.
    # Used to classify per-page discrepancies: if the "missing" image does appear
    # somewhere else in the other log, the discrepancy is a page-offset effect [~],
    # not a true failure [!].
    $allBaseNamesA = @{}
    $allBaseNamesB = @{}
    if ($logsWithTimes.Count -eq 2 -and $logA.SectionImageMap -and $logB.SectionImageMap) {
        foreach ($page in $logA.ImagesPerPage) {
            foreach ($k in $page.Images) {
                $fn = if ($logA.SectionImageMap.ContainsKey($k)) { $logA.SectionImageMap[$k] } else { $k }
                $allBaseNamesA[[System.IO.Path]::GetFileNameWithoutExtension($fn)] = $true
            }
        }
        foreach ($page in $logB.ImagesPerPage) {
            foreach ($k in $page.Images) {
                $fn = if ($logB.SectionImageMap.ContainsKey($k)) { $logB.SectionImageMap[$k] } else { $k }
                $allBaseNamesB[[System.IO.Path]::GetFileNameWithoutExtension($fn)] = $true
            }
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
            $row | Add-Member -MemberType NoteProperty -Name "A_HasRefresh" -Value ($logA.HalfRefreshPages.ContainsKey($i) -and $logA.HalfRefreshPages[$i]) -Force
            $row | Add-Member -MemberType NoteProperty -Name "B_HasRefresh" -Value ($logB.HalfRefreshPages.ContainsKey($i) -and $logB.HalfRefreshPages[$i]) -Force
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
            $discrepancyType = "none"
            $hasIdentityDiscrepancy = $false
            $keysA2 = @(); $keysB2 = @()

            # Classify discrepancy: true failure [!] vs page-offset [~]
            # - failure:  image on one side never appears anywhere in the other log
            # - offset:   same image (by base name) exists in both logs but on different pages
            # - identity: same image COUNT but different images on this page (e.g. ORIGINAL loads
            #             img_separador where OPTIMIZED loads ilustra_04 — substitute masking failure)
            if ($row.Page -is [int] -and $allBaseNamesA.Count -gt 0) {
                $pageIndex2 = $row.Page - 1
                $keysA2 = if ($pageIndex2 -ge 0 -and $pageIndex2 -lt $logA.ImagesPerPage.Count) { $logA.ImagesPerPage[$pageIndex2].Images } else { @() }
                $keysB2 = if ($pageIndex2 -ge 0 -and $pageIndex2 -lt $logB.ImagesPerPage.Count) { $logB.ImagesPerPage[$pageIndex2].Images } else { @() }

                # Identity check: counts match but images on this page differ
                if (-not $hasImageDiscrepancy -and $imagesA -gt 0 -and $imagesB -gt 0) {
                    $basesA2 = @($keysA2 | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($(if ($logA.SectionImageMap.ContainsKey($_)) { $logA.SectionImageMap[$_] } else { $_ })) })
                    $basesB2 = @($keysB2 | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($(if ($logB.SectionImageMap.ContainsKey($_)) { $logB.SectionImageMap[$_] } else { $_ })) })
                    $hasIdentityDiscrepancy = ($basesB2 | Where-Object { $basesA2 -notcontains $_ }).Count -gt 0
                }

                if ($hasImageDiscrepancy -or $hasIdentityDiscrepancy) {
                    $isTrueFailure = $false
                    foreach ($k in $keysB2) {
                        $fn = if ($logB.SectionImageMap.ContainsKey($k)) { $logB.SectionImageMap[$k] } else { $k }
                        if (-not $allBaseNamesA.ContainsKey([System.IO.Path]::GetFileNameWithoutExtension($fn))) { $isTrueFailure = $true; break }
                    }
                    if (-not $isTrueFailure) {
                        foreach ($k in $keysA2) {
                            $fn = if ($logA.SectionImageMap.ContainsKey($k)) { $logA.SectionImageMap[$k] } else { $k }
                            if (-not $allBaseNamesB.ContainsKey([System.IO.Path]::GetFileNameWithoutExtension($fn))) { $isTrueFailure = $true; break }
                        }
                    }
                    $discrepancyType = if ($isTrueFailure) { "failure" } else { "offset" }
                }
            } elseif ($hasImageDiscrepancy -and $row.Page -notlike "*Cover*") {
                $discrepancyType = "failure"  # can't classify without maps – treat as failure
            }

            # Mark page label: [!] for true failures only (offset effects shown in Winner column)
            if ($discrepancyType -eq "failure") {
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

            # Add [~] to winner for page-offset effects (image shifted to adjacent page)
            if ($discrepancyType -eq "offset") {
                $winner = "$winner [~]"
            }

            # Add [!] only when misleading: winner did less work (failed cover, fewer images,
            # or loaded substitute images while loser loaded unique content)
            if (($discrepancyType -eq "failure" -or $hasCoverMismatch) -and $winner -ne "TIE") {
                $isMisleadingWinner = if ($winner -eq $winnerA) {
                    if ($hasIdentityDiscrepancy -and -not $hasImageDiscrepancy) {
                        # A won with equal count: misleading if B loaded images absent from A's entire log
                        ($keysB2 | Where-Object {
                            $fn = if ($logB.SectionImageMap.ContainsKey($_)) { $logB.SectionImageMap[$_] } else { $_ }
                            -not $allBaseNamesA.ContainsKey([System.IO.Path]::GetFileNameWithoutExtension($fn))
                        }).Count -gt 0
                    } else {
                        $imagesA -lt $imagesB  # A won but had fewer images
                    }
                } else {
                    if ($hasIdentityDiscrepancy -and -not $hasImageDiscrepancy) {
                        # B won with equal count: misleading if A loaded images absent from B's entire log
                        ($keysA2 | Where-Object {
                            $fn = if ($logA.SectionImageMap.ContainsKey($_)) { $logA.SectionImageMap[$_] } else { $_ }
                            -not $allBaseNamesB.ContainsKey([System.IO.Path]::GetFileNameWithoutExtension($fn))
                        }).Count -gt 0
                    } else {
                        $imagesB -lt $imagesA  # B won but had fewer images
                    }
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
        Write-Host "${displayNameA} (A)" -ForegroundColor Blue -NoNewline
        Write-Host " vs " -ForegroundColor Yellow -NoNewline
        Write-Host "${displayNameB} (B)" -ForegroundColor Green -NoNewline
        Write-Host ""
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

        $msCols = @($colA, $colB, "Diff_ms")
        foreach ($mc in $msCols) { $colWidths[$mc] += 3 }  # account for " ms" suffix
        # Account for " [R]" marker (4 chars) if any row has a half refresh
        if ($comparison | Where-Object { $_.PSObject.Properties["A_HasRefresh"] -and $_.A_HasRefresh }) { $colWidths[$colA] += 4 }
        if ($comparison | Where-Object { $_.PSObject.Properties["B_HasRefresh"] -and $_.B_HasRefresh }) { $colWidths[$colB] += 4 }
        $rightAlignedCols = @($colA, $colB, $imgColA, $imgColB, "Diff_ms", "Percent")

        $headerDisplay = @{ $colA = "A"; $colB = "B"; "Diff_ms" = "Diff" }

        # Print header row
        foreach ($prop in $orderedProperties) {
            $color = if ($prop -eq $colA -or $prop -eq $imgColA) { "Blue" }
                     elseif ($prop -eq $colB -or $prop -eq $imgColB) { "Green" }
                     else { "White" }
            $w = $colWidths[$prop]
            $fmt = if ($rightAlignedCols -contains $prop) { "{0,$w}" } else { "{0,-$w}" }
            $hdr = if ($headerDisplay.ContainsKey($prop)) { $headerDisplay[$prop] } else { $prop }
            Write-Host ($fmt -f $hdr) -ForegroundColor $color -NoNewline
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
                if ($msCols -contains $prop -and $strVal -ne "") { $strVal = "${strVal} ms" }
                $hasR = ($prop -eq $colA -and $row.PSObject.Properties["A_HasRefresh"] -and $row.A_HasRefresh) -or
                        ($prop -eq $colB -and $row.PSObject.Properties["B_HasRefresh"] -and $row.B_HasRefresh)
                $width = $colWidths[$prop]
                $fmt = if ($rightAlignedCols -contains $prop) { "{0,$width}" } else { "{0,-$width}" }

                if ($prop -eq $colA -or $prop -eq $imgColA) {
                    $color = "Blue"
                } elseif ($prop -eq $colB -or $prop -eq $imgColB) {
                    $color = "Green"
                } elseif ($prop -eq "Winner") {
                    $bare = $strVal -replace " \[!\]", "" -replace " \[~\]", ""
                    $color = if ($bare -eq "TIE") { "Gray" }
                             elseif ($bare -eq $winnerA) { "Blue" }
                             elseif ($bare -eq $winnerB) { "Green" }
                             else { "White" }
                } else {
                    $color = "White"
                }

                if ($strVal -like "*[!]*") {
                    $baseVal = $strVal -replace " \[!\]", ""
                    $marker = " [!]"
                    $fullWidth = ($fmt -f $strVal).Length
                    $pad = $fullWidth - $baseVal.Length - $marker.Length
                    Write-Host $baseVal -NoNewline -ForegroundColor $color
                    Write-Host $marker -NoNewline -ForegroundColor Red
                    if ($pad -gt 0) { Write-Host (" " * $pad) -NoNewline }
                } elseif ($strVal -like "*[~]*") {
                    $baseVal = $strVal -replace " \[~\]", ""
                    $marker = " [~]"
                    $fullWidth = ($fmt -f $strVal).Length
                    $pad = $fullWidth - $baseVal.Length - $marker.Length
                    Write-Host $baseVal -NoNewline -ForegroundColor $color
                    Write-Host $marker -NoNewline -ForegroundColor Yellow
                    if ($pad -gt 0) { Write-Host (" " * $pad) -NoNewline }
                } elseif ($hasR) {
                    $marker = "[R] "
                    $valueFmt = if ($rightAlignedCols -contains $prop) { "{0,$($width - $marker.Length)}" } else { "{0,-$($width - $marker.Length)}" }
                    Write-Host $marker -NoNewline -ForegroundColor Cyan
                    Write-Host ($valueFmt -f $strVal) -NoNewline -ForegroundColor $color
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
            Write-Host "  - $("A".PadRight($legendW)): ${displayNameA} is faster" -ForegroundColor Blue
            Write-Host "  - $("B".PadRight($legendW)): ${displayNameB} is faster" -ForegroundColor Green
        } else {
            $legendW = "Test1".Length  # = 5
            Write-Host "  - $("Test1".PadRight($legendW)): ${displayNameA} is faster" -ForegroundColor Blue
            Write-Host "  - $("Test2".PadRight($legendW)): ${displayNameB} is faster" -ForegroundColor Green
        }
        Write-Host "  - TIE: When the difference is < 1% (statistically insignificant)" -ForegroundColor Gray
        Write-Host "  - " -NoNewline -ForegroundColor Gray
        Write-WithWarning "[!]" "Red" -NoNewline
        Write-Host " : True image failure - one version is missing an illustration entirely" -ForegroundColor Gray
        Write-Host "  - " -NoNewline -ForegroundColor Gray
        Write-Host "[~]" -NoNewline -ForegroundColor Yellow
        Write-Host " : Page offset - same image present in both versions but on different pages" -ForegroundColor Gray
        Write-Host "  - " -NoNewline -ForegroundColor Gray
        Write-Host "[R]" -NoNewline -ForegroundColor Cyan
        Write-Host " : Refresh Display - page includes an e-ink screen refresh cycle (not content rendering time)" -ForegroundColor Gray
        Write-Host ""

        # ── Compute all data ─────────────────────────────────────────────────
        $pagesWithWarnings = $comparison | Where-Object { $_.Winner -like "*[!]*" }

        $aWins = 0; $bWins = 0; $ties = 0
        foreach ($row in $comparison) {
            $bareWinner = $row.Winner -replace " \[!\]", "" -replace " \[~\]", ""
            if ($bareWinner -eq $winnerA) { $aWins++ }
            elseif ($bareWinner -eq $winnerB) { $bWins++ }
            elseif ($bareWinner -eq "TIE") { $ties++ }
        }

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
        # Only count [!] true-failure pages (not [~] offset pages) in success/failed tallies
        foreach ($page in ($comparison | Where-Object { $_.Page -notlike "*Cover*" -and $_.Winner -notlike "*[~]*" -and ([int]$_.$imgColA -gt 0 -or [int]$_.$imgColB -gt 0) })) {
            if ([int]$page.$imgColA -gt 0) { $imgSuccessA++ } else { $imgFailedA++ }
            if ([int]$page.$imgColB -gt 0) { $imgSuccessB++ } else { $imgFailedB++ }
        }
        $coverDiscrepancy = ($covSuccessA -ne $covSuccessB) -and (($covSuccessA + $covFailedA) -gt 0)

        # Occurrence-based image failure and offset detection
        $failureOccs  = @()   # images in B missing from A
        $failureOccsB = @()   # images in A missing from B
        $offsetOccs   = @()
        $multiBase    = @{}
        $multiBaseB   = @{}
        if ($logA.SectionImageMap -and $logB.SectionImageMap -and
            $logA.ImagesPerPage.Count -gt 0 -and $logB.ImagesPerPage.Count -gt 0) {

            $occA = @{}; $occB = @{}
            $fnMapA = @{}; $fnMapB = @{}
            for ($pi = 0; $pi -lt $logA.ImagesPerPage.Count; $pi++) {
                foreach ($k in $logA.ImagesPerPage[$pi].Images) {
                    $fn   = if ($logA.SectionImageMap.ContainsKey($k)) { $logA.SectionImageMap[$k] }
                            elseif ($logB.SectionImageMap.ContainsKey($k)) { $logB.SectionImageMap[$k] }
                            else { $k }
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($fn)
                    if (-not $occA.ContainsKey($base)) { $occA[$base] = [System.Collections.Generic.List[int]]::new() }
                    $occA[$base].Add($pi + 1)
                    $fnMapA[$base] = [System.IO.Path]::GetFileName($fn)
                }
            }
            for ($pi = 0; $pi -lt $logB.ImagesPerPage.Count; $pi++) {
                foreach ($k in $logB.ImagesPerPage[$pi].Images) {
                    $fn   = if ($logB.SectionImageMap.ContainsKey($k)) { $logB.SectionImageMap[$k] }
                            elseif ($logA.SectionImageMap.ContainsKey($k)) { $logA.SectionImageMap[$k] }
                            else { $k }
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($fn)
                    if (-not $occB.ContainsKey($base)) { $occB[$base] = [System.Collections.Generic.List[int]]::new() }
                    $occB[$base].Add($pi + 1)
                    $fnMapB[$base] = [System.IO.Path]::GetFileName($fn)
                }
            }

            foreach ($base in $occB.Keys) {
                $pagesB = @($occB[$base])
                $pagesA = if ($occA.ContainsKey($base)) { @($occA[$base]) } else { @() }
                $dispName = if ($fnMapB.ContainsKey($base)) { $fnMapB[$base] } else { $base }
                for ($i = 0; $i -lt $pagesB.Count; $i++) {
                    $pageB = $pagesB[$i]; $occN = $i + 1
                    if ($i -ge $pagesA.Count) {
                        $failureOccs += [PSCustomObject]@{ Base=$base; Name=$dispName; OccN=$occN; PageB=$pageB }
                    } elseif ($pagesA[$i] -ne $pageB) {
                        $offsetOccs  += [PSCustomObject]@{ Base=$base; Name=$dispName; OccN=$occN; PageB=$pageB; PageA=$pagesA[$i] }
                    }
                }
            }
            $failureOccs = @($failureOccs | Sort-Object PageB, Base)
            $offsetOccs  = @($offsetOccs  | Sort-Object PageB, Base)

            foreach ($base in $occA.Keys) {
                $pagesA = @($occA[$base])
                $pagesB = if ($occB.ContainsKey($base)) { @($occB[$base]) } else { @() }
                $dispName = if ($fnMapA.ContainsKey($base)) { $fnMapA[$base] } else { $base }
                for ($i = 0; $i -lt $pagesA.Count; $i++) {
                    if ($i -ge $pagesB.Count) {
                        $failureOccsB += [PSCustomObject]@{ Base=$base; Name=$dispName; OccN=($i+1); PageA=$pagesA[$i] }
                    }
                }
            }
            $failureOccsB = @($failureOccsB | Sort-Object PageA, Base)

            if ($failureOccs.Count -gt 0 -or $offsetOccs.Count -gt 0) {
                foreach ($b in $occB.Keys) { if ($occB[$b].Count -gt 1) { $multiBase[$b] = $true } }
            }
            if ($failureOccsB.Count -gt 0) {
                foreach ($b in $occA.Keys) { if ($occA[$b].Count -gt 1) { $multiBaseB[$b] = $true } }
            }
        }

        # ── Summary box ──────────────────────────────────────────────────────
        $bH = [char]0x2500; $bV = [char]0x2502
        $bTL = [char]0x250C; $bTR = [char]0x2510
        $bBL = [char]0x2514; $bBR = [char]0x2518
        $bML = [char]0x251C; $bMR = [char]0x2524
        $covStatA = if (($covSuccessA + $covFailedA) -gt 0) { if ($covSuccessA -gt 0) { "SUCCESS" } else { "FAILED" } } else { $null }
        $covStatB = if (($covSuccessB + $covFailedB) -gt 0) { if ($covSuccessB -gt 0) { "SUCCESS" } else { "FAILED" } } else { $null }

        # Column width calculation
        $sumLabels = @("Pages analyzed", "Images rendered")
        if ($failureOccs.Count -gt 0 -or $failureOccsB.Count -gt 0) { $sumLabels += "Image failures" }
        if ($null -ne $covStatA) { $sumLabels += "Cover generation" }
        $sumLabels += @("$shortNameA faster", "$shortNameB faster", "Ties (< 1%)")
        $sumLabelW = ($sumLabels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

        $colAVals = @("$($logA.TotalImages)", "$($failureOccs.Count)", "$covStatA", "$aWins", "$bWins", "$ties")
        $colBVals = @("$($logB.TotalImages)", "$($failureOccsB.Count)", "$covStatB")
        $sumColAW = ([int[]](@($shortNameA.Length) + ($colAVals | ForEach-Object { $_.Length })) | Measure-Object -Maximum).Maximum
        $sumColBW = ([int[]](@($shortNameB.Length) + ($colBVals | ForEach-Object { $_.Length })) | Measure-Object -Maximum).Maximum

        # Inner width: label + " : " + colA + "  " + colB
        $sumInnerWidth = $sumLabelW + 3 + $sumColAW + 2 + $sumColBW
        $sumHLine     = "$bH" * ($sumInnerWidth + 2)
        $sumTopBorder = "  $bTL$sumHLine$bTR"
        $sumMidBorder = "  $bML$sumHLine$bMR"
        $sumBotBorder = "  $bBL$sumHLine$bBR"

        # Helper: write one box row
        function Write-SumRow($label, $valA, $valB, $colorA, $colorB) {
            $pad = " " * ($sumColBW - $valB.Length)
            Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
            Write-Host "$($label.PadRight($sumLabelW)) : " -NoNewline -ForegroundColor Gray
            Write-Host $valA.PadLeft($sumColAW) -NoNewline -ForegroundColor $colorA
            Write-Host "  " -NoNewline
            Write-Host "$($valB.PadLeft($sumColBW)) " -NoNewline -ForegroundColor $colorB
            Write-Host "$bV" -ForegroundColor DarkCyan
        }
        function Write-SumRowSingle($label, $val, $color) {
            $pad = " " * (2 + $sumColBW)
            Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
            Write-Host "$($label.PadRight($sumLabelW)) : " -NoNewline -ForegroundColor Gray
            Write-Host $val.PadLeft($sumColAW) -NoNewline -ForegroundColor $color
            Write-Host "$pad " -NoNewline
            Write-Host "$bV" -ForegroundColor DarkCyan
        }

        Write-Host $sumTopBorder -ForegroundColor DarkCyan
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host "Summary".PadRight($sumInnerWidth) -NoNewline -ForegroundColor Cyan
        Write-Host " $bV" -ForegroundColor DarkCyan
        Write-Host $sumMidBorder -ForegroundColor DarkCyan
        # Header row (column names, each with its color)
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host (" " * ($sumLabelW + 3)) -NoNewline
        Write-Host $shortNameA.PadLeft($sumColAW) -NoNewline -ForegroundColor Blue
        Write-Host "  " -NoNewline
        Write-Host $shortNameB.PadLeft($sumColBW) -NoNewline -ForegroundColor Green
        Write-Host " $bV" -ForegroundColor DarkCyan
        Write-Host $sumMidBorder -ForegroundColor DarkCyan
        # Pages analyzed: show count for each log
        $pagesA = ($comparison | Where-Object { $null -ne $_.PSObject.Properties[$colA] -and $_.$colA -ne "" }).Count
        $pagesB = ($comparison | Where-Object { $null -ne $_.PSObject.Properties[$colB] -and $_.$colB -ne "" }).Count
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host "$("Pages analyzed".PadRight($sumLabelW)) : " -NoNewline -ForegroundColor Gray
        Write-Host "$pagesA".PadLeft($sumColAW) -NoNewline -ForegroundColor White
        Write-Host "  " -NoNewline
        Write-Host "$pagesB".PadLeft($sumColBW) -NoNewline -ForegroundColor White
        Write-Host " " -NoNewline
        Write-Host "$bV" -ForegroundColor DarkCyan
        # Images rendered: more = green, less = red, equal = both green
        $imgColorA = if ($logA.TotalImages -ge $logB.TotalImages) { "Green" } else { "Red" }
        $imgColorB = if ($logB.TotalImages -ge $logA.TotalImages) { "Green" } else { "Red" }
        Write-SumRow "Images rendered" "$($logA.TotalImages)" "$($logB.TotalImages)" $imgColorA $imgColorB
        if ($failureOccs.Count -gt 0 -or $failureOccsB.Count -gt 0) {
            $fColorA = if ($failureOccs.Count  -gt 0) { "Red" } else { "Green" }
            $fColorB = if ($failureOccsB.Count -gt 0) { "Red" } else { "Green" }
            Write-SumRow "Image failures" "$($failureOccs.Count)" "$($failureOccsB.Count)" $fColorA $fColorB
        }
        if ($null -ne $covStatA) {
            $covColorA = if ($covStatA -eq "FAILED") { "Red" } else { "Green" }
            $covColorB = if ($covStatB -eq "FAILED") { "Red" } else { "Green" }
            Write-SumRow "Cover generation" $covStatA $covStatB $covColorA $covColorB
        }
        Write-Host $sumBotBorder -ForegroundColor DarkCyan
        Write-Host ""

        # ── Page render results box ──────────────────────────────────────────
        $winsLabels = @("$shortNameA faster", "$shortNameB faster", "Ties (< 1%)")
        $winsLabelW = [Math]::Max("Page render results".Length, ($winsLabels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum)
        $winsNumW   = [Math]::Max("Pages".Length, [Math]::Max("$aWins".Length, [Math]::Max("$bWins".Length, "$ties".Length)))
        $winsSep    = [char]0x2502  # │ for column separator

        # Inner width: label col + " │ " + num col
        $winsInnerW = $winsLabelW + 3 + $winsNumW
        $winsHLine  = "$bH" * ($winsInnerW + 2)
        $winsTop    = "  $bTL$winsHLine$bTR"
        $winsMid    = "  $bML$winsHLine$bMR"
        $winsBot    = "  $bBL$winsHLine$bBR"
        # Mid border with column split: ├────────┼──────┤
        $winsColSep = "  $bML$("$bH" * ($winsLabelW + 2))$([char]0x253C)$("$bH" * ($winsNumW + 2))$bMR"

        Write-Host $winsTop -ForegroundColor DarkCyan
        # Header row
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host "Page render results".PadRight($winsLabelW) -NoNewline -ForegroundColor DarkGray
        Write-Host " $winsSep " -NoNewline -ForegroundColor DarkCyan
        Write-Host "Pages".PadLeft($winsNumW) -NoNewline -ForegroundColor DarkGray
        Write-Host " $bV" -ForegroundColor DarkCyan
        Write-Host $winsColSep -ForegroundColor DarkCyan
        $winsColorA = if ($aWins -eq 0) { "Green" } else { "Blue" }
        $winsColorB = if ($bWins -eq 0) { "Red" } else { "Green" }

        # Data rows
        foreach ($row in @(
            @{ Label="$shortNameA faster"; Val="$aWins"; Color=$winsColorA },
            @{ Label="$shortNameB faster"; Val="$bWins"; Color=$winsColorB },
            @{ Label="Ties (< 1%)";        Val="$ties";  Color="Gray"     }
        )) {
            Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
            Write-Host $row.Label.PadRight($winsLabelW) -NoNewline -ForegroundColor $row.Color
            Write-Host " $winsSep " -NoNewline -ForegroundColor DarkCyan
            Write-Host $row.Val.PadLeft($winsNumW) -NoNewline -ForegroundColor $row.Color
            Write-Host " $bV" -ForegroundColor DarkCyan
        }
        Write-Host $winsBot -ForegroundColor DarkCyan
        Write-Host ""

        # ── Unfair comparison warnings ────────────────────────────────────────
        if ($pagesWithWarnings -or $coverDiscrepancy) {
            Write-Host "UNFAIR COMPARISONS DETECTED:" -ForegroundColor Red
            if ($coverDiscrepancy) {
                $covStatusA = if ($covSuccessA -gt 0) { "Success" } else { "Failed" }
                $covStatusB = if ($covSuccessB -gt 0) { "Success" } else { "Failed" }
                Write-Host "  Cover: " -NoNewline -ForegroundColor Yellow
                Write-Host $shortNameA -NoNewline -ForegroundColor Blue
                Write-Host " $covStatusA" -NoNewline -ForegroundColor Yellow
                Write-Host "  |  " -NoNewline -ForegroundColor Yellow
                Write-Host $shortNameB -NoNewline -ForegroundColor Green
                Write-Host " $covStatusB" -ForegroundColor Yellow
            }
        }

        # ── Failure and offset details ────────────────────────────────────────
        if ($failureOccs.Count -gt 0) {
            Write-WithWarning "[!]" "Red" -NoNewline
            Write-Host " Image not rendered in " -NoNewline -ForegroundColor White
            Write-Host "${shortNameA}" -NoNewline -ForegroundColor Blue
            Write-Host ":" -ForegroundColor Yellow
            $maxBaseW  = ($failureOccs | ForEach-Object { $_.Name.Length }      | Measure-Object -Maximum).Maximum
            $maxPageBW = ($failureOccs | ForEach-Object { "$($_.PageB)".Length }| Measure-Object -Maximum).Maximum
            $anyMultiF = ($failureOccs | Where-Object { $multiBase.ContainsKey($_.Base) }).Count -gt 0
            $maxOccW   = if ($anyMultiF) { ($failureOccs | Where-Object { $multiBase.ContainsKey($_.Base) } | ForEach-Object { "$($_.OccN)".Length } | Measure-Object -Maximum).Maximum } else { 0 }
            foreach ($f in $failureOccs) {
                Write-Host "    " -NoNewline
                Write-Host $f.Name.PadRight($maxBaseW) -NoNewline -ForegroundColor Red
                if ($anyMultiF) {
                    if ($multiBase.ContainsKey($f.Base)) {
                        Write-Host "  #$("$($f.OccN)".PadLeft($maxOccW))" -NoNewline -ForegroundColor Gray
                    } else {
                        Write-Host (" " * (3 + $maxOccW)) -NoNewline
                    }
                }
                Write-Host "  page " -NoNewline -ForegroundColor Green
                Write-Host "$($f.PageB)".PadLeft($maxPageBW) -NoNewline -ForegroundColor Green
                Write-Host " in " -NoNewline -ForegroundColor Green
                Write-Host "$shortNameB" -NoNewline -ForegroundColor Green
                Write-Host "  ->  not in " -NoNewline -ForegroundColor Red
                Write-Host $shortNameA -ForegroundColor Blue
            }
            Write-Host ""
        }

        if ($failureOccsB.Count -gt 0) {
            Write-WithWarning "[!]" "Red" -NoNewline
            Write-Host " Image not rendered in " -NoNewline -ForegroundColor White
            Write-Host "${shortNameB}:" -ForegroundColor Green
            $maxBaseW  = ($failureOccsB | ForEach-Object { $_.Name.Length }      | Measure-Object -Maximum).Maximum
            $maxPageAW = ($failureOccsB | ForEach-Object { "$($_.PageA)".Length }| Measure-Object -Maximum).Maximum
            $anyMultiF = ($failureOccsB | Where-Object { $multiBaseB.ContainsKey($_.Base) }).Count -gt 0
            $maxOccW   = if ($anyMultiF) { ($failureOccsB | Where-Object { $multiBaseB.ContainsKey($_.Base) } | ForEach-Object { "$($_.OccN)".Length } | Measure-Object -Maximum).Maximum } else { 0 }
            foreach ($f in $failureOccsB) {
                Write-Host "    " -NoNewline
                Write-Host $f.Name.PadRight($maxBaseW) -NoNewline -ForegroundColor Red
                if ($anyMultiF) {
                    if ($multiBaseB.ContainsKey($f.Base)) {
                        Write-Host "  #$("$($f.OccN)".PadLeft($maxOccW))" -NoNewline -ForegroundColor Gray
                    } else {
                        Write-Host (" " * (3 + $maxOccW)) -NoNewline
                    }
                }
                Write-Host "  page " -NoNewline -ForegroundColor Blue
                Write-Host "$($f.PageA)".PadLeft($maxPageAW) -NoNewline -ForegroundColor Blue
                Write-Host " in " -NoNewline -ForegroundColor Blue
                Write-Host "$shortNameA" -NoNewline -ForegroundColor Blue
                Write-Host "  ->  not in " -NoNewline -ForegroundColor Red
                Write-Host $shortNameB -ForegroundColor Green
            }
            Write-Host ""
        }

        if ($offsetOccs.Count -gt 0) {
            Write-Host "[~] " -NoNewline -ForegroundColor Yellow
            Write-Host "Page offset effects (same content, different page):" -ForegroundColor White
            $maxBaseW  = ($offsetOccs | ForEach-Object { $_.Name.Length }       | Measure-Object -Maximum).Maximum
            $maxPageBW = ($offsetOccs | ForEach-Object { "$($_.PageB)".Length } | Measure-Object -Maximum).Maximum
            $maxPageAW = ($offsetOccs | ForEach-Object { "$($_.PageA)".Length } | Measure-Object -Maximum).Maximum
            $anyMultiO = ($offsetOccs | Where-Object { $multiBase.ContainsKey($_.Base) }).Count -gt 0
            $maxOccW   = if ($anyMultiO) { ($offsetOccs | Where-Object { $multiBase.ContainsKey($_.Base) } | ForEach-Object { "$($_.OccN)".Length } | Measure-Object -Maximum).Maximum } else { 0 }
            foreach ($o in $offsetOccs) {
                Write-Host "  " -NoNewline
                Write-Host $o.Name.PadRight($maxBaseW) -NoNewline -ForegroundColor Yellow
                if ($anyMultiO) {
                    if ($multiBase.ContainsKey($o.Base)) {
                        Write-Host "#$("$($o.OccN)".PadLeft($maxOccW))" -NoNewline -ForegroundColor Gray
                    } else {
                        Write-Host (" " * (3 + $maxOccW)) -NoNewline
                    }
                }
                Write-Host "  page " -NoNewline -ForegroundColor Green
                Write-Host "$($o.PageB)".PadLeft($maxPageBW) -NoNewline -ForegroundColor Green
                Write-Host " in $shortNameB" -NoNewline -ForegroundColor Green
                Write-Host "  -> " -NoNewline -ForegroundColor Yellow
                Write-Host " page " -NoNewline -ForegroundColor Blue
                Write-Host "$($o.PageA)".PadLeft($maxPageAW) -NoNewline -ForegroundColor Blue
                Write-Host " in $shortNameA" -ForegroundColor Blue
            }
            Write-Host ""
        }

        if ($pagesWithWarnings -or $coverDiscrepancy) {
            Write-Host "If the winner failed to generate images or cover, the result may not represent true performance!" -ForegroundColor Red
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

        $avgLabelWidth = [Math]::Max($shortNameA.Length, $shortNameB.Length)
        $avgASStr = "$([Math]::Round($avgA / 1000, 2))s"
        $avgBSStr = "$([Math]::Round($avgB / 1000, 2))s"
        $avgSWidth = [Math]::Max($avgASStr.Length, $avgBSStr.Length)
        Write-Host "Average render time per page:" -ForegroundColor Cyan
        Write-Host "  $($shortNameA.PadRight($avgLabelWidth)): $($avgASStr.PadLeft($avgSWidth)) ($($avgAStr.PadLeft($avgNumWidth)) ms)" -ForegroundColor Blue
        Write-Host "  $($shortNameB.PadRight($avgLabelWidth)): $($avgBSStr.PadLeft($avgSWidth)) ($($avgBStr.PadLeft($avgNumWidth)) ms)" -ForegroundColor Green
        Write-Host ""

        $resultNameA = $shortNameA
        $resultNameB = $shortNameB

        # [!] if the overall winner has any unfair pages
        $resultWinner = if ($avgDiff -lt 0) { $winnerA } else { $winnerB }
        $resultHasUnfair = $pagesWithWarnings | Where-Object { ($_.Winner -replace " \[!\]", "") -eq $resultWinner }
        $resultWarning = if ($resultHasUnfair) { " [!]" } else { "" }

        $avgDiffS = [Math]::Round([Math]::Abs($avgDiff) / 1000, 2)

        # Check if difference is statistically significant (> 1%)
        if ([Math]::Abs($avgPercent) -lt 1) {
            Write-Host "  Result: TIE (statistically insignificant difference: ${avgDiffS}s on average, $([Math]::Abs($avgPercent))%)" -ForegroundColor Yellow
        } elseif ($avgDiff -lt 0) {
            Write-WithWarning "  Result: $resultNameA is ${avgDiffS}s faster on average ($([Math]::Abs($avgPercent))%)$resultWarning" "Blue"
        } elseif ($avgDiff -gt 0) {
            Write-WithWarning "  Result: $resultNameB is ${avgDiffS}s faster on average ($([Math]::Abs($avgPercent))%)$resultWarning" "Green"
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
        Write-Host ($displayNameA.PadLeft($valueWidth)) -NoNewline -ForegroundColor Blue
        Write-Host (" " * 4) -NoNewline
        Write-Host ($displayNameB.PadLeft($valueWidth)) -ForegroundColor Green
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
        $cvColorA = if ($cvA -lt $cvB) { "Green" } elseif ($cvA -eq $cvB) { "Yellow" } else { "Red" }
        $cvColorB = if ($cvB -lt $cvA) { "Green" } elseif ($cvB -eq $cvA) { "Yellow" } else { "Red" }
        Write-Host "  $($consistencyNameA.PadRight($cvLabelWidth)): Coef. of Variation = $([Math]::Round($cvA, 1))%" -ForegroundColor $cvColorA
        Write-Host "  $($consistencyNameB.PadRight($cvLabelWidth)): Coef. of Variation = $([Math]::Round($cvB, 1))%" -ForegroundColor $cvColorB
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
                Write-WithWarning "  $("Most improved".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $([Math]::Abs($mostImproved.Diff_ms)) ms faster ($($mostImproved.Percent))$warningText" "Green"
            } else {
                Write-Host "  $("Most improved".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $([Math]::Abs($mostImproved.Diff_ms)) ms faster ($($mostImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
            }

            # Worst case for B: regression or least improved
            $pageDisplay = if ($leastImproved.Page -like "Cover*") { if ($leastIsMisleading) { "Cover [!]" } else { "Cover" } } else { "Page $($leastImproved.Page)" }
            $regressionHasRefresh = $leastImproved.PSObject.Properties["B_HasRefresh"] -and $leastImproved.B_HasRefresh
            if ($gotWorse -and $leastImprovedPercent -gt 1) {
                $warningText = if ($leastIsMisleading) { " [!]" } else { "" }
                Write-WithWarning "  $("Regression".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $($leastImproved.Diff_ms) ms SLOWER ($($leastImproved.Percent))$warningText" "Red" -NoNewline
                if ($regressionHasRefresh) { Write-Host " [R]" -ForegroundColor Cyan } else { Write-Host "" }
            } elseif ($gotWorse) {
                Write-Host "  $("Regression".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is $($leastImproved.Diff_ms) ms slower ($($leastImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
            } else {
                Write-Host "  $("Least improved".PadRight($impactLabelW)): $pageDisplay ($displayNameB) is only $([Math]::Abs($leastImproved.Diff_ms)) ms faster ($($leastImproved.Percent))" -ForegroundColor Yellow
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

            Write-WithWarning "  Best performer:  Page $($bestCase.Page) ($displayNameA) faster by $($bestCase.Diff_ms) ms ($($bestCase.Percent))$bestWarningText" "Green"
            Write-WithWarning "  Worst performer: Page $($worstCase.Page) ($displayNameB) faster by $($worstCase.Diff_ms) ms ($($worstCase.Percent))$worstWarningText" $(if ([Math]::Abs($worstCase.Diff_ms) -gt 1000) { "Red" } else { "Yellow" })

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

        # Pre-compute content lines for box sizing
        $perfLine1 = "$($label1.PadRight($maxLabelWidth)): $($timeA_formatted) ($totalTimeA ms)"
        $perfLine2 = "$($label2.PadRight($maxLabelWidth)): $($timeB_formatted) ($totalTimeB ms)"
        $perfLine4 = "$($label4.PadRight($maxLabelWidth)): $totalPages"
        $perfLine3 = $null; $perfLine3Color = "White"
        $perfLine3b = $null; $perfLine3bColor = "White"
        if ($totalTimeSaved -ne 0) {
            $percentSaved = if ($totalTimeA -gt 0) { [Math]::Round(([Math]::Abs($totalTimeSaved) / $totalTimeA) * 100, 1) } else { 0 }
            $timeSaved_str = [Math]::Round([Math]::Abs($totalTimeSaved) / 1000, 2).ToString("0.00")
            $timeSaved_formatted = "{0}.{1}s" -f $timeSaved_str.Split('.')[0].PadLeft($maxTimeIntWidth), $timeSaved_str.Split('.')[1]
            if ($percentSaved -gt 1) {
                $unfairMarker = if ($hasUnfairComparisonInOptimization) { " [!]" } else { "" }
                $perfWinner = if ($totalTimeSaved -lt 0) { $displayNameA } else { $displayNameB }
                $perfLine3  = "$($label3.PadRight($maxLabelWidth)): $($timeSaved_formatted) ($percentSaved%)"
                $perfLine3Color = "Green"
                $perfLine3b = "$(" " * ($maxLabelWidth + 2))  >> $perfWinner is faster$unfairMarker"
                $perfLine3bColor = "Green"
            } else {
                $perfLine3  = "$($label3.PadRight($maxLabelWidth)): $($timeSaved_formatted) ($percentSaved%)"
                $perfLine3Color = "Gray"
                $perfLine3b = "$(" " * ($maxLabelWidth + 2))  statistically insignificant"
                $perfLine3bColor = "Gray"
            }
        }

        # Box drawing
        $boxContent = @($perfLine1, $perfLine2, $perfLine4)
        if ($perfLine3)  { $boxContent += $perfLine3  }
        if ($perfLine3b) { $boxContent += $perfLine3b }
        $innerWidth   = ($boxContent | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        $bH  = [char]0x2500; $bV  = [char]0x2502
        $bTL = [char]0x250C; $bTR = [char]0x2510
        $bBL = [char]0x2514; $bBR = [char]0x2518
        $bML = [char]0x251C; $bMR = [char]0x2524
        $hLine        = "$bH" * ($innerWidth + 2)
        $topBorder    = "  $bTL$hLine$bTR"
        $midBorder    = "  $bML$hLine$bMR"
        $bottomBorder = "  $bBL$hLine$bBR"

        Write-Host $topBorder -ForegroundColor DarkCyan
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host "Total Performance".PadRight($innerWidth) -NoNewline -ForegroundColor Cyan
        Write-Host " $bV" -ForegroundColor DarkCyan
        Write-Host $midBorder -ForegroundColor DarkCyan
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host $perfLine4.PadRight($innerWidth) -NoNewline -ForegroundColor White
        Write-Host " $bV" -ForegroundColor DarkCyan
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host $perfLine1.PadRight($innerWidth) -NoNewline -ForegroundColor White
        Write-Host " $bV" -ForegroundColor DarkCyan
        Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
        Write-Host $perfLine2.PadRight($innerWidth) -NoNewline -ForegroundColor White
        Write-Host " $bV" -ForegroundColor DarkCyan
        if ($perfLine3) {
            Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
            Write-Host $perfLine3.PadRight($innerWidth) -NoNewline -ForegroundColor $perfLine3Color
            Write-Host " $bV" -ForegroundColor DarkCyan
        }
        if ($perfLine3b) {
            Write-Host "  $bV " -NoNewline -ForegroundColor DarkCyan
            Write-Host $perfLine3b.PadRight($innerWidth) -NoNewline -ForegroundColor $perfLine3bColor
            Write-Host " $bV" -ForegroundColor DarkCyan
        }
        Write-Host $bottomBorder -ForegroundColor DarkCyan
        Write-Host ""

        # Show warning if there are unfair comparisons
        if ($hasUnfairComparisonInOptimization) {
            Show-UnfairComparisonWarning
        }
        Write-Host ""
    }

    # Export to CSV
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    # Build output filename: analysis_LABELA_vs_LABELB_BookName_timestamp
    if ($logsWithTimes.Count -eq 2) {
        $labelA = $shortNameA -replace '[^\w\-]', '_'
        $labelB = $shortNameB -replace '[^\w\-]', '_'
        $bookName = $logsWithTimes[0].BookName -replace '\.epub(_\d{8}(_\d{6})?)?$', ''
        $sanitizedBookName = $bookName -replace '[^\w\-]', '_'
        $outputBase = "analysis_${labelA}_vs_${labelB}_${sanitizedBookName}"
    } else {
        $cleanBookNames = ($logsWithTimes | ForEach-Object {
            $_.BookName -replace '\.epub(_\d{8}(_\d{6})?)?$', ''
        }) -join '_vs_'
        $outputBase = "analysis_$($cleanBookNames -replace '[^\w\-]', '_')"
    }
    $outputFile = Join-Path $logsDir "${outputBase}_${timestamp}.csv"

    $comparison | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "CSV exported: " -ForegroundColor Green
    Write-Host "$outputFile" -ForegroundColor Gray
    Write-Host ""

    # Export to JSON (2-log comparisons only - includes full metadata)
    if ($logsWithTimes.Count -eq 2) {
        # Parse firmware and branch from "1.1.1-dev+master" format
        $fwPartsA = $logA.FirmwareBranch -split '\+', 2
        $fwPartsB = $logB.FirmwareBranch -split '\+', 2

        # Determine comparison type string
        $compType = if ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) { "repeatability" }
                    elseif ($uniqueTypes -gt 1 -and $uniquePorts -gt 1) { "book_type+device" }
                    elseif ($uniqueTypes -gt 1) { "book_type" }
                    else { "device" }

        # Clean book name for display
        $cleanBook = ($logA.BookName -replace '\.epub(_\d{8}(_\d{6})?)?$', '') -replace '_+', ' '

        $jsonMeta = [ordered]@{
            timestamp       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            book            = $cleanBook.Trim()
            comparison_type = $comparisonType
            a = [ordered]@{
                label         = $logA.Type
                port          = $logA.Port
                firmware      = if ($fwPartsA.Count -gt 0) { $fwPartsA[0] } else { $logA.FirmwareBranch }
                branch        = if ($fwPartsA.Count -gt 1) { $fwPartsA[1] } else { "unknown" }
                pages         = $logA.RenderTimes.Count
                total_images  = $logA.TotalImages
                cover_success = if ($logA.CoverGenerationTime) { $logA.CoverGenerationTime.Success } else { $null }
                log_file      = Split-Path $logA.Path -Leaf
                epub_path     = $logA.EpubPath
                epub_folder   = $logA.EpubFolder
            }
            b = [ordered]@{
                label         = $logB.Type
                port          = $logB.Port
                firmware      = if ($fwPartsB.Count -gt 0) { $fwPartsB[0] } else { $logB.FirmwareBranch }
                branch        = if ($fwPartsB.Count -gt 1) { $fwPartsB[1] } else { "unknown" }
                pages         = $logB.RenderTimes.Count
                total_images  = $logB.TotalImages
                cover_success = if ($logB.CoverGenerationTime) { $logB.CoverGenerationTime.Success } else { $null }
                log_file      = Split-Path $logB.Path -Leaf
                epub_path     = $logB.EpubPath
                epub_folder   = $logB.EpubFolder
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
            min_a_ms         = [int]$minA
            max_a_ms         = [int]$maxA
            median_a_ms      = [int]$medianA
            stddev_a_ms      = [Math]::Round($stdDevA, 1)
            p95_a_ms         = [int]$p95A
            p99_a_ms         = [int]$p99A
            min_b_ms         = [int]$minB
            max_b_ms         = [int]$maxB
            median_b_ms      = [int]$medianB
            stddev_b_ms      = [Math]::Round($stdDevB, 1)
            p95_b_ms         = [int]$p95B
            p99_b_ms         = [int]$p99B
            cv_a_percent     = [Math]::Round($cvA, 1)
            cv_b_percent     = [Math]::Round($cvB, 1)
            image_failures_a_count = $failureOccs.Count
            image_failures_b_count = $failureOccsB.Count
            page_offset_count      = $offsetOccs.Count
            has_unfair_pages       = [bool]($comparison | Where-Object { $_.Winner -like "*[!]*" })
            a_half_refresh_count   = ($comparison | Where-Object { $_.PSObject.Properties["A_HasRefresh"] -and $_.A_HasRefresh }).Count
            b_half_refresh_count   = ($comparison | Where-Object { $_.PSObject.Properties["B_HasRefresh"] -and $_.B_HasRefresh }).Count
        }

        $jsonPages = @()
        foreach ($row in $comparison) {
            $bareWinner = $row.Winner -replace " \[!\]", "" -replace " \[~\]", ""
            $isUnfair   = $row.Winner -like "*[!]*"

            $pageObj = [ordered]@{
                page          = $row.Page
                a_ms          = [int]$row.$colA
                b_ms          = [int]$row.$colB
                a_images      = [int]$row.$imgColA
                b_images      = [int]$row.$imgColB
                diff_ms       = [int]$row.Diff_ms
                diff_percent  = [double]($row.Percent -replace '%', '')
                winner        = $bareWinner
                unfair        = $isUnfair
                a_half_refresh = [bool]($row.PSObject.Properties["A_HasRefresh"] -and $row.A_HasRefresh)
                b_half_refresh = [bool]($row.PSObject.Properties["B_HasRefresh"] -and $row.B_HasRefresh)
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

        # Build optimization_impact / performance_highlights for JSON
        if ($uniqueTypes -gt 1) {
            $jsonImpact = [ordered]@{
                type = "optimization"
                most_improved = [ordered]@{
                    page       = $mostImproved.Page
                    diff_ms    = [int]$mostImproved.Diff_ms
                    percent    = [double]($mostImproved.Percent -replace '%', '')
                    misleading = $mostIsMisleading
                }
                least_improved = [ordered]@{
                    page          = $leastImproved.Page
                    diff_ms       = [int]$leastImproved.Diff_ms
                    percent       = [double]($leastImproved.Percent -replace '%', '')
                    is_regression = $gotWorse
                    misleading    = $leastIsMisleading
                }
            }
        } else {
            $jsonImpact = [ordered]@{
                type = "performance_highlights"
                best = [ordered]@{
                    page        = $bestCase.Page
                    diff_ms     = [int]$bestCase.Diff_ms
                    percent     = [double]($bestCase.Percent -replace '%', '')
                    has_warning = $bestCaseHasWarning
                }
                worst = [ordered]@{
                    page        = $worstCase.Page
                    diff_ms     = [int]$worstCase.Diff_ms
                    percent     = [double]($worstCase.Percent -replace '%', '')
                    has_warning = $worstCaseHasWarning
                }
            }
        }

        $jsonOutput = [ordered]@{
            meta    = $jsonMeta
            summary = $jsonSummary
            impact  = $jsonImpact
            pages   = $jsonPages
        }

        $jsonFile = $outputFile -replace '\.csv$', '.json'
        $jsonOutput | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-Host "JSON exported: " -ForegroundColor Green
        Write-Host "$jsonFile" -ForegroundColor Gray
        Write-Host ""

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
        $null = $md.AppendLine("**Type:** $comparisonType  ")
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
        $null = $md.AppendLine("| Page | ${shortNameA} ms | ${shortNameB} ms | ${shortNameA} img | ${shortNameB} img | Diff ms | Percent | Winner |")
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
            $rA = if ($row.PSObject.Properties["A_HasRefresh"] -and $row.A_HasRefresh) { " [R]" } else { "" }
            $rB = if ($row.PSObject.Properties["B_HasRefresh"] -and $row.B_HasRefresh) { " [R]" } else { "" }
            $null = $md.AppendLine("| $($row.Page) | $($row.$colA)${rA} | $($row.$colB)${rB} | $imgAv | $imgBv | $($row.Diff_ms) | $($row.Percent) | $winnerMd |")
        }
        $null = $md.AppendLine("")

        # Legend
        $null = $md.AppendLine("**Legend:**  ")
        $null = $md.AppendLine("A = $shortNameA faster  ")
        $null = $md.AppendLine("B = $shortNameB faster  ")
        $null = $md.AppendLine("TIE = difference < 1% (statistically insignificant)  ")
        $null = $md.AppendLine("[!] = image failure (one version missing an image)  ")
        $null = $md.AppendLine("[~] = page offset (same image on different page)  ")
        $null = $md.AppendLine("[R] = Refresh Display (e-ink screen refresh cycle included in page time)")
        $null = $md.AppendLine("")

        # Summary
        $null = $md.AppendLine("## Summary")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Metric | $shortNameA | $shortNameB |")
        $null = $md.AppendLine("|--------|------:|------:|")
        $null = $md.AppendLine("| Pages analyzed | $($comparison.Count) | $($comparison.Count) |")
        $null = $md.AppendLine("| Total images rendered | $($logA.TotalImages) | $($logB.TotalImages) |")
        if ($failureOccs.Count -gt 0 -or $failureOccsB.Count -gt 0) {
            $null = $md.AppendLine("| Image failures | $($failureOccs.Count) | $($failureOccsB.Count) |")
        }
        if ($offsetOccs.Count -gt 0) {
            $null = $md.AppendLine("| Page offset effects | $($offsetOccs.Count) | |")
        }
        if (($covSuccessA + $covFailedA) -gt 0) {
            $mdCovStatA = if ($covSuccessA -gt 0) { "SUCCESS" } else { "FAILED" }
            $mdCovStatB = if ($covSuccessB -gt 0) { "SUCCESS" } else { "FAILED" }
            $null = $md.AppendLine("| Cover generation | $mdCovStatA | $mdCovStatB |")
        }

        # Page render results
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Page render results | Pages |")
        $null = $md.AppendLine("|----------------------|------:|")
        $null = $md.AppendLine("| $shortNameA faster | $aWins |")
        $null = $md.AppendLine("| $shortNameB faster | $bWins |")
        $null = $md.AppendLine("| Ties (< 1% diff) | $ties |")
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
                $upWinnerDisplay = if ($upWinner -eq $winnerA) { $shortNameA } elseif ($upWinner -eq $winnerB) { $shortNameB } else { $upWinner }
                if ($null -ne $upCs -and $upCs.Value -ne $null -and $upCs.Value -ne '') {
                    $statusA = if ([bool]$upCs.Value) { "SUCCESS" } else { "FAILED" }
                    $statusB = if ([bool]$up.PSObject.Properties["${colB}_CoverSuccess"].Value) { "SUCCESS" } else { "FAILED" }
                    $null = $md.AppendLine("- **Cover [!]**: $upWinnerDisplay faster - cover generation ${shortNameA}: $statusA, ${shortNameB}: $statusB")
                    if (($upWinner -eq $winnerA -and $statusA -eq "FAILED") -or ($upWinner -eq $winnerB -and $statusB -eq "FAILED")) {
                        $null = $md.AppendLine("  > [!] Unfair advantage: winner failed to generate the cover - missing work may explain the speed difference")
                    } else {
                        $null = $md.AppendLine("  > [i] Winner generated the cover successfully - result is conservative")
                    }
                } else {
                    $upLoserDisplay = if ($upWinner -eq $winnerA) { $shortNameB } else { $shortNameA }
                    $upWinnerImgs   = if ($upWinner -eq $winnerA) { $upImgAv } else { $upImgBv }
                    $upLoserImgs    = if ($upWinner -eq $winnerA) { $upImgBv } else { $upImgAv }
                    $null = $md.AppendLine("- **Page $($up.Page)**: $upWinnerDisplay faster ($upWinnerImgs images rendered) vs $upLoserDisplay ($upLoserImgs images rendered)")
                    if ($upWinner -eq $winnerA -and $upImgAv -lt $upImgBv) {
                        $null = $md.AppendLine("  > [!] Unfair advantage: $shortNameA did less work - missing image may explain the speed difference")
                    } elseif ($upWinner -eq $winnerB -and $upImgBv -lt $upImgAv) {
                        $null = $md.AppendLine("  > [!] Unfair advantage: $shortNameB did less work - missing image may explain the speed difference")
                    } else {
                        $null = $md.AppendLine("  > [i] Winner rendered more images and still won - result is conservative")
                    }
                }
            }
            $null = $md.AppendLine("")
        }

        # Image failures (occurrence-based)
        if ($failureOccs.Count -gt 0 -or $failureOccsB.Count -gt 0) {
            $anyMultiFmd = ($failureOccs | Where-Object { $multiBase.ContainsKey($_.Base) }).Count -gt 0
            $null = $md.AppendLine("## Image Failures in $shortNameA")
            $null = $md.AppendLine("")
            if ($failureOccs.Count -eq 0) {
                $null = $md.AppendLine("No images missing from **$shortNameA** - all images from **$shortNameB** were rendered.")
            } else {
                $null = $md.AppendLine("Images rendered in **$shortNameB** but absent from **$shortNameA**:")
                $null = $md.AppendLine("")
                if ($anyMultiFmd) {
                    $null = $md.AppendLine("| Image | # | $shortNameB page | |")
                    $null = $md.AppendLine("|-------|:-:|:---:|---|")
                    foreach ($f in $failureOccs) {
                        $occLabel = if ($multiBase.ContainsKey($f.Base)) { "#$($f.OccN)" } else { "" }
                        $null = $md.AppendLine("| $($f.Name) | $occLabel | $($f.PageB) | -> not in $shortNameA |")
                    }
                } else {
                    $null = $md.AppendLine("| Image | $shortNameB page | |")
                    $null = $md.AppendLine("|-------|:---:|---|")
                    foreach ($f in $failureOccs) {
                        $null = $md.AppendLine("| $($f.Name) | $($f.PageB) | -> not in $shortNameA |")
                    }
                }
            }
            $null = $md.AppendLine("")
        }
        if ($failureOccsB.Count -gt 0 -or $failureOccs.Count -gt 0) {
            $anyMultiFmdB = ($failureOccsB | Where-Object { $multiBaseB.ContainsKey($_.Base) }).Count -gt 0
            $null = $md.AppendLine("## Image Failures in $shortNameB")
            $null = $md.AppendLine("")
            if ($failureOccsB.Count -eq 0) {
                $null = $md.AppendLine("No images missing from **$shortNameB** - all images from **$shortNameA** were rendered.")
            } else {
                $null = $md.AppendLine("Images rendered in **$shortNameA** but absent from **$shortNameB**:")
                $null = $md.AppendLine("")
                if ($anyMultiFmdB) {
                    $null = $md.AppendLine("| Image | # | $shortNameA page | |")
                    $null = $md.AppendLine("|-------|:-:|:---:|---|")
                    foreach ($f in $failureOccsB) {
                        $occLabel = if ($multiBaseB.ContainsKey($f.Base)) { "#$($f.OccN)" } else { "" }
                        $null = $md.AppendLine("| $($f.Name) | $occLabel | $($f.PageA) | -> not in $shortNameB |")
                    }
                } else {
                    $null = $md.AppendLine("| Image | $shortNameA page | |")
                    $null = $md.AppendLine("|-------|:---:|---|")
                    foreach ($f in $failureOccsB) {
                        $null = $md.AppendLine("| $($f.Name) | $($f.PageA) | -> not in $shortNameB |")
                    }
                }
            }
            $null = $md.AppendLine("")
        }

                $null = $md.AppendLine("")
        if ($offsetOccs.Count -gt 0) {
            $anyMultiOmd = ($offsetOccs | Where-Object { $multiBase.ContainsKey($_.Base) }).Count -gt 0
            $null = $md.AppendLine("## Page Offset Effects")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("Same image rendered on different pages across versions:")
            $null = $md.AppendLine("")
            if ($anyMultiOmd) {
                $null = $md.AppendLine("| Image | # | $shortNameB page | | $shortNameA page |")
                $null = $md.AppendLine("|-------|:-:|:---:|:---:|:---:|")
                foreach ($o in $offsetOccs) {
                    $occLabel = if ($multiBase.ContainsKey($o.Base)) { "#$($o.OccN)" } else { "" }
                    $null = $md.AppendLine("| $($o.Name) | $occLabel | $($o.PageB) | -> | $($o.PageA) |")
                }
            } else {
                $null = $md.AppendLine("| Image | $shortNameB page | | $shortNameA page |")
                $null = $md.AppendLine("|-------|:---:|:---:|:---:|")
                foreach ($o in $offsetOccs) {
                    $null = $md.AppendLine("| $($o.Name) | $($o.PageB) | -> | $($o.PageA) |")
                }
            }
            $null = $md.AppendLine("")
        }

        # Extended Statistics
        $null = $md.AppendLine("## Extended Statistics")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Metric | $shortNameA | $shortNameB |")
        $null = $md.AppendLine("|--------|--:|--:|")
        $null = $md.AppendLine("| Min | $([int]$minA) ms | $([int]$minB) ms |")
        $null = $md.AppendLine("| Max | $([int]$maxA) ms | $([int]$maxB) ms |")
        $null = $md.AppendLine("| Avg | $([Math]::Round($avgA, 0)) ms | $([Math]::Round($avgB, 0)) ms |")
        $null = $md.AppendLine("| Median | $([int]$medianA) ms | $([int]$medianB) ms |")
        $null = $md.AppendLine("| Std Dev | $([Math]::Round($stdDevA, 0)) ms | $([Math]::Round($stdDevB, 0)) ms |")
        $null = $md.AppendLine("| P95 | $([int]$p95A) ms | $([int]$p95B) ms |")
        $null = $md.AppendLine("| P99 | $([int]$p99A) ms | $([int]$p99B) ms |")
        $null = $md.AppendLine("")

        # Consistency Analysis
        $null = $md.AppendLine("## Consistency Analysis")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("Coefficient of Variation (lower = more consistent):")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| | CV% |")
        $null = $md.AppendLine("|---|---:|")
        $null = $md.AppendLine("| $shortNameA | $([Math]::Round($cvA, 1))% |")
        $null = $md.AppendLine("| $shortNameB | $([Math]::Round($cvB, 1))% |")
        $null = $md.AppendLine("")

        # Optimization Impact / Performance Highlights
        if ($uniqueTypes -gt 1) {
            $null = $md.AppendLine("## Optimization Impact")
            $null = $md.AppendLine("")
            $mdPageMost  = if ($mostImproved.Page  -like "Cover*") { if ($mostIsMisleading)  { "Cover [!]" } else { "Cover" } } else { "Page $($mostImproved.Page)" }
            $mdPageLeast = if ($leastImproved.Page -like "Cover*") { if ($leastIsMisleading) { "Cover [!]" } else { "Cover" } } else { "Page $($leastImproved.Page)" }
            $mostPct = [Math]::Abs([double]($mostImproved.Percent -replace '%', ''))
            if ($mostPct -gt 1) {
                $mostFlag = if ($mostIsMisleading) { " [!]" } else { "" }
                $null = $md.AppendLine("- **Most improved:** $mdPageMost - $shortNameB is $([Math]::Abs($mostImproved.Diff_ms)) ms faster ($($mostImproved.Percent))$mostFlag")
            } else {
                $null = $md.AppendLine("- **Most improved:** $mdPageMost - $shortNameB is $([Math]::Abs($mostImproved.Diff_ms)) ms faster ($($mostImproved.Percent)) *(statistically insignificant)*")
            }
            $leastPct = [double]($leastImproved.Percent -replace '%', '')
            if ($gotWorse -and $leastPct -gt 1) {
                $leastFlag = if ($leastIsMisleading) { " [!]" } else { "" }
                $mdRegrR = if ($leastImproved.PSObject.Properties["B_HasRefresh"] -and $leastImproved.B_HasRefresh) { " [R]" } else { "" }
                $null = $md.AppendLine("- **Regression:** $mdPageLeast - $shortNameB is $($leastImproved.Diff_ms) ms SLOWER ($($leastImproved.Percent))${leastFlag}${mdRegrR}")
            } elseif ($gotWorse) {
                $null = $md.AppendLine("- **Regression:** $mdPageLeast - $shortNameB is $($leastImproved.Diff_ms) ms slower ($($leastImproved.Percent)) *(statistically insignificant)*")
            } else {
                $null = $md.AppendLine("- **Least improved:** $mdPageLeast - $shortNameB is only $([Math]::Abs($leastImproved.Diff_ms)) ms faster ($($leastImproved.Percent))")
            }
            $null = $md.AppendLine("")
        } else {
            $null = $md.AppendLine("## Performance Highlights")
            $null = $md.AppendLine("")
            $bestFlag  = if ($bestCaseHasWarning)  { " [!]" } else { "" }
            $worstFlag = if ($worstCaseHasWarning) { " [!]" } else { "" }
            $null = $md.AppendLine("- **Best performer:** Page $($bestCase.Page) - $shortNameA is $($bestCase.Diff_ms) ms faster ($($bestCase.Percent))$bestFlag")
            $null = $md.AppendLine("- **Worst performer:** Page $($worstCase.Page) - $shortNameB is $([Math]::Abs($worstCase.Diff_ms)) ms faster ($($worstCase.Percent))$worstFlag")
            $null = $md.AppendLine("")
        }

        # Total Performance
        $diffAbs    = [Math]::Abs($totalTimeA - $totalTimeB)
        $diffS      = [Math]::Round($diffAbs / 1000, 2)
        $diffPct    = if ($totalTimeA -gt 0) { [Math]::Round(($diffAbs / $totalTimeA) * 100, 1) } else { 0 }
        $avgDiffAbs = [Math]::Round([Math]::Abs($avgB - $avgA), 1)
        $avgPctAbs  = [Math]::Round([Math]::Abs(($avgB - $avgA) / $avgA * 100), 1)
        $avgDiffS   = [Math]::Round($avgDiffAbs / 1000, 2)
        $timeA_s    = [Math]::Round($totalTimeA / 1000, 2)
        $timeB_s    = [Math]::Round($totalTimeB / 1000, 2)
        $pagesCount = $comparison.Count
        $null = $md.AppendLine("## Total Performance")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Metric | |")
        $null = $md.AppendLine("|--------|---:|")
        $null = $md.AppendLine("| Pages analyzed | $pagesCount |")
        $null = $md.AppendLine("| Total $shortNameA | ${timeA_s}s |")
        $null = $md.AppendLine("| Total $shortNameB | ${timeB_s}s |")
        if ($diffPct -gt 1) {
            $null = $md.AppendLine("| Time saved | ${diffS}s ($diffPct%) |")
        }
        $null = $md.AppendLine("")
        if ($diffPct -gt 1) {
            $winner = if ($totalTimeB -lt $totalTimeA) { $shortNameB } else { $shortNameA }
            $null = $md.AppendLine("**$winner is faster overall**")
        } else {
            $null = $md.AppendLine("**Overall difference is statistically insignificant (< 1%)**")
        }
        if ($avgPctAbs -gt 1) {
            $avgWinner = if ($avgB -lt $avgA) { $shortNameB } else { $shortNameA }
            $null = $md.AppendLine("  Average per page: $avgWinner is ${avgDiffS}s faster")
        }

        # Footer
        $null = $md.AppendLine("---")
        $null = $md.AppendLine("*Generated by EPUB Optimization Benchmark - $($jsonMeta.timestamp)*")

        $mdFile = $outputFile -replace '\.csv$', '.md'
        $md.ToString() | Set-Content -Path $mdFile -Encoding UTF8
        Write-Host "MD  exported: " -ForegroundColor Green
        Write-Host "$mdFile" -ForegroundColor Gray
        Write-Host ""
    }

    # Ask if user wants to see charts (only for 2-log comparisons)
    if ($logsWithTimes.Count -eq 2) {
        Write-Host ""
        Write-Host ""
        Write-Host "Press ENTER to Show Performance Charts, or ESC to return to Menu..." -ForegroundColor Gray
        $key = [Console]::ReadKey($true)

        if ($key.Key -ne [ConsoleKey]::Enter) { return }

        if ($key.Key -eq [ConsoleKey]::Enter) {
            $displayNameA = $shortNameA
            $displayNameB = $shortNameB
            $chartType = "4"

            # Shorten names for chart if needed
            $nameA = if ($displayNameA.Length -gt 10) { $displayNameA.Substring(0, 8) + ".." } else { $displayNameA }
            $nameB = if ($displayNameB.Length -gt 10) { $displayNameB.Substring(0, 8) + ".." } else { $displayNameB }

            # Dynamic page label width: enough digits to fit the highest page number
            $maxPageNum = ($comparison | ForEach-Object {
                if ($_.Page -is [int]) { $_.Page }
                elseif ("$($_.Page)" -match '^\d+') { [int]([regex]::Match("$($_.Page)", '^\d+').Value) }
                else { 0 }
            } | Measure-Object -Maximum).Maximum
            $pageNumW = [Math]::Max(2, "$maxPageNum".Length)
            # Helper: build a fixed-width label for any page value
            # "Cover" padded to match "Page NNN" width, then ": "
            function Get-ChartPageLabel($p) {
                if ($p -like "*Cover*") { return "Cover$(' ' * $pageNumW): " }
                if ($p -is [int]) { return "Page $($p.ToString().PadLeft($pageNumW)): " }
                $n = [int]([string]$p -replace '\D.*', '')
                return "Page $($n.ToString().PadLeft($pageNumW)): "
            }

            if ($chartType -eq "1" -or $chartType -eq "4") {
                Write-Host ""
                Write-Host ""
                Write-Host "Bar Chart - Page Render Times Comparison" -ForegroundColor Cyan
                Write-Host "Comparing: " -NoNewline -ForegroundColor Yellow
                Write-Host "$displayNameA (A)" -NoNewline -ForegroundColor Blue
                Write-Host " vs " -NoNewline -ForegroundColor Yellow
                Write-Host "$displayNameB (B)" -ForegroundColor Green
                Write-Host "Each bar shows render time in milliseconds." -ForegroundColor Gray
                Write-Host ""

                # Pre-calculate max ms digit width for consistent column alignment
                $msWidthBar = 4
                foreach ($r in $comparison) {
                    $ta = $r.$colA; $tb = $r.$colB
                    if ($ta -is [int] -or $ta -is [double] -or $ta -is [decimal]) { $msWidthBar = [Math]::Max($msWidthBar, "$([int]$ta)".Length) }
                    if ($tb -is [int] -or $tb -is [double] -or $tb -is [decimal]) { $msWidthBar = [Math]::Max($msWidthBar, "$([int]$tb)".Length) }
                }

                foreach ($row in $comparison) {
                    $timeA = $row.$colA
                    $timeB = $row.$colB

                    # Skip if times are null or invalid
                    if ($null -eq $timeA -or $null -eq $timeB -or $timeA -eq "N/A" -or $timeB -eq "N/A") {
                        $pageLabel = Get-ChartPageLabel $row.Page
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
                    $pageLabel = Get-ChartPageLabel $row.Page
                    Write-Host "  $pageLabel" -NoNewline -ForegroundColor Cyan

                    # Bar A
                    Write-Host "A [" -NoNewline -ForegroundColor Blue
                    Write-Host ("#" * $scaleA) -NoNewline -ForegroundColor Blue
                    Write-Host (" " * (21 - $scaleA)) -NoNewline
                    Write-Host "] " -NoNewline -ForegroundColor Blue
                    if ($row.PSObject.Properties["A_HasRefresh"] -and $row.A_HasRefresh) { Write-Host "[R] " -NoNewline -ForegroundColor Cyan } else { Write-Host "    " -NoNewline }
                    Write-Host "$($timeA.ToString().PadLeft($msWidthBar))ms" -NoNewline -ForegroundColor Gray
                    Write-Host " | " -NoNewline -ForegroundColor Gray

                    # Bar B
                    Write-Host "B [" -NoNewline -ForegroundColor Green
                    Write-Host ("#" * $scaleB) -NoNewline -ForegroundColor Green
                    Write-Host (" " * (21 - $scaleB)) -NoNewline
                    Write-Host "] " -NoNewline -ForegroundColor Green
                    if ($row.PSObject.Properties["B_HasRefresh"] -and $row.B_HasRefresh) { Write-Host "[R] " -NoNewline -ForegroundColor Cyan } else { Write-Host "    " -NoNewline }
                    Write-Host "$($timeB.ToString().PadLeft($msWidthBar))ms " -NoNewline -ForegroundColor Gray

                    # Winner + page marker at end of line
                    # [!] = true image failure, [~] = page-offset effect
                    $isFailureBar = ($row.Winner -like "*[!]*" -or $row.Page -like "*[!]*")
                    $isOffsetBar  = ($row.Winner -like "*[~]*")
                    $lineMarker   = if ($isFailureBar) { " [!]" } elseif ($isOffsetBar) { " [~]" } else { "" }
                    $markerColor  = if ($isFailureBar) { "Red" } else { "Yellow" }
                    $bareWinnerChart = $row.Winner -replace " \[!\]", "" -replace " \[~\]", ""
                    if ($bareWinnerChart -eq "TIE") {
                        Write-Host "TIE" -NoNewline -ForegroundColor Gray
                        if ($lineMarker) { Write-Host $lineMarker -NoNewline -ForegroundColor $markerColor }
                        Write-Host ""
                    } elseif ($bareWinnerChart -eq $winnerA) {
                        $winnerShort = if ($winnerA.Length -gt 8) { $winnerA.Substring(0, 6) + ".." } else { $winnerA }
                        Write-Host $winnerShort -NoNewline -ForegroundColor Blue
                        if ($lineMarker) { Write-Host $lineMarker -NoNewline -ForegroundColor $markerColor }
                        Write-Host ""
                    } else {
                        $winnerShort = if ($winnerB.Length -gt 8) { $winnerB.Substring(0, 6) + ".." } else { $winnerB }
                        Write-Host $winnerShort -NoNewline -ForegroundColor Green
                        if ($lineMarker) { Write-Host $lineMarker -NoNewline -ForegroundColor $markerColor }
                        Write-Host ""
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
                Write-Host "Comparing: " -NoNewline -ForegroundColor Yellow
                Write-Host "$displayNameA (A)" -NoNewline -ForegroundColor Blue
                Write-Host " vs " -NoNewline -ForegroundColor Yellow
                Write-Host "$displayNameB (B)" -ForegroundColor Green
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
                $msWidthTrend = [Math]::Max(4, "$([int]$globalMax)".Length)

                foreach ($row in $comparison) {
                    $timeA = $row.$colA
                    $timeB = $row.$colB

                    # Skip if times are null or invalid
                    if ($null -eq $timeA -or $null -eq $timeB -or $timeA -eq "N/A" -or $timeB -eq "N/A") {
                        $pageLabel = Get-ChartPageLabel $row.Page
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
                    $pageLabel = Get-ChartPageLabel $row.Page
                    Write-Host "  $pageLabel" -NoNewline -ForegroundColor Cyan

                    # Trend line A
                    Write-Host "A [" -NoNewline -ForegroundColor Blue
                    Write-Host (" " * $scaleA) -NoNewline
                    Write-Host "*" -NoNewline -ForegroundColor Blue
                    Write-Host (" " * (20 - $scaleA)) -NoNewline
                    Write-Host "]" -NoNewline -ForegroundColor Blue
                    if ($row.PSObject.Properties["A_HasRefresh"] -and $row.A_HasRefresh) { Write-Host " [R]" -NoNewline -ForegroundColor Cyan } else { Write-Host "    " -NoNewline }
                    Write-Host " $($timeA.ToString().PadLeft($msWidthTrend))ms" -NoNewline -ForegroundColor Gray
                    Write-Host " | " -NoNewline -ForegroundColor Gray

                    # Trend line B + page marker at end
                    $isFailureTrend = ($row.Winner -like "*[!]*" -or $row.Page -like "*[!]*")
                    $isOffsetTrend  = ($row.Winner -like "*[~]*")
                    $lineMarker = if ($isFailureTrend) { " [!]" } elseif ($isOffsetTrend) { " [~]" } else { "" }
                    $markerColorTrend = if ($isFailureTrend) { "Red" } else { "Yellow" }
                    Write-Host "B [" -NoNewline -ForegroundColor Green
                    Write-Host (" " * $scaleB) -NoNewline
                    Write-Host "*" -NoNewline -ForegroundColor Green
                    Write-Host (" " * (20 - $scaleB)) -NoNewline
                    Write-Host "]" -NoNewline -ForegroundColor Green
                    if ($row.PSObject.Properties["B_HasRefresh"] -and $row.B_HasRefresh) { Write-Host " [R]" -NoNewline -ForegroundColor Cyan } else { Write-Host "    " -NoNewline }
                    if ($lineMarker) {
                        Write-Host " $($timeB.ToString().PadLeft($msWidthTrend))ms" -NoNewline -ForegroundColor Gray
                        Write-Host $lineMarker -ForegroundColor $markerColorTrend
                    } else {
                        Write-Host " $($timeB.ToString().PadLeft($msWidthTrend))ms" -ForegroundColor Gray
                    }
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
                Write-Host "Comparing: " -NoNewline -ForegroundColor Yellow
                Write-Host "$displayNameA (A)" -NoNewline -ForegroundColor Blue
                Write-Host " vs " -NoNewline -ForegroundColor Yellow
                Write-Host "$displayNameB (B)" -ForegroundColor Green
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
                    Write-Host "  $($metric.Name.PadRight(8)): A [" -NoNewline -ForegroundColor Blue
                    Write-Host ("#" * $scaleA) -NoNewline -ForegroundColor Blue
                    Write-Host (" " * (30 - $scaleA)) -NoNewline
                    Write-Host "] $([Math]::Round($metric.ValueA, 1).ToString().PadLeft(7))ms" -ForegroundColor Gray

                    # Column B
                    Write-Host "  $($metric.Name.PadRight(8)): B [" -NoNewline -ForegroundColor Green
                    Write-Host ("#" * $scaleB) -NoNewline -ForegroundColor Green
                    Write-Host (" " * (30 - $scaleB)) -NoNewline
                    Write-Host "] $([Math]::Round($metric.ValueB, 1).ToString().PadLeft(7))ms" -ForegroundColor Green
                    Write-Host ""
                }

                # Consistency Analysis (Coefficient of Variation)
                Write-Host "  Consistency (Coef. of Variation):" -ForegroundColor Cyan
                Write-Host ""

                $cvMax = [Math]::Max($cvA, $cvB)
                $scaleCVA = if ($cvMax -gt 0) { [int](($cvA / $cvMax) * 30) } else { 0 }
                $scaleCVB = if ($cvMax -gt 0) { [int](($cvB / $cvMax) * 30) } else { 0 }

                $cvChartColorA = if ($cvA -lt $cvB) { "Green" } elseif ($cvA -eq $cvB) { "Yellow" } else { "Red" }
                $cvChartColorB = if ($cvB -lt $cvA) { "Green" } elseif ($cvB -eq $cvA) { "Yellow" } else { "Red" }
                $cvLabelW  = [Math]::Max($displayNameA.Length, $displayNameB.Length)
                $cvStrA    = "$([Math]::Round($cvA, 1))%"
                $cvStrB    = "$([Math]::Round($cvB, 1))%"
                $cvNumW    = [Math]::Max($cvStrA.Length, $cvStrB.Length)

                Write-Host "  $($displayNameA.PadRight($cvLabelW)) [" -NoNewline -ForegroundColor $cvChartColorA
                Write-Host ("#" * $scaleCVA) -NoNewline -ForegroundColor $cvChartColorA
                Write-Host (" " * (30 - $scaleCVA)) -NoNewline
                Write-Host "] $($cvStrA.PadLeft($cvNumW))" -ForegroundColor $cvChartColorA

                Write-Host "  $($displayNameB.PadRight($cvLabelW)) [" -NoNewline -ForegroundColor $cvChartColorB
                Write-Host ("#" * $scaleCVB) -NoNewline -ForegroundColor $cvChartColorB
                Write-Host (" " * (30 - $scaleCVB)) -NoNewline
                Write-Host "] $($cvStrB.PadLeft($cvNumW))" -ForegroundColor $cvChartColorB

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

            Write-Host ""
            Write-Host "Press ESC to return to Menu..." -ForegroundColor Gray
            do { $exitKey = [Console]::ReadKey($true) } until ($exitKey.Key -eq [ConsoleKey]::Escape)
            return
        }
    }

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
                    "0" { Start-DualDeviceCapture }
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
