#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EPUB Benchmark Statistical Data Extractor
Extracts metrics from benchmark logs for statistical analysis
"""

import re
import sys
from pathlib import Path
from typing import Dict, List, Optional
from dataclasses import dataclass
from statistics import mean

# Fix Windows console encoding
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except:
        pass

@dataclass
class BenchmarkMetrics:
    """Metrics extracted from a single benchmark log"""
    capture_type: str = ""       # Whatever the user set: ORIGINAL, OPTIMIZED, my-custom-name, ...
    device: str = ""             # COM3, COM4, etc.
    timestamp: str = ""          # 20260315_132355
    firmware_branch: str = ""    # 1.1.1-dev+master

    cover_generated: bool = False
    cover_time_ms: Optional[int] = None

    page_times: List[int] = None
    num_pages: int = 0
    avg_page_time_ms: float = 0.0

    total_images: int = 0

    def __post_init__(self):
        if self.page_times is None:
            self.page_times = []

@dataclass
class BookComparison:
    """
    Side-by-side comparison of two captures (left vs right).
    'left' is always the log whose filename sorts first (e.g. COM3 before COM4).
    The actual type names are stored in left_type / right_type.

    Supported scenarios:
      - Same book,  same device,  different type  (A/B settings test)
      - Same book,  different device, different type  (typical benchmark)
      - Different book, same or different device  (cross-book comparison)
    """
    # Left capture (first log alphabetically)
    left_book: str = ""
    left_type: str = ""
    left_device: str = ""
    left_firmware: str = ""
    left_timestamp: str = ""
    left_cover_success: bool = False
    left_cover_time_ms: Optional[int] = None
    left_page_times: List[int] = None
    left_num_pages: int = 0
    left_avg_page_time_ms: float = 0.0
    left_total_images: int = 0

    # Right capture (second log alphabetically)
    right_book: str = ""
    right_type: str = ""
    right_device: str = ""
    right_firmware: str = ""
    right_timestamp: str = ""
    right_cover_success: bool = False
    right_cover_time_ms: Optional[int] = None
    right_page_times: List[int] = None
    right_num_pages: int = 0
    right_avg_page_time_ms: float = 0.0
    right_total_images: int = 0

    # Derived: left_avg - right_avg  (positive = left is slower, right wins)
    avg_page_time_diff_ms: Optional[float] = None
    avg_page_time_diff_pct: Optional[float] = None

    # Context flags
    same_book: bool = False
    same_device: bool = False

    data_complete: bool = False
    comparison_fair: bool = True   # False when cover generation outcome or books differ

    def __post_init__(self):
        if self.left_page_times is None:
            self.left_page_times = []
        if self.right_page_times is None:
            self.right_page_times = []

        self.same_book   = (self.left_book   == self.right_book)   and bool(self.left_book)
        self.same_device = (self.left_device == self.right_device) and bool(self.left_device)

        if self.left_page_times and self.right_page_times:
            self.left_avg_page_time_ms  = mean(self.left_page_times)
            self.right_avg_page_time_ms = mean(self.right_page_times)
            self.avg_page_time_diff_ms  = self.left_avg_page_time_ms - self.right_avg_page_time_ms
            if self.left_avg_page_time_ms > 0:
                self.avg_page_time_diff_pct = (self.avg_page_time_diff_ms / self.left_avg_page_time_ms) * 100

        # Comparison is unfair if cover outcomes differ OR if the books are different
        if self.left_cover_success != self.right_cover_success:
            self.comparison_fair = False
        if not self.same_book:
            self.comparison_fair = False

        self.data_complete = all([
            self.left_type,
            self.right_type,
            len(self.left_page_times) > 0,
            len(self.right_page_times) > 0,
        ])


def parse_benchmark_log(log_path: Path) -> BenchmarkMetrics:
    """Parse a benchmark log file and extract metrics."""
    if not log_path.exists():
        return BenchmarkMetrics()

    try:
        with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()

        metrics = BenchmarkMetrics()

        # CAPTURE_METADATA: Type=<anything>, Device=COM3, Timestamp=..., Firmware+Branch=...
        meta = re.search(
            r'CAPTURE_METADATA:\s*Type=([^,]+),\s*Device=([^,]+),\s*Timestamp=([^,]+),\s*[Ff]irmware\+[Bb]ranch=([^\r\n]+)',
            content
        )
        if meta:
            metrics.capture_type    = meta.group(1).strip()
            metrics.device          = meta.group(2).strip()
            metrics.timestamp       = meta.group(3).strip()
            metrics.firmware_branch = meta.group(4).strip()
            print(f"[DEBUG] {log_path.name}: Type={metrics.capture_type}, Device={metrics.device}, Firmware={metrics.firmware_branch}")
        else:
            print(f"[WARN]  {log_path.name}: CAPTURE_METADATA not found")

        # Page render times: [14712] [DBG] [ERS] Rendered page in 1795ms
        page_times = [int(m.group(1)) for m in re.finditer(r'\[DBG\]\s*\[ERS\]\s*Rendered page in (\d+)ms', content)]
        metrics.page_times = page_times
        metrics.num_pages = len(page_times)
        if page_times:
            metrics.avg_page_time_ms = mean(page_times)

        # Cover: [DBG] [ERS] Generated cover in 2017ms
        cover = re.search(r'\[DBG\]\s*\[ERS\]\s*Generated cover in (\d+)ms', content)
        if cover:
            metrics.cover_generated = True
            metrics.cover_time_ms = int(cover.group(1))

        # Images count
        image_matches = re.findall(r'Images:\s*(\d+)', content)
        if image_matches:
            metrics.total_images = sum(int(x) for x in image_matches)

        return metrics

    except Exception as e:
        print(f"[ERROR] parsing {log_path}: {e}")
        return BenchmarkMetrics()


def parse_analysis_csv(csv_path: Path) -> Optional[Dict]:
    """
    Parse the analysis CSV.
    Cover success is extracted per device (COM3, COM4, …) by matching column names,
    so it works regardless of what Type name the user chose.
    Returns a dict keyed by device name, e.g.:
      { 'cover_success': {'COM3': False, 'COM4': True}, 'cover_unfair': True, ... }
    """
    if not csv_path.exists():
        print(f"[DEBUG] CSV not found: {csv_path}")
        return None

    try:
        import csv

        print(f"[DEBUG] Reading CSV: {csv_path}")
        with open(csv_path, 'r', encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            rows = list(reader)

        if not rows:
            print("[DEBUG] CSV is empty")
            return None

        columns = list(rows[0].keys())
        print(f"[DEBUG] CSV columns: {columns}")

        # Find Cover row
        cover_row = next((r for r in rows if 'Cover' in r.get('Page', '')), None)
        if cover_row:
            print(f"[DEBUG] Cover row: {cover_row.get('Page', '')}")
        else:
            print("[DEBUG] No Cover row found")

        # Extract cover success per device from CoverSuccess columns
        # Column names look like: COM3_ORIGINAL_ms_CoverSuccess, COM4_OPTIMIZED_ms_CoverSuccess
        cover_success_by_device: Dict[str, bool] = {}
        if cover_row:
            for col in columns:
                if 'CoverSuccess' not in col:
                    continue
                # Extract device prefix (COMx)
                dev_match = re.match(r'(COM\d+)', col)
                if not dev_match:
                    continue
                device = dev_match.group(1)
                raw = cover_row.get(col, '').strip().lower()
                cover_success_by_device[device] = (raw == 'true')
                print(f"[DEBUG] Cover success {device}: {cover_success_by_device[device]}")

        # Build a map from type-name fragment → device (e.g. "ORIGINAL" → "COM3")
        # by parsing column headers like "COM3_ORIGINAL_ms"
        type_to_device: Dict[str, str] = {}
        for col in columns:
            m = re.match(r'(COM\d+)_(.+)_ms$', col)
            if m:
                type_to_device[m.group(2)] = m.group(1)

        # Count page-level winners by device
        wins_by_device: Dict[str, int] = {}
        ties = 0
        for row in rows:
            winner = row.get('Winner', '')
            if winner == 'TIE':
                ties += 1
            elif '[!]' not in winner:
                # Winner value is the type name (e.g. "ORIGINAL", "OPTIMIZED", or custom)
                dev = type_to_device.get(winner)
                if dev:
                    wins_by_device[dev] = wins_by_device.get(dev, 0) + 1

        cover_unfair = '[!]' in (cover_row.get('Winner', '') if cover_row else '')

        result = {
            'total_pages': len(rows),
            'ties': ties,
            'wins_by_device': wins_by_device,
            'cover_success': cover_success_by_device,
            'cover_unfair': cover_unfair,
        }
        print(f"[DEBUG] CSV result: {result}")
        return result

    except Exception as e:
        print(f"[ERROR] parsing CSV {csv_path}: {e}")
        import traceback
        traceback.print_exc()
        return None


def _book_name_from_stem(stem: str) -> str:
    """
    Extract book name from log filename stem.
    Expected format: COMx_<TYPE>_<book_name>_<YYYYMMDD>_<HHMMSS>
    Drops the first two parts (device + type) and last two (date + time).
    """
    parts = stem.split('_')
    if len(parts) > 4:
        return '_'.join(parts[2:-2])
    return stem


def compare_benchmark_logs(log_left: Path, log_right: Path, csv_path: Path = None) -> BookComparison:
    """
    Compare two benchmark logs.
    log_left / log_right must be passed in the desired display order
    (caller sorts by filename so COM3 < COM4, etc.).
    Works for any combination of books/devices/types.
    """
    m_left  = parse_benchmark_log(log_left)
    m_right = parse_benchmark_log(log_right)

    csv_data = parse_analysis_csv(csv_path) if csv_path else None

    # Override cover success from CSV (more reliable than log pattern matching)
    if csv_data:
        cover_by_dev = csv_data.get('cover_success', {})
        if m_left.device in cover_by_dev:
            m_left.cover_generated = cover_by_dev[m_left.device]
        if m_right.device in cover_by_dev:
            m_right.cover_generated = cover_by_dev[m_right.device]

    left_book  = _book_name_from_stem(log_left.stem)
    right_book = _book_name_from_stem(log_right.stem)

    return BookComparison(
        left_book=left_book,
        left_type=m_left.capture_type,
        left_device=m_left.device,
        left_firmware=m_left.firmware_branch,
        left_timestamp=m_left.timestamp,
        left_cover_success=m_left.cover_generated,
        left_cover_time_ms=m_left.cover_time_ms,
        left_page_times=m_left.page_times,
        left_num_pages=m_left.num_pages,
        left_total_images=m_left.total_images,

        right_book=right_book,
        right_type=m_right.capture_type,
        right_device=m_right.device,
        right_firmware=m_right.firmware_branch,
        right_timestamp=m_right.timestamp,
        right_cover_success=m_right.cover_generated,
        right_cover_time_ms=m_right.cover_time_ms,
        right_page_times=m_right.page_times,
        right_num_pages=m_right.num_pages,
        right_total_images=m_right.total_images,
    )


def main():
    import subprocess
    try:
        result = subprocess.run(['py', '--version'], capture_output=True, text=True)
        if result.returncode == 0:
            print(f"[INFO] Using Python: {result.stdout.strip()}")
    except:
        pass

    logs_dir = Path(r"C:\Users\Pablo\github\epub-optimization-benchmark\logs")

    # Find most recent log pair (exclude TEMP files), sorted by mtime descending
    log_files = sorted(
        [f for f in logs_dir.glob("COM*_*.txt") if "TEMP" not in f.name],
        key=lambda x: x.stat().st_mtime, reverse=True
    )

    if len(log_files) < 2:
        print("[ERROR] Not enough log files found (need at least 2)")
        return

    # Take the two most recent, then sort by filename so COM3 < COM4
    recent_pair = sorted(log_files[:2], key=lambda x: x.name)
    log_left, log_right = recent_pair[0], recent_pair[1]

    csv_files = sorted(logs_dir.glob("analysis_*.csv"), key=lambda x: x.stat().st_mtime, reverse=True)
    csv_path = csv_files[0] if csv_files else None

    print("EPUB Benchmark Statistical Data Extractor")
    print("=" * 60)
    print()
    print("Analyzing:")
    print(f"  Left : {log_left.name}")
    print(f"  Right: {log_right.name}")
    if csv_path:
        print(f"  CSV  : {csv_path.name}")
    print()

    cmp = compare_benchmark_logs(log_left, log_right, csv_path)

    print("Analysis Results:")
    print()

    # Show book context
    if cmp.same_book:
        print(f"Book    : {cmp.left_book}")
    else:
        print(f"[WARN] Different books being compared - page times are NOT directly comparable")
        print(f"  Left book : {cmp.left_book}")
        print(f"  Right book: {cmp.right_book}")
    if cmp.same_device:
        print(f"[INFO] Same device ({cmp.left_device}) - A/B settings comparison")
    print()

    def print_capture(label, book, dev, typ, fw, ts, pages, avg, cover_ok, cover_ms):
        header = f"{label} [{dev} - {typ}]"
        if not cmp.same_book:
            header += f"  book: {book}"
        print(f"{header}:")
        print(f"  Firmware  : {fw}")
        print(f"  Timestamp : {ts}")
        print(f"  Pages     : {pages}")
        print(f"  Avg time  : {avg:.1f}ms")
        print(f"  Cover     : {'OK' if cover_ok else 'FAILED'}" + (f" ({cover_ms}ms)" if cover_ms else ""))
        print()

    print_capture("LEFT ", cmp.left_book,  cmp.left_device,  cmp.left_type,  cmp.left_firmware,  cmp.left_timestamp,
                  cmp.left_num_pages,  cmp.left_avg_page_time_ms,  cmp.left_cover_success,  cmp.left_cover_time_ms)
    print_capture("RIGHT", cmp.right_book, cmp.right_device, cmp.right_type, cmp.right_firmware, cmp.right_timestamp,
                  cmp.right_num_pages, cmp.right_avg_page_time_ms, cmp.right_cover_success, cmp.right_cover_time_ms)

    print("COMPARISON:")

    # Fairness reasons
    fair_issues = []
    if not cmp.same_book:
        fair_issues.append("different books")
    if cmp.left_cover_success != cmp.right_cover_success:
        fair_issues.append("cover outcome differs")

    if fair_issues:
        print(f"  Fair    : NO ({', '.join(fair_issues)})")
        # Cover regression/fix note (relevant even for different books)
        if cmp.left_cover_success != cmp.right_cover_success:
            if cmp.right_cover_success and not cmp.left_cover_success:
                print(f"  Cover   : {cmp.right_type} ({cmp.right_device}) generated cover - {cmp.left_type} failed")
                print(f"  [INFO]    This looks like a fix in {cmp.right_type}")
            else:
                print(f"  Cover   : {cmp.left_type} ({cmp.left_device}) generated cover - {cmp.right_type} failed")
                print(f"  [WARN]    Possible regression in {cmp.right_type}!")
    else:
        print(f"  Fair    : YES")

    if cmp.avg_page_time_diff_ms is not None:
        diff = cmp.avg_page_time_diff_ms
        pct  = abs(cmp.avg_page_time_diff_pct)
        if abs(diff) <= 0.5:
            print(f"  Pages   : TIE ({diff:+.1f}ms, {cmp.avg_page_time_diff_pct:+.2f}%)")
            winner_str = "TIE"
        elif diff > 0:
            print(f"  Pages   : {cmp.right_type} faster by {abs(diff):.1f}ms ({pct:.2f}%)")
            winner_str = f"{cmp.right_type} ({cmp.right_device})"
        else:
            print(f"  Pages   : {cmp.left_type} faster by {abs(diff):.1f}ms ({pct:.2f}%)")
            winner_str = f"{cmp.left_type} ({cmp.left_device})"

        if cmp.comparison_fair:
            print(f"  Winner  : {winner_str}")
        else:
            print(f"  Winner  : {winner_str} (informational only - comparison not fair)")
    else:
        print(f"  Pages   : N/A (no data)")

    print()
    if cmp.data_complete:
        print("[OK] Data complete - Ready for statistical analysis")
    else:
        print("[WARN] Data incomplete - Check logs")


if __name__ == '__main__':
    main()
