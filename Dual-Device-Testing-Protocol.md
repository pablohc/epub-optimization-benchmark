# Dual Device Testing Protocol

**Objective:** Side-by-side comparison in real time
**Devices:** 2x XTEink X4 (or similar e-readers)
**Date:** ___________

---

## 🎯 Advantages of Dual Testing

| Aspect | Individual Testing | Dual Testing |
|---------|-------------------|--------------|
| **Variables** | Many (warmup, memory) | **Minimal** ✅ |
| **Comparison** | Deferred (memory) | **Real-time** ✅ |
| **Subjectivity** | High | **Low** ✅ |
| **Consistency** | Variable | **High** ✅ |
| **Total Time** | 2x | **1x** ✅ |

---

## 📋 Preparation

### 1.1 Devices

```
Device A (LEFT):
  [ ] Book 1 - ORIGINAL VERSION
  [ ] Book 2 - OPTIMIZED VERSION
  [ ] Book 3 - ORIGINAL VERSION
  [ ] Book 4 - OPTIMIZED VERSION

Device B (RIGHT):
  [ ] Book 1 - OPTIMIZED VERSION
  [ ] Book 2 - ORIGINAL VERSION
  [ ] Book 3 - OPTIMIZED VERSION
  [ ] Book 4 - ORIGINAL VERSION
```

**Note:** Swap versions between devices for each test to eliminate device-specific bias.

### 1.2 Serial Monitor Configuration

```
PC with 2 USB ports:
  COM3 → Device A (LEFT)
  COM4 → Device B (RIGHT)

Output files:
  com3_device_A.txt
  com4_device_B.txt
```

### 1.3 Serial Monitor Software

**Option 1: Arduino IDE (2 windows)**
```
Window 1: COM3 → Save to com3_device_A.txt
Window 2: COM4 → Save to com4_device_B.txt
```

**Option 2: PlatformIO (2 terminals)**
```
Terminal 1: pio device monitor -p COM3
Terminal 2: pio device monitor -p COM4
```

**Option 3: PowerShell Scripts (Recommended)**
```
.\Capture-Dual-Simple.ps1
```

### 1.4 Physical Setup

```
Example configuration for Book 1
┌────────────┐  ┌────────────┐
│            │  │            │
│  Device A  │  │  Device B  │
│            │  │            │
│  ORIGINAL  │  │  OPTIMIZED │
│    BOOK    │  │    BOOK    │
│            │  │            │ 
│            │  │            │
└────────────┘  └────────────┘

**IMPORTANT:** Versions swap between devices for each book:
- Book 1: Device A=ORIGINAL, Device B=OPTIMIZED
- Book 2: Device A=OPTIMIZED, Device B=ORIGINAL
- Book 3: Device A=ORIGINAL, Device B=OPTIMIZED
- Book 4: Device A=OPTIMIZED, Device B=ORIGINAL
```

---

## 🎯 Testing Procedure

### Phase 1: Initial Synchronization

```
1. Both devices powered off
2. Connect both to PC
3. Start serial monitors on both COM ports
4. Verify both are capturing data
5. Restart both devices simultaneously
6. Wait 30 seconds for stabilization
```

### Phase 2: Test by Book

#### Test Book 1

```
Device A: ORIGINAL VERSION
Device B: OPTIMIZED VERSION

Step 1: Synchronized opening
  - Countdown: 3, 2, 1, GO!
  - Both open book AT THE SAME TIME

Step 2: Observe first page
  - Which appears first?
  - Note difference: _____ seconds

Step 3: Synchronized navigation
  - Countdown: 3, 2, 1, GO!
  - Both advance to page 2
  - Note which appears first
  - Repeat to page 10

Step 4: Cover generation
  - Both navigate to HOME
  - Which generates cover first?
```

#### Test Book 2

```
Device A: OPTIMIZED VERSION  (SWAP)
Device B: ORIGINAL VERSION  (SWAP)

Repeat steps...
```

#### Test Books 3 and 4

```
Continue swapping versions...
```

---

## 📊 Dual Testing Record Sheet

**Date:** ___________  **Start Time:** _______

### Test Book 1

| Page | Device A (ORIGINAL VERSION) | Device B (OPTIMIZED VERSION) | Winner? | Difference (s) |
|------|----------------------|----------------------|---------|---------------|
| **Open** | | | A/B ❌ Tie | |
| 1 | | | A/B ❌ Tie | |
| 2 | | | A/B ❌ Tie | |
| 3 | | | A/B ❌ Tie | |
| 4 | | | A/B ❌ Tie | |
| 5 | | | A/B ❌ Tie | |
| 6 | | | A/B ❌ Tie | |
| 7 | | | A/B ❌ Tie | |
| 8 | | | A/B ❌ Tie | |
| 9 | | | A/B ❌ Tie | |
| 10 | | | A/B ❌ Tie | |
| **Cover** | | | A/B ❌ Tie | |

**Winner:** ORIGINAL VERSION ___ / OPTIMIZED VERSION ___ / Tie ___

**Visual observations:**
-

---

### Repeat for books 2, 3, 4...

---

## 🎯 Scoring System

### Per Test

```
Score A = (Pages won by A) × 10
Score B = (Pages won by B) × 10

If tie = 0 points for both
```

### Example

| Book | ORIGINAL VERSION | OPTIMIZED VERSION | Ties | Winner |
|------|-----------|-----------|------|---------|
| Book 1 | 2 | 2 | 8 | **TIE** |
| Book 2 | 1 | 3 | 7 | **B +2** |
| Book 3 | 0 | 5 | 6 | **B +5** |
| Book 4 | 4 | 1 | 6 | **A +3** |

**Total:** ORIGINAL VERSION +7 vs OPTIMIZED VERSION +10

---

## 📹 Optional: Video Recording

### For visual evidence

```
1. Set up camera facing devices
2. Record entire session
3. Timestamp in video to sync with logs
4. Analyze frame-by-frame to validate manual measurements
```

### Video benefits

- **Objective evidence** of differences
- **Can be reviewed** later
- **Shows subtleties** not captured in logs
- **Validates** manual measurements

---

## 🔍 Post-Test Data Analysis

### 1. Compare Logs

```
For each page:
  Log A (COM3): [timestamp] Rendered page in Xms
  Log B (COM4): [timestamp] Rendered page in Yms

  Real difference = |Log A - Log B|
```

### 2. Compare with Manual Measurements

```
If manual says "A won by 2 seconds":
  → Verify in logs that difference is ~2000ms
  → If NOT → Investigate why
```

### 3. Identify Patterns

```
If ORIGINAL VERSION always wins:
  → Optimization not effective for this book

If OPTIMIZED VERSION always wins:
  → Optimization working well

If mixed results:
  → Depends on page/image type
```

---

## ⚠️ Precautions

### 1. Synchronization

**Problem:** Difficult to press exactly at the same time

**Solution:**
```
- Use voice countdown
- Practice synchronization before real test
- Accept ±0.5 seconds error
```

### 2. Interference

**Problem:** Two USB devices may overload PC

**Solution:**
```
- Use separate USB ports (not hub)
- Verify both COM ports are detected
- Test monitors before test
```

### 3. Hidden Variables

**Problem:** One device may have different firmware/conditions

**Solution:**
```
- Both devices same model
- Both with same firmware version
- Restart both before test
- Verify similar free memory
```

---

## ✅ Pre-Test Checklist

### Devices
- [ ] Both devices ready
- [ ] Both with same firmware
- [ ] Both restarted
- [ ] Similar free memory on both
- [ ] Books loaded on correct devices

### Serial Monitors
- [ ] COM3 detected and working
- [ ] COM4 detected and working
- [ ] Output files configured
- [ ] Test data capture (record 10 seconds)

### Space and Preparation
- [ ] Physical space prepared (left/right)
- [ ] Record sheet printed or digital
- [ ] Camera ready (optional)
- [ ] Stopwatch ready

### Knowledge
- [ ] Know which book goes on each device
- [ ] Know which is A (left) and which is B (right)
- [ ] Know the order of books
- [ ] Practiced synchronized countdown

---

## 🏆 Conclusion

**Dual testing is SUPERIOR METHOD because:**

1. ✅ Eliminates time variables
2. ✅ Objective real-time comparison
3. ✅ Minimal subjectivity
4. ✅ Faster (1x vs 2x)
5. ✅ Clear visual evidence
6. ✅ Can be recorded on video

**Recommendation:** USE DUAL TESTING for final validation

---

**Ready for dual testing?**
