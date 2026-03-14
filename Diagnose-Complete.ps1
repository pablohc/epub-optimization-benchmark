# Diagnose-Complete.ps1
# Comprehensive diagnosis of log capture problems

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LOG CAPTURE DIAGNOSTIC" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check available ports
Write-Host "1. AVAILABLE COM PORTS" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Gray

$ports = [System.IO.Ports.SerialPort]::GetPortNames()

if ($ports.Count -eq 0) {
    Write-Host "   [FAIL] No COM ports detected" -ForegroundColor Red
    Write-Host ""
    Write-Host "   ACTIONS:" -ForegroundColor Yellow
    Write-Host "   1. Verify devices are connected via USB" -ForegroundColor Gray
    Write-Host "   2. Install USB-Serial drivers if needed" -ForegroundColor Gray
    Write-Host "   3. Run: devmgmt.msc and check 'Ports (COM & LPT)'" -ForegroundColor Gray
    exit 1
}

Write-Host "   Ports detected: $($ports -join ', ')" -ForegroundColor Green
Write-Host ""

# 2. Test each port
Write-Host "2. CONNECTION TEST TO PORTS" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Gray

foreach ($port in $ports) {
    Write-Host "   Testing $port..." -NoNewline -ForegroundColor Gray

    try {
        $serial = New-Object System.IO.Ports.SerialPort
        $serial.PortName = $port
        $serial.BaudRate = 115200
        $serial.Parity = "None"
        $serial.DataBits = 8
        $serial.StopBits = "One"

        $serial.Open()
        Start-Sleep -Milliseconds 500

        # Check for data
        $bytesRead = 0
        $sample = ""

        for ($i = 0; $i -lt 10; $i++) {
            if ($serial.BytesToRead -gt 0) {
                $data = $serial.ReadExisting()
                $bytesRead += $data.Length
                $sample += $data.Substring(0, [Math]::Min(50, $data.Length))
            }
            Start-Sleep -Milliseconds 200
        }

        $serial.Close()

        if ($bytesRead -gt 0) {
            Write-Host " [OK] DATA ($bytesRead bytes)" -ForegroundColor Green

            # Show data sample
            if ($sample.Length -gt 0) {
                $cleanSample = $sample -replace "`r`n", " " -replace "`n", " " -replace "`r", " "
                $cleanSample = $cleanSample.Substring(0, [Math]::Min(80, $cleanSample.Length))
                Write-Host "      Sample: $cleanSample..." -ForegroundColor DarkGray
            }
        } else {
            Write-Host " [WARN] NO DATA (port open but not receiving)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host " [FAIL] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""

# 3. Check permissions
Write-Host "3. PERMISSIONS AND ACCESS" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Gray

try {
    $testFile = ".\logs\test_write.tmp"
    if (-not (Test-Path ".\logs")) {
        New-Item -ItemType Directory -Path ".\logs" | Out-Null
    }
    "TEST" | Out-File $testFile -Force
    $content = Get-Content $testFile
    Remove-Item $testFile -Force

    Write-Host "   [OK] Write permissions OK" -ForegroundColor Green
}
catch {
    Write-Host "   [FAIL] Permission error: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""

# 4. Check existing files
Write-Host "4. EXISTING LOG FILES" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Gray

if (Test-Path ".\logs") {
    $logFiles = Get-ChildItem ".\logs\*.txt" -ErrorAction SilentlyContinue

    if ($logFiles) {
        Write-Host "   Files found:" -ForegroundColor Cyan
        foreach ($file in $logFiles) {
            $size = $file.Length
            $lines = (Get-Content $file -ErrorAction SilentlyContinue | Measure-Object -Line).Lines

            if ($size -eq 0) {
                Write-Host "   [FAIL] $($file.Name) - 0 bytes (empty)" -ForegroundColor Red
            } elseif ($lines -lt 5) {
                Write-Host "   [WARN] $($file.Name) - $size bytes, $lines lines" -ForegroundColor Yellow
            } else {
                Write-Host "   [OK] $($file.Name) - $size bytes, $lines lines" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "   No .txt files in .\logs" -ForegroundColor Gray
    }
} else {
    Write-Host "   Directory .\logs does not exist" -ForegroundColor Gray
}

Write-Host ""

# 5. Recommendations
Write-Host "5. RECOMMENDATIONS" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Gray

$anyData = $false
foreach ($port in $ports) {
    try {
        $serial = New-Object System.IO.Ports.SerialPort
        $serial.PortName = $port
        $serial.BaudRate = 115200
        $serial.Parity = "None"
        $serial.DataBits = 8
        $serial.StopBits = "One"
        $serial.Open()
        Start-Sleep -Milliseconds 500

        for ($i = 0; $i -lt 10; $i++) {
            if ($serial.BytesToRead -gt 0) {
                $anyData = $true
                break
            }
            Start-Sleep -Milliseconds 200
        }

        $serial.Close()

        if ($anyData) {
            break
        }
    }
    catch {
        # Ignore errors in verification
    }
}

if (-not $anyData) {
    Write-Host "   [WARN] DEVICES ARE NOT SENDING DATA" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Possible causes:" -ForegroundColor Gray
    Write-Host "   1. Debug logs not enabled in firmware" -ForegroundColor DarkGray
    Write-Host "   2. Baudrate is not 115200" -ForegroundColor DarkGray
    Write-Host "   3. Devices need command to start logs" -ForegroundColor DarkGray
    Write-Host "   4. Logs sent via USB, not serial" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   Solutions:" -ForegroundColor Gray
    Write-Host "   1. Check device configuration" -ForegroundColor DarkGray
    Write-Host "   2. Review firmware source code" -ForegroundColor DarkGray
    Write-Host "   3. Look for DEBUG_LOG or SERIAL_DEBUG defines" -ForegroundColor DarkGray
    Write-Host "   4. Build firmware with logs enabled" -ForegroundColor DarkGray
} else {
    Write-Host "   [OK] Devices are sending data" -ForegroundColor Green
    Write-Host "   Problem is in capture script" -ForegroundColor Gray
}

Write-Host ""
Write-Host "6. CONCLUSION" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Gray

if ($anyData) {
    Write-Host "   Devices are working correctly." -ForegroundColor Green
    Write-Host "   Review capture script to find error." -ForegroundColor Gray
} else {
    Write-Host "   Devices are NOT sending data via serial port." -ForegroundColor Red
    Write-Host ""
    Write-Host "   You need to verify:" -ForegroundColor Yellow
    Write-Host "   1. Does firmware have debug logs enabled?" -ForegroundColor DarkGray
    Write-Host "   2. Are logs sent via serial or USB?" -ForegroundColor DarkGray
    Write-Host "   3. Is special configuration required?" -ForegroundColor DarkGray
}

Write-Host ""
