# Statistical Testing Plan - Integration with EPUB Benchmark Tool

## 🎯 Objective

Obtain a statistically valid sample (n=20 books) to validate EPUB optimization with a 95% confidence level.

## 📊 Sample Distribution

| Group | Quantity | Characteristics | Expected Improvement |
|-------|----------|----------------|---------------------|
| **1. Text Only** | 5 books | 0-5 images <100px, <5MB | 0-5% improvement |
| **2. Intermediate** | 8 books | 5-20 images 100-500px, 5-30MB | 15-35% improvement |
| **3. Many Images** | 7 books | 20+ images >500px, >30MB | 40-70% improvement |

**Total:** 20 books

---

## 🚀 Workflow with Your Existing Tool

### Phase 1: Book Organization

```powershell
# Create folder structure
$base = "C:\Users\Pablo\Downloads\eBooks\PR-1224\statistical_testing"
New-Item -ItemType Directory -Force -Path "$base\group_1_text_only"
New-Item -ItemType Directory -Force -Path "$base\group_2_intermediate"
New-Item -ItemType Directory -Force -Path "$base\group_3_many_images"
```

### Phase 2: Capture with EPUB-Optimization-Benchmark.ps1

For each book in each group:

```powershell
# 1. Navigate to the tool
cd C:\Users\Pablo\github\epub-optimization-benchmark

# 2. Run dual capture
.\EPUB-Optimization-Benchmark.ps1

# 3. Select [2] Capture - Dual Devices

# 4. For BOOK 1 from GROUP 1 (Text Only):
#    LEFT device: ORIGINAL (option 1)
#    RIGHT device: OPTIMIZED (option 2)

# 5. Capture 20-30 synchronized pages

# 6. Press Ctrl+C to stop

# 7. Analysis is generated automatically
```

### Phase 3: Archive Results

```powershell
# After each capture, archive logs:

# Get most recent timestamp
$latest = Get-ChildItem C:\Users\Pablo\github\epub-optimization-benchmark\logs\*.txt |
          Sort-Object LastWriteTime -Descending |
          Select-Object -First 2

# Move to organized structure
$group = "group_1_text_only"  # Adjust by group
$book_id = "book_01_short_name"

$dest = "C:\Users\Pablo\Downloads\eBooks\PR-1224\statistical_testing\$group\$book_id"
New-Item -ItemType Directory -Force -Path "$dest\original"
New-Item -ItemType Directory -Force -Path "$dest\optimized"

# Move logs (adjust names according to timestamp)
Copy-Item $latest[0].FullName "$dest\original\log_serial.txt"
Copy-Item $latest[1].FullName "$dest\optimized\log_serial.txt"

# Also copy analysis CSV if exists
Copy-Item C:\Users\Pablo\github\epub-optimization-benchmark\logs\analysis_*.csv $dest\
```

---

## 📋 Book Registration Template

Create `testing_record.md` in each book folder:

```markdown
# Book: [BOOK NAME]

**Group:** [1/2/3]
**ID:** book_XX_name
**Test Date:** 2026-03-XX

## EPUB Metadata

- **Filename:** filename.epub
- **Original size:** XX MB
- **Optimized size:** XX MB
- **Reduction:** XX%
- **Image count:** XX
- **Max resolution:** XXXxXXX
- **Formats:** progressive_jpeg, png, etc.

## Problems Observed (Original)

- Broken images: [quantity]
- Pages with issues: [list]
- Failure type: [JPEG Decode failed / cache buffer / etc.]

## Analysis Results

- **Opening improvement:** XX%
- **Time saved:** XXX ms
- **Pages analyzed:** XX

## Manual Observations

[Notes about visual quality, unusual behavior, etc.]
```

---

## 🔧 Automation Script (Optional)

Create `archive_results.ps1`:

```powershell
param(
    [Parameter(Mandatory=$true)]
    [string]$Group,

    [Parameter(Mandatory=$true)]
    [string]$BookID,

    [Parameter(Mandatory=$true)]
    [string]$BookName
)

# Paths
$benchmarkLogs = "C:\Users\Pablo\github\epub-optimization-benchmark\logs"
$baseOutput = "C:\Users\Pablo\Downloads\eBooks\PR-1224\statistical_testing"

# Create structure
$dest = "$baseOutput\$Group\$BookID"
New-Item -ItemType Directory -Force -Path "$dest\original" | Out-Null
New-Item -ItemType Directory -Force -Path "$dest\optimized" | Out-Null

# Get most recent logs
$latestLogs = Get-ChildItem $benchmarkLogs\COM*_*.txt |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 2

if ($latestLogs.Count -lt 2) {
    Write-Error "Not enough recent logs found"
    exit 1
}

# Copy logs
Copy-Item $latestLogs[0].FullName "$dest\original\log_serial.txt" -Force
Copy-Item $latestLogs[1].FullName "$dest\optimized\log_serial.txt" -Force

# Copy analysis CSV if exists
$latestCSV = Get-ChildItem $benchmarkLogs\analysis_*.csv |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1

if ($latestCSV) {
    Copy-Item $latestCSV.FullName "$dest\analysis.csv" -Force
}

# Create basic metadata
$metadata = @"
# Book: $BookName

**Group:** $Group
**ID:** $BookID
**Test Date:** $(Get-Date -Format "yyyy-MM-dd")

## Files

- Original log: original/log_serial.txt
- Optimized log: optimized/log_serial.txt
- Analysis: analysis.csv (if exists)

"@

Set-Content "$dest\README.md" $metadata

Write-Host "✅ Archived: $BookID" -ForegroundColor Green
Write-Host "   Logs copied to: $dest"
```

**Usage:**

```powershell
.\archive_results.ps1 -Group "group_1_text_only" -BookID "book_01_novel_example" -BookName "Example Novel - Author"
```

---

## 📊 Testing Checklist

### Group 1: Text Only (5 books)
- [ ] Book 1: Literary novel without images
- [ ] Book 2: Technical essay
- [ ] Book 3: Textbook without illustrations
- [ ] Book 4: Biography (cover only)
- [ ] Book 5: Play

**Expected:** 0-5% improvement (not significant)

### Group 2: Intermediate (8 books)
- [ ] Book 1: Light manga (10-15 images)
- [ ] Book 2: Children's illustrated book
- [ ] Book 3: Technical manual with diagrams
- [ ] Book 4: Textbook with graphics
- [ ] Book 5: Comic book (20-30 pages)
- [ ] Book 6: Art book (medium photos)
- [ ] Book 7: Magazine
- [ ] Book 8: Compiled blog (mixed images)

**Expected:** 15-35% improvement

### Group 3: Many Images (7 books)
- [ ] Book 1: ✅ **COMPLETED** - Sentenced to Be a Hero
- [ ] Book 2: Complete manga volume
- [ ] Book 3: Complete comic
- [ ] Book 4: Photography book
- [ ] Book 5: Art book
- [ ] Book 6: Product catalog
- [ ] Book 7: Scanned document archive

**Expected:** 40-70% improvement

---

## 📈 Final Statistical Analysis

When all 20 books are complete, run:

```python
# Your Python script will read the entire structure and generate:
# 1. Complete comparison table
# 2. Statistics by group
# 3. Paired t-test
# 4. ANOVA between groups
# 5. Confidence intervals
# 6. Graphs (box plots, scatter plots)
```

---

## ⏱️ Estimated Time

- **Per book:** ~15 minutes (preparation + 20 pages capture + archiving)
- **Total:** 20 books × 15 min = **5 hours**
- **With automation:** ~3-4 hours

---

## ✅ Next Steps

1. **Select 5 "Text Only" books** - Novels without images
2. **Select 8 "Intermediate" books** - With moderate images
3. **Select 6 more "Many Images" books** (you already have 1)
4. **Run testing** using your existing tool
5. **Archive results** using the script or manually
6. **Notify me** when you have 5-10 books for preliminary analysis

---

## 🎯 Success Criteria

Testing will be **STATISTICALLY VALID** when:

- ✅ n ≥ 20 total books
- ✅ Each group has ≥ 4 books
- ✅ Complete data (original + optimized)
- ✅ p < 0.05 in paired t-test
- ✅ 95% confidence intervals calculated

**Ready to start with Group 1 (Text Only)?**
