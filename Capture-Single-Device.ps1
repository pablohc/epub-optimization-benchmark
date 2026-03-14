# Capture-Single-Device.ps1
# Interactive single device capture with book specification

param(
    [Parameter(Mandatory=$false)]
    [string]$ComPort = ""
)

# Create logs directory
$logsDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir | Out-Null
}

# Detect available COM ports
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SINGLE DEVICE CAPTURE - Port Detection" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Detecting available COM ports..." -ForegroundColor Cyan

# Get port names and sort them without using pipeline on single-element arrays
$rawPorts = [System.IO.Ports.SerialPort]::GetPortNames()
$availablePorts = @($rawPorts)
$availablePorts = [string[]]($availablePorts | Sort-Object)

if ($availablePorts.Count -eq 0) {
    Write-Host "ERROR: No COM ports detected" -ForegroundColor Red
    Write-Host "Please connect a device and try again" -ForegroundColor Yellow
    exit 1
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

# Auto-select if only one port available
if ($availablePorts.Count -eq 1) {
    $ComPort = $availablePorts[0]
    Write-Host ("Auto-selected: {0} (only port available)" -f $ComPort) -ForegroundColor Green
    Write-Host ""
}
# Use provided port if valid
elseif ($ComPort -ne "" -and $ComPort -in $availablePorts) {
    Write-Host ("Using specified port: {0}" -f $ComPort) -ForegroundColor Green
    Write-Host ""
}
# Otherwise, prompt user to select
else {
    $maxSelect = $availablePorts.Count
    $selection = 0
    while ($selection -lt 1 -or $selection -gt $maxSelect) {
        $selection = Read-Host "Select port (1-$maxSelect)"
        if ($selection -notmatch '^\d+$') {
            $selection = 0
        }
    }
    $ComPort = $availablePorts[$selection - 1]
    Write-Host ("Selected: {0}" -f $ComPort) -ForegroundColor Green
    Write-Host ""
}

# Interactive book specification
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SINGLE DEVICE CAPTURE" -ForegroundColor Cyan
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
# Capture with TEMP filename, will be renamed at the end
$fileName = Join-Path $logsDir "COM${portShort}_TEMP_${timestamp}.txt"

Write-Host "Output file:" -ForegroundColor Green
Write-Host "  $fileName" -ForegroundColor Gray
Write-Host ""
Write-Host "Press ENTER to start, Ctrl+C to stop" -ForegroundColor Yellow
Read-Host

Write-Host ""
Write-Host "Opening port (device will restart)..." -ForegroundColor Cyan

# Open port
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

    # Write metadata header
    $metadata = "CAPTURE_METADATA: Type=${sanitizedBook}, Device=$ComPort, Timestamp=${timestamp}"
    $writer.WriteLine($metadata)

    Write-Host "[OK] Capturing... Press Ctrl+C to stop" -ForegroundColor Green
    Write-Host ""

    $count = 0
    $lastDot = Get-Date

    while ($true) {
        # Read from port
        if ($port.BytesToRead -gt 0) {
            $data = $port.ReadExisting()
            $writer.Write($data)
            $count += $data.Length
        }

        # Show progress every second
        if ((Get-Date) - $lastDot -gt [TimeSpan]::FromSeconds(1)) {
            Write-Host "`r[$count bytes captured] " -NoNewline -ForegroundColor Gray
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

    if ($writer) { $writer.Close() }
    if ($port -and $port.IsOpen) { $port.Close() }

    Write-Host ""
    Write-Host "File:" -ForegroundColor Cyan

    if (Test-Path $fileName) {
        $size = (Get-Item $fileName).Length
        Write-Host "  $fileName - $size bytes" -ForegroundColor Gray
    } else {
        Write-Host "  $fileName - NOT CREATED" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host ("Capture completed for: {0} on {1}" -f $book, $ComPort) -ForegroundColor Green

    # Try to extract the real book name from log and rename the file
    Write-Host ""
    Write-Host "Extracting book name from log..." -ForegroundColor Yellow

    try {
        if (Test-Path $fileName) {
            $logContent = Get-Content $fileName -Raw

            # Pattern to match: [timestamp] [DBG] [EBP] Loading ePub: /FOLDER-XXXX/BOOKNAME.epub
            # Updated pattern to handle spaces and special characters in filename
            $pattern = '\[\d+\]\s+\[DBG\]\s+\[EBP\]\s+Loading\s+ePub:\s+[^\s]+/(.+\.epub)'
            $match = [regex]::Match($logContent, $pattern)

            if ($match.Success) {
                $epubFileName = $match.Groups[1].Value.Trim()
                # Use the full epub filename (e.g., LIBRO.EPUB)
                $sanitizedEpubName = $epubFileName -replace '[^\w\-\.]', '_'

                # Generate new filename: COM3_ORIGINAL_LIBRO.EPUB_20250313_123456.txt
                $newFileName = Join-Path $logsDir "COM${portShort}_${sanitizedBook}_${sanitizedEpubName}_${timestamp}.txt"

                # Rename the file
                Move-Item -Path $fileName -Destination $newFileName -Force
                Write-Host "  Renamed to: COM${portShort}_${sanitizedBook}_${sanitizedEpubName}_${timestamp}.txt" -ForegroundColor Green
                $finalFileName = $newFileName
            } else {
                Write-Host "  WARNING: Could not extract book name from log" -ForegroundColor Yellow
                Write-Host "  Keeping TEMP filename: $fileName" -ForegroundColor Yellow
                $finalFileName = $fileName
            }
        }
    }
    catch {
        Write-Host "  ERROR: Could not rename file - $($_.Exception.Message)" -ForegroundColor Yellow
        $finalFileName = $fileName
    }

    Write-Host ""
    Write-Host "Final log file: $finalFileName" -ForegroundColor Cyan
    Write-Host "Note: For single device analysis, capture the same book on another device" -ForegroundColor Yellow
    Write-Host "      and run .\Analyze-Logs-Specific.ps1 to compare results" -ForegroundColor Yellow
    Write-Host ""
}