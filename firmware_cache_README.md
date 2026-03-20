# Firmware Cache System

## Overview
The firmware cache system solves the problem of firmware detection timeouts when devices are already connected and running from previous capture sessions. It uses a **two-phase detection approach**:

1. **Temporary Detection** (during reset) - In-memory detection
2. **Definitive Association** (during interactive identification) - Permanent COM→firmware mapping

## How It Works

### Cache Files
- **Location**: `firmware_cache/` directory (created automatically)
- **Filename format**: `firmware_COM{port}.json` (e.g., `firmware_COM3.json`, `firmware_COM4.json`)
- **Content**: JSON file with definitive COM port → firmware association
- **Purpose**: Persistent storage for COM→firmware mappings across sessions

### Smart Detection System

**Step 1: Read from Existing Logs (BEFORE reset)**
- System searches for recent log files in `logs/` directory
- Pattern: `*COM{port}*.txt` (max age: 60 minutes)
- Extracts firmware info from `CAPTURE_METADATA` line
- **Result**: Instant firmware info without any device communication
- **Example**: "COM3 : 1.2.3+master (from log)"

**Step 2: Live Detection (if no logs found)**
- User is prompted to ensure devices are running
- Opens port briefly (without reset)
- Reads firmware info from device startup message (8 second timeout)
- Accumulates all received data and searches for firmware pattern
- **Result**: Firmware info for new/unlogged devices
- **Example**: "COM3 : 1.2.3+master (detected)"

**Step 3: Device Reset (AFTER firmware detection)**
- Devices are reset via DTR signal
- 3 second wait for reboot
- Firmware info is already known from Step 1 or 2

**Step 4: Definitive Association (Interactive Phase)**
- User identifies LEFT device by pressing button
- **System saves definitive association**: COM3 → Firmware+Branch
- User identifies RIGHT device by pressing button
- **System saves definitive association**: COM4 → Firmware+Branch
- These associations are **permanent** (until cache expires or is deleted)

### Detection Flow

**For Dual Device Capture:**
1. **Read Logs** - Searches `logs/` for recent files (max 60 min old)
   - Finds `COM3_ORIGINAL_BOOK_20250315_123456.txt`
   - Extracts: "COM3 : 1.2.3+master (from log)"
   - Finds `COM4_ORIGINAL_BOOK_20250315_123456.txt`
   - Extracts: "COM4 : 1.2.4+dev (from log)"
2. **Live Detection** (if needed) - For devices without recent logs
   - Shows prompt: "Press ENTER when ready to detect firmware..."
   - User ensures devices are running
   - Opens COM3 → Detects firmware (8s timeout) → Closes
   - Shows "COM3 : 1.2.3+master (detected)"
3. **Device Reset** - Resets all devices (AFTER firmware is known)
4. **Port Opening** - Opens ports for button monitoring
   - Shows "Opened COM3 - Firmware: 1.2.3+master"
   - Shows "Opened COM4 - Firmware: 1.2.4+dev"
5. **Interactive Identification** - User confirms LEFT/RIGHT devices
   - **LEFT confirmed → Silently saves COM3 → Firmware to cache**
   - **RIGHT confirmed → Silently saves COM4 → Firmware to cache**
6. **Capture Start** - Uses definitive associations from cache

**For Single Device Capture:**
1. **Port Opening** - Device port is opened
2. **Cache Check** - Uses definitive association if available
3. **Detection** - If no cache, detects and saves association
4. **Capture Start** - Begins with known firmware

**For Subsequent Sessions (Skip Reset):**
1. **No Reset** - Devices already connected
2. **Cache Lookup** - Reads existing COM→firmware associations
3. **Direct Capture** - Uses cached associations immediately

### Cache Logic

1. **First Session** (Fresh devices):
   - Temporary detection during reset (in memory)
   - Definitive association saved during identification
   - Cache file created with COM→firmware mapping
   - No detection timeout during capture

2. **Subsequent Sessions** (Same devices):
   - Cache exists and is recent (< 1 hour)
   - Uses cached associations immediately
   - No reset needed → No re-detection needed

3. **Cache Expiration**:
   - Cache expires after 1 hour
   - Next session re-detects and creates new associations

### Cache Invalidation
The cache is automatically invalidated when:
- Cache is older than 1 hour
- Cache file is corrupted or invalid
- Manually deleted by user

## Benefits

1. **Log-Based Detection**: Reads firmware from existing logs - instant and reliable
2. **Interactive Detection**: User prompted when devices need firmware detection
3. **No Detection Delays**: Devices detected while running, not after reset
4. **Longer Timeout**: 8 second timeout for reliable firmware detection
5. **Data Accumulation**: Accumulates all received data for robust pattern matching
6. **Works Before Reset**: Firmware known BEFORE device reset
7. **Silent Associations**: Definitive COM→firmware mappings saved without extra prompts
8. **Consistent Firmware Info**: Same firmware used across multiple captures
9. **Graceful Fallback**: If detection fails, first capture will detect firmware
10. **Automatic Updates**: Cache updates when valid firmware is detected

## File Format Example

```json
{
  "ComPort": "COM3",
  "Firmware": "1.2.3",
  "Branch": "master",
  "Timestamp": "2026-03-15 14:30:45"
}
```

## Troubleshooting

### Firmware showing as "Unknown"
- Check if device is sending firmware info on startup
- Look for `[DBG] [MAIN] Starting CrossPoint version X.X.X+branch` in logs
- Try disconnecting and reconnecting device to force re-detection

### Wrong firmware detected
- Delete the cache file: `firmware_cache/firmware_COM{port}.json`
- Re-run capture to force re-detection

### Cache not updating
- Ensure device fully disconnects (port closes) between sessions
- Check `firmware_cache/` directory for stale files
- Delete cache files manually if needed

## Implementation Details

### Functions Added
- `Get-FirmwareCacheFilePath`: Returns cache file path for a COM port
- `Get-CachedFirmware`: Reads and validates cache file (1-hour expiration)
- `Save-FirmwareCache`: Saves definitive COM→firmware association to cache file
- `Get-FirmwareFromExistingLogs`: Reads firmware from previous session logs
- `Get-TempFirmwareDetection`: Temporary firmware detection (in memory only)
- `Detect-FirmwareFromDevice`: Detects firmware from live device (with port opening)
- `Get-FirmwareForDevice`: Main function that handles cache lookup + detection logic

### Modified Functions
- `Start-SingleDeviceCapture`: Uses cached firmware instead of live detection
- `Start-DualDeviceCapture`: Log-based detection system
  - Step 1: Read firmware from existing logs (before reset)
  - Step 2: Live detection only if no logs found
  - Step 3: Device reset (after firmware is known)
  - Step 4: Definitive association during interactive identification

### Changes to Capture Logic
- **Dual Device - Normal Mode**: Log-based detection system
  - Step 1: Read firmware from logs (instant, no device communication)
  - Step 2: Live detection only for devices without recent logs
  - Step 3: Reset happens AFTER firmware is known
  - Step 4: Definitive COM→firmware associations saved during button identification
- **Dual Device - Skip Reset Mode**: Uses existing cache associations
- **Single Device**: Firmware detected during capture setup
- Removed: Firmware detection buffers and timeout logic from capture loops
- Added: Log-based firmware reading + fallback live detection
- Result: Faster workflow, no detection delays, reliable firmware info