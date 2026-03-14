# Analyze-Logs-Smart.ps1
# Smart log analyzer that automatically detects comparable logs

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
    # Pattern to find the end of cover generation
    $endPattern = "\[(\d+)\]\s+\[DBG\]\s+\[EBP\]\s+Generated thumb.*cover image.*success:\s+yes"

    $startMatch = $content | Select-String -Pattern $startPattern | Select-Object -First 1
    $endMatch = $content | Select-String -Pattern $endPattern | Select-Object -First 1

    if ($startMatch -and $endMatch) {
        $startTime = [int]$startMatch.Matches[0].Groups[1].Value
        $endTime = [int]$endMatch.Matches[0].Groups[1].Value
        $durationMs = $endTime - $startTime
        $durationSec = [Math]::Round($durationMs / 1000, 2)

        $result = [PSCustomObject]@{
            StartTime = $startTime
            EndTime = $endTime
            DurationMs = $durationMs
            DurationSec = $durationSec
            Found = $true
        }

        if ($DebugMode) {
            Write-Host "  Cover generation detected: $($durationSec)s ($durationMs ms)" -ForegroundColor Cyan
            Write-Host "    Start: [$startTime]" -ForegroundColor Gray
            Write-Host "    End:   [$endTime]" -ForegroundColor Gray
        }

        return $result
    }

    if ($DebugMode) {
        Write-Host "  Cover generation NOT detected in log" -ForegroundColor Yellow
    }

    return $null
}

$logsDir = Join-Path $PSScriptRoot "logs"

if (-not (Test-Path $logsDir)) {
    Write-Host "ERROR: Logs directory not found: $logsDir" -ForegroundColor Red
    exit 1
}

# Get all log files
$logFiles = Get-ChildItem $logsDir -Filter "*.txt" | Sort-Object LastWriteTime -Descending

if ($logFiles.Count -eq 0) {
    Write-Host "ERROR: No log files found in $logsDir" -ForegroundColor Red
    exit 1
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

    return $result
}

# Function to extract render times from log
function Get-RenderTimes {
    param($FilePath)

    if (-not (Test-Path $FilePath)) {
        return @()
    }

    $content = Get-Content $FilePath
    $matches = $content | Select-String -Pattern "\[(\d+)\]\s+\[DBG\]\s+\[ERS\]\s+Rendered page in (\d+)ms"

    $results = @()
    foreach ($match in $matches) {
        $results += [PSCustomObject]@{
            Timestamp = [int]$match.Matches[0].Groups[1].Value
            Time = [int]$match.Matches[0].Groups[2].Value
        }
    }

    return $results
}

# Function to extract images decoded per page from logs
function Get-ImagesPerPage {
    param($FilePath)

    if (-not (Test-Path $FilePath)) {
        return @()
    }

    $content = Get-Content $FilePath

    # Find all "Rendered page" entries to get page boundaries
    $renderedPages = $content | Select-String -Pattern "\[(\d+)\]\s+\[DBG\]\s+\[ERS\]\s+Rendered page in (\d+)ms"

    # Find all image decode successful entries (flexible pattern with timestamp)
    $decodeSuccess = $content | Select-String -Pattern "\[(\d+)\].*\[IMG\].*Decode successful"

    $results = @()

    # For each rendered page, count images decoded BEFORE that page render
    for ($i = 0; $i -lt $renderedPages.Count; $i++) {
        $currentPageMatch = $renderedPages[$i]
        $currentPageTime = [int]$currentPageMatch.Matches[0].Groups[1].Value

        # Get the previous page's time (or 0 for first page)
        if ($i -gt 0) {
            $previousPageTime = [int]$renderedPages[$i - 1].Matches[0].Groups[1].Value
        } else {
            $previousPageTime = 0
        }

        # Count image decodes between previous page and current page
        $imageCount = 0
        foreach ($decode in $decodeSuccess) {
            $decodeTime = [int]$decode.Matches[0].Groups[1].Value
            if ($decodeTime -gt $previousPageTime -and $decodeTime -lt $currentPageTime) {
                $imageCount++
            }
        }

        $results += [PSCustomObject]@{
            PageIndex = $i
            ImageCount = $imageCount
            Images = @()  # Don't track individual filenames from logs
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

# Parse all log files
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  SMART LOG ANALYZER" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
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
    exit 1
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
    exit 1
}

# Get selected logs
$selectedLogs = $selectedIndices | ForEach-Object { $logMap[$_] }

Write-Host ""
Write-Host "Selected logs:" -ForegroundColor Green
foreach ($log in $selectedLogs) {
    Write-Host "  $($log.FileName)" -ForegroundColor Gray
}
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
        $summary += " + cover ($($coverTime.DurationSec)s)"
    }
    Write-Host "  $($log.Port) ($($log.Type)): $summary" -ForegroundColor Gray
}

Write-Host ""

# IMPORTANT WARNING about image loading fairness
Write-Host "[!] COMPARISON FAIRNESS WARNING" -ForegroundColor Yellow
Write-Host "This analysis compares render times, but does NOT verify if all images" -ForegroundColor Yellow
Write-Host "loaded successfully. A faster time may indicate MISSING or FAILED images." -ForegroundColor Yellow
Write-Host "Pages with missing images will be marked with '[!]' in the Winner column." -ForegroundColor Yellow
Write-Host ""

# Check if all selected logs are for the same book
$uniqueBooks = ($selectedLogs | Select-Object -ExpandProperty BookName -Unique).Count

if ($uniqueBooks -gt 1) {
    Write-Host "WARNING: Comparing different books!" -ForegroundColor Yellow
    Write-Host "This comparison may not be meaningful." -ForegroundColor Yellow
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
    exit 1
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

    if ($logA.CoverGenerationTime -and $logB.CoverGenerationTime) {
        $coverRow = [PSCustomObject]@{
            Page = "Cover"
        }

        # Add cover generation times (in milliseconds) using same column names
        $coverRow | Add-Member -MemberType NoteProperty -Name $colA -Value $logA.CoverGenerationTime.DurationMs -Force
        $coverRow | Add-Member -MemberType NoteProperty -Name $colB -Value $logB.CoverGenerationTime.DurationMs -Force

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
    $colA = "$($logA.Port)_$($logA.Type)_ms"
    $colB = "$($logB.Port)_$($logB.Type)_ms"

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
        } elseif ($row.Page -eq "Cover") {
            # Cover: count images decoded before cover generation completes
            # Note: Cover row is a special case - don't count cover-related images
            # Only count images from regular content pages that happen to be decoded before cover completes
            if ($logA.CoverGenerationTime -and $logA.CoverGenerationTime.EndTime -gt 0) {
                $coverEndTimeA = $logA.CoverGenerationTime.EndTime
                $contentA = Get-Content $logA.Path
                # Count only page image decodes, exclude any cover/thumb operations
                $decodeSuccessA = $contentA | Select-String -Pattern "\[(\d+)\].*\[IMG\].*Decoding.*page" | Where-Object {
                    $_ -notmatch "Loading ePub" -and $_ -notmatch "cover"
                }
                foreach ($decode in $decodeSuccessA) {
                    $decodeTime = [int]$decode.Matches[0].Groups[1].Value
                    if ($decodeTime -lt $coverEndTimeA) {
                        $imagesA++
                    }
                }
            }

            if ($logB.CoverGenerationTime -and $logB.CoverGenerationTime.EndTime -gt 0) {
                $coverEndTimeB = $logB.CoverGenerationTime.EndTime
                $contentB = Get-Content $logB.Path
                # Count only page image decodes, exclude any cover/thumb operations
                $decodeSuccessB = $contentB | Select-String -Pattern "\[(\d+)\].*\[IMG\].*Decoding.*page" | Where-Object {
                    $_ -notmatch "Loading ePub" -and $_ -notmatch "cover"
                }
                foreach ($decode in $decodeSuccessB) {
                    $decodeTime = [int]$decode.Matches[0].Groups[1].Value
                    if ($decodeTime -lt $coverEndTimeB) {
                        $imagesB++
                    }
                }
            }
        }

        $hasImageDiscrepancy = $imagesA -ne $imagesB

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

        # Add warning marker to winner if images don't match
        if ($hasImageDiscrepancy) {
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
        $displayNameA = $logA.Type
        $displayNameB = $logB.Type
        $comparisonTitle = "Book Version Comparison"
    } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
        # Same device, same book = different tests
        $displayNameA = "Test 1 ($($logA.Port))"
        $displayNameB = "Test 2 ($($logB.Port))"
        $comparisonTitle = "Same Device Repeatability Test"
    } else {
        $displayNameA = "Device A ($($logA.Port))"
        $displayNameB = "Device B ($($logB.Port))"
        $comparisonTitle = "Device Performance Comparison"
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
$comparison | Format-Table -AutoSize

# Add Legend for 2-log comparison
if ($logsWithTimes.Count -eq 2) {
    Write-Host ""

    # Image discrepancy warning
    $pagesWithWarnings = $comparison | Where-Object { $_.ImageWarning }
    if ($pagesWithWarnings) {
        Write-Host "[!] UNFAIR COMPARISONS DETECTED:" -ForegroundColor Red
        foreach ($page in $pagesWithWarnings) {
            Write-Host "  Page $($page.Page): $($logA.Port) has $($page.ImagesA) image(s), $($logB.Port) has $($page.ImagesB) image(s)" -ForegroundColor Yellow
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
        # Book version comparison - use Type names
        $summaryNameA = $logA.Type
        $summaryNameB = $logB.Type
    } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
        # Same device repeatability - use Test numbers
        $summaryNameA = "Test 1"
        $summaryNameB = "Test 2"
    } else {
        # Device comparison - use Port names with Type
        $summaryNameA = "$($logA.Port) ($($logA.Type))"
        $summaryNameB = "$($logB.Port) ($($logB.Type))"
    }

    Write-Host "  ${summaryNameA}: $aWins wins" -ForegroundColor Green
    Write-Host "  ${summaryNameB}: $bWins wins" -ForegroundColor Green
    Write-Host "  Ties: $ties pages" -ForegroundColor Gray
    Write-Host ""

    # Comparative averages
    $avgA = ($comparison | ForEach-Object { $_.$colA } | Measure-Object -Average).Average
    $avgB = ($comparison | ForEach-Object { $_.$colB } | Measure-Object -Average).Average
    $avgDiff = $avgA - $avgB
    $avgPercent = if ($avgA -gt 0) { [Math]::Round(($avgDiff / $avgA) * 100, 1) } else { 0 }

    Write-Host "Averages:" -ForegroundColor Cyan
    Write-Host "  ${summaryNameA}: $([Math]::Round($avgA, 0)) ms" -ForegroundColor White
    Write-Host "  ${summaryNameB}: $([Math]::Round($avgB, 0)) ms" -ForegroundColor White
    Write-Host ""

    # Determine display names for result message
    if ($uniqueTypes -gt 1) {
        # Book version comparison - use Type names
        $resultNameA = $logA.Type
        $resultNameB = $logB.Type
        $resultType = "book version"
    } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
        # Same device repeatability - use Test numbers
        $resultNameA = "Test 1"
        $resultNameB = "Test 2"
        $resultType = "test"
    } else {
        # Device comparison - use Port names
        $resultNameA = $logA.Port
        $resultNameB = $logB.Port
        $resultType = "device"
    }

    # Check if difference is statistically significant (> 1%)
    if ([Math]::Abs($avgPercent) -lt 1) {
        Write-Host "  Result: TIE (statistically insignificant difference: $([Math]::Abs($avgDiff)) ms, $([Math]::Abs($avgPercent))%)" -ForegroundColor Yellow
    } elseif ($avgDiff -lt 0) {
        Write-Host "  Result: $resultNameA is $([Math]::Abs($avgDiff)) ms faster than $resultNameB ($([Math]::Abs($avgPercent))%)" -ForegroundColor Green
    } elseif ($avgDiff -gt 0) {
        Write-Host "  Result: $resultNameB is $([Math]::Abs($avgDiff)) ms faster than $resultNameA ($([Math]::Abs($avgPercent))%)" -ForegroundColor Green
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
    # Note: $colA and $colB are already defined earlier in the script
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

    Write-Host ""
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
        Write-Host ("$([Math]::Round($metric.ValueA, 1)) ms").PadLeft($valueWidth) -NoNewline -ForegroundColor Gray
        Write-Host (" " * 4) -NoNewline
        Write-Host ("$([Math]::Round($metric.ValueB, 1)) ms").PadLeft($valueWidth) -ForegroundColor Gray
    }

} else {
    # Single or multiple logs: show original format
    foreach ($log in $logsWithTimes) {
        $colName = "$($log.Port)_$($log.Type)_ms"
        $times = $comparison | ForEach-Object { $_.$colName }

        $avg = ($times | Measure-Object -Average).Average
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $median = Get-Median $times
        $stdDev = Get-StdDev $times $avg
        $p95 = Get-Percentile $times 95
        $p99 = Get-Percentile $times 99

        # Display book name (cleaned) for statistics header
        $cleanBookName = $log.BookName -replace '\.epub(_\d{8}(_\d{6})?)?$', '.epub'
        Write-Host "  $($log.Port) ($($log.Type)) - ${cleanBookName}:" -ForegroundColor White
        Write-Host "    Min:     $([Math]::Round($min, 0)) ms" -ForegroundColor Gray
        Write-Host "    Max:     $([Math]::Round($max, 0)) ms" -ForegroundColor Gray
        Write-Host "    Median:  $([Math]::Round($median, 0)) ms" -ForegroundColor Gray
        Write-Host "    Std Dev: $([Math]::Round($stdDev, 1)) ms" -ForegroundColor Gray
        Write-Host "    P95:     $([Math]::Round($p95, 0)) ms" -ForegroundColor Gray
        Write-Host "    P99:     $([Math]::Round($p99, 0)) ms" -ForegroundColor Gray
        Write-Host ""

        $cv = if ($avg -gt 0) { ($stdDev / $avg) * 100 } else { 0 }
        Write-Host "    Coef. of Variation: $([Math]::Round($cv, 1))%" -ForegroundColor $(if ($cv -lt 20) { "Green" } elseif ($cv -lt 40) { "Yellow" } else { "Red" })
        Write-Host ""
    }
}

# Consistency Analysis (for 2-log comparisons only)
if ($logsWithTimes.Count -eq 2) {
    # Note: $cvA and $cvB are already calculated in the Extended Statistics section
    # We need to recalculate them here or store them for use

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
        # Book version comparison - use Type names
        $consistencyNameA = $logA.Type
        $consistencyNameB = $logB.Type
    } elseif ($uniquePorts -eq 1 -and $uniqueTypes -eq 1) {
        # Same device repeatability - use Test numbers
        $consistencyNameA = "Test 1"
        $consistencyNameB = "Test 2"
    } else {
        # Device comparison - use Port names with Type
        $consistencyNameA = "$($logA.Port) ($($logA.Type))"
        $consistencyNameB = "$($logB.Port) ($($logB.Type))"
    }

    Write-Host ""
    Write-Host "Consistency Analysis:" -ForegroundColor Cyan
    Write-Host "  ${consistencyNameA}: Coef. of Variation = $([Math]::Round($cvA, 1))%" -ForegroundColor $(if ($cvA -lt 20) { "Green" } elseif ($cvA -lt 40) { "Yellow" } else { "Red" })
    Write-Host "  ${consistencyNameB}: Coef. of Variation = $([Math]::Round($cvB, 1))%" -ForegroundColor $(if ($cvB -lt 20) { "Green" } elseif ($cvB -lt 40) { "Yellow" } else { "Red" })
}

# Optimization Impact / Performance Highlights (for 2-log comparisons only)
if ($logsWithTimes.Count -eq 2) {
    $logA = $logsWithTimes[0]
    $logB = $logsWithTimes[1]

    # Determine display names based on comparison type
    if ($uniqueTypes -gt 1) {
        # Different book types: show ORIGINAL/OPTIMIZED/CUSTOM
        $displayNameA = $logA.Type
        $displayNameB = $logB.Type
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

        # Only show "faster" if improvement > 1%
        if ($mostImprovedPercent -gt 1) {
            Write-Host "  Most improved:  Page $($mostImproved.Page) - $displayNameB is $($mostImproved.Diff_ms)ms faster ($($mostImproved.Percent))" -ForegroundColor Green
        } else {
            Write-Host "  Most improved:  Page $($mostImproved.Page) - $displayNameB is $($mostImproved.Diff_ms)ms ($($mostImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
        }

        if ($gotWorse -and [Math]::Abs($leastImprovedPercent) -gt 1) {
            Write-Host "  Regression:     Page $($leastImproved.Page) - $displayNameB is $($leastImproved.Diff_ms)ms SLOWER ($($leastImproved.Percent))" -ForegroundColor Red
        } elseif ($gotWorse) {
            Write-Host "  Regression:     Page $($leastImproved.Page) - $displayNameB is $($leastImproved.Diff_ms)ms ($($leastImproved.Percent)) - statistically insignificant" -ForegroundColor Gray
        } else {
            Write-Host "  Least improved: Page $($leastImproved.Page) - $displayNameB is only $($leastImproved.Diff_ms)ms faster ($($leastImproved.Percent))" -ForegroundColor Yellow
        }
    } else {
        # Same book type: Device comparison
        $displayNameA = "Device A"
        $displayNameB = "Device B"
        $sectionTitle = "Performance Highlights"

        # Traditional best/worst based on pure difference
        $bestCase = $comparison | Sort-Object -Property Diff_ms | Select-Object -First 1
        $worstCase = $comparison | Sort-Object -Property Diff_ms -Descending | Select-Object -First 1

        Write-Host "${sectionTitle}:" -ForegroundColor Cyan
        Write-Host "  Best performer:  Page $($bestCase.Page) - $displayNameA faster by $($bestCase.Diff_ms)ms ($($bestCase.Percent))" -ForegroundColor Green
        Write-Host "  Worst performer: Page $($worstCase.Page) - $displayNameB faster by $($worstCase.Diff_ms)ms ($($worstCase.Percent))" -ForegroundColor $(if ([Math]::Abs($worstCase.Diff_ms) -gt 1000) { "Red" } else { "Yellow" })
    }
    Write-Host ""
}

# Total Performance (for 2-log comparisons only)
if ($logsWithTimes.Count -eq 2) {
    # Note: $colA and $colB are already defined earlier in the script
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
    Write-Host "  Total render time ${displayNameA}: $([Math]::Round($totalTimeA / 1000, 2))s ($totalTimeA ms)" -ForegroundColor White
    Write-Host "  Total render time ${displayNameB}: $([Math]::Round($totalTimeB / 1000, 2))s ($totalTimeB ms)" -ForegroundColor White

    if ($totalTimeSaved -ne 0) {
        $percentSaved = if ($totalTimeA -gt 0) { [Math]::Round(([Math]::Abs($totalTimeSaved) / $totalTimeA) * 100, 1) } else { 0 }

        # Only show "faster" if difference > 1%
        if ($percentSaved -gt 1) {
            if ($totalTimeSaved -lt 0) {
                Write-Host "  Time saved: $([Math]::Round([Math]::Abs($totalTimeSaved) / 1000, 2))s ($percentSaved%) - $displayNameA is faster" -ForegroundColor Green
            } else {
                Write-Host "  Time saved: $([Math]::Round([Math]::Abs($totalTimeSaved) / 1000, 2))s ($percentSaved%) - $displayNameB is faster" -ForegroundColor Green
            }
        } else {
            Write-Host "  Time difference: $([Math]::Round([Math]::Abs($totalTimeSaved) / 1000, 2))s ($percentSaved%) - statistically insignificant" -ForegroundColor Gray
        }
    }
    Write-Host "  Pages analyzed: $totalPages" -ForegroundColor White
    Write-Host "  Avg. rendering speed ${displayNameA}: $([Math]::Round(1000 / $avgA, 2)) pages/sec" -ForegroundColor Gray
    Write-Host "  Avg. rendering speed ${displayNameB}: $([Math]::Round(1000 / $avgB, 2)) pages/sec" -ForegroundColor Gray
    Write-Host ""
}

# Export to CSV
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Clean book names: remove .epub extension and individual timestamps
# Handle both formats: "file.epub" and "file.epub_20260313"
$cleanBookNames = ($logsWithTimes | ForEach-Object {
    $name = $_.BookName
    # Remove .epub extension with optional timestamp after it
    $name = $name -replace '\.epub(_\d{8}(_\d{6})?)?$', ''
    $name
}) -join '_vs_'

$sanitizedBookNames = $cleanBookNames -replace '[^\w\-]', '_'
$outputFile = ".\logs\analysis_${sanitizedBookNames}_${timestamp}.csv"

$comparison | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
Write-Host "CSV exported: $outputFile" -ForegroundColor Green

# Ask if user wants to see charts (only for 2-log comparisons)
if ($logsWithTimes.Count -eq 2) {
    Write-Host ""
    $response = Read-Host "Show performance charts? (s/n)"

    if ($response -eq "s" -or $response -eq "S") {
        $logA = $logsWithTimes[0]
        $logB = $logsWithTimes[1]
        $colA = "$($logA.Port)_$($logA.Type)_ms"
        $colB = "$($logB.Port)_$($logB.Type)_ms"

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
        Write-Host "  1. Bar chart (side-by-side comparison)" -ForegroundColor White
        Write-Host "  2. Trend chart (performance over pages)" -ForegroundColor White
        Write-Host "  3. Statistics comparison" -ForegroundColor White
        Write-Host "  4. All charts" -ForegroundColor White
        $chartType = Read-Host "Choose (1-4)"

        if ($chartType -eq "1" -or $chartType -eq "4") {
            Write-Host ""
            Write-Host "Bar Chart Comparison:" -ForegroundColor Cyan
            Write-Host "$displayNameA vs $displayNameB" -ForegroundColor Yellow
            Write-Host ""

            # Shorten names for chart if needed
            $nameA = if ($displayNameA.Length -gt 10) { $displayNameA.Substring(0, 8) + ".." } else { $displayNameA }
            $nameB = if ($displayNameB.Length -gt 10) { $displayNameB.Substring(0, 8) + ".." } else { $displayNameB }

            foreach ($row in $comparison) {
                $timeA = $row.$colA
                $timeB = $row.$colB
                $maxTime = [Math]::Max($timeA, $timeB)

                # Scale to 20 characters max
                $scaleA = if ($maxTime -gt 0) { [int](($timeA / $maxTime) * 20) } else { 0 }
                $scaleB = if ($maxTime -gt 0) { [int](($timeB / $maxTime) * 20) } else { 0 }

                # Display "Cover  :" or "Page X:" with proper alignment
                $pageLabel = if ($row.Page -eq "Cover") { "Cover  :" } else { "Page $($row.Page.ToString().PadLeft(2)):" }
                Write-Host "  $pageLabel" -NoNewline -ForegroundColor Cyan

                # Bar A
                Write-Host "$nameA [" -NoNewline -ForegroundColor Green
                Write-Host ("#" * $scaleA) -NoNewline -ForegroundColor Green
                Write-Host (" " * (20 - $scaleA)) -NoNewline
                Write-Host "] " -NoNewline -ForegroundColor Green
                Write-Host "$($timeA.ToString().PadLeft(4))ms " -NoNewline -ForegroundColor Gray

                # Bar B
                Write-Host "$nameB [" -NoNewline -ForegroundColor Blue
                Write-Host ("#" * $scaleB) -NoNewline -ForegroundColor Blue
                Write-Host (" " * (20 - $scaleB)) -NoNewline
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
        }

        if ($chartType -eq "2" -or $chartType -eq "4") {
            Write-Host ""
            Write-Host "Trend Chart (performance over pages):" -ForegroundColor Cyan
            Write-Host "$displayNameA vs $displayNameB" -ForegroundColor Yellow
            Write-Host ""

            # Find global maximum for scaling
            $globalMax = 0
            foreach ($row in $comparison) {
                $timeA = $row.$colA
                $timeB = $row.$colB
                $globalMax = [Math]::Max([Math]::Max($globalMax, $timeA), $timeB)
            }

            foreach ($row in $comparison) {
                $timeA = $row.$colA
                $timeB = $row.$colB

                # Scale to 20 characters max
                $scaleA = if ($globalMax -gt 0) { [int](($timeA / $globalMax) * 20) } else { 0 }
                $scaleB = if ($globalMax -gt 0) { [int](($timeB / $globalMax) * 20) } else { 0 }

                # Display "Cover  :" or "Page X:" with proper alignment
                $pageLabel = if ($row.Page -eq "Cover") { "Cover  :" } else { "Page $($row.Page.ToString().PadLeft(2)):" }
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
        }

        # Statistics Comparison Chart
        if ($chartType -eq "3" -or $chartType -eq "4") {
            Write-Host ""
            Write-Host "Statistics Comparison Chart:" -ForegroundColor Cyan
            Write-Host "$displayNameA vs $displayNameB" -ForegroundColor Yellow
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

            # Find global maximum for scaling (include Average)
            # Ensure all values are valid numbers, default to 0 if null
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
                # Scale bars (30 chars max - same as Bar Chart and Trend Chart)
                $scaleA = if ($globalMax -gt 0) { [int](($metric.ValueA / $globalMax) * 30) } else { 0 }
                $scaleB = if ($globalMax -gt 0) { [int](($metric.ValueB / $globalMax) * 30) } else { 0 }

                # Column A
                Write-Host "  $($metric.Name.PadRight(8)): $displayNameA [" -NoNewline -ForegroundColor Green
                Write-Host ("#" * $scaleA) -NoNewline -ForegroundColor Green
                Write-Host (" " * (37 - $scaleA)) -NoNewline
                Write-Host "$([Math]::Round($metric.ValueA, 1).ToString().PadLeft(7))ms]" -ForegroundColor Gray

                # Column B
                Write-Host "  $($metric.Name.PadRight(8)): $displayNameB [" -NoNewline -ForegroundColor Blue
                Write-Host ("#" * $scaleB) -NoNewline -ForegroundColor Blue
                Write-Host (" " * (37 - $scaleB)) -NoNewline
                Write-Host "$([Math]::Round($metric.ValueB, 1).ToString().PadLeft(7))ms]" -ForegroundColor Blue
                Write-Host ""
            }

            # Consistency Analysis (Coefficient of Variation)
            Write-Host ""
            Write-Host "  Consistency (Coef. of Variation):" -ForegroundColor Cyan

            $cvMax = [Math]::Max($cvA, $cvB)
            $scaleCVA = if ($cvMax -gt 0) { [int](($cvA / $cvMax) * 30) } else { 0 }
            $scaleCVB = if ($cvMax -gt 0) { [int](($cvB / $cvMax) * 30) } else { 0 }

            Write-Host "  $($displayNameA.PadLeft(15)): [" -NoNewline -ForegroundColor Green
            Write-Host ("#" * $scaleCVA) -NoNewline -ForegroundColor $(if ($cvA -lt 20) { "Green" } elseif ($cvA -lt 40) { "Yellow" } else { "Red" })
            Write-Host (" " * (30 - $scaleCVA)) -NoNewline
            Write-Host "] $([Math]::Round($cvA, 1))%" -ForegroundColor $(if ($cvA -lt 20) { "Green" } elseif ($cvA -lt 40) { "Yellow" } else { "Red" })

            Write-Host "  $($displayNameB.PadLeft(15)): [" -NoNewline -ForegroundColor Blue
            Write-Host ("#" * $scaleCVB) -NoNewline -ForegroundColor $(if ($cvB -lt 20) { "Green" } elseif ($cvB -lt 40) { "Yellow" } else { "Red" })
            Write-Host (" " * (30 - $scaleCVB)) -NoNewline
            Write-Host "] $([Math]::Round($cvB, 1))%" -ForegroundColor $(if ($cvB -lt 20) { "Green" } elseif ($cvB -lt 40) { "Yellow" } else { "Red" })
        }
    }
}

Write-Host ""
Write-Host "Analysis completed" -ForegroundColor Green
Write-Host ""
Write-Host "To view full details:" -ForegroundColor Yellow
Write-Host "  Import-Csv '$outputFile' | Out-GridView" -ForegroundColor Gray
Write-Host ""
