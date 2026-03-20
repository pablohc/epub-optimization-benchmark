#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EPUB Benchmark Statistical Data Extractor
Extracts metrics from benchmark logs for statistical analysis
"""

import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, asdict
from statistics import mean, stdev

# Fix Windows console encoding
if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except:
        pass

@dataclass
class BenchmarkMetrics:
    """Metrics extracted from benchmark logs"""
    capture_type: str = ""           # ORIGINAL, OPTIMIZED, or custom
    device: str = ""                 # COM3, COM4, etc.
    timestamp: str = ""              # 20260315_124025
    firmware_branch: str = ""        # 1.1.1-dev+master

    # Book metrics
    book_open_ms: Optional[int] = None
    cover_generated: bool = False
    cover_time_ms: Optional[int] = None

    # Page metrics
    page_times: List[int] = None
    num_pages: int = 0
    avg_page_time_ms: float = 0.0

    # Image metrics
    total_images: int = 0

    def __post_init__(self):
        if self.page_times is None:
            self.page_times = []

@dataclass
class BookComparison:
    """Complete comparison of original vs optimized for one book"""
    book_id: str = ""
    book_name: str = ""
    group: str = ""  # group_1_text_only, group_2_intermediate, group_3_many_images

    # Original metrics
    original_type: str = ""
    original_device: str = ""
    original_firmware: str = ""
    original_timestamp: str = ""
    original_book_open_ms: Optional[int] = None
    original_cover_success: bool = False
    original_cover_time_ms: Optional[int] = None
    original_page_times: List[int] = None
    original_num_pages: int = 0
    original_avg_page_time_ms: float = 0.0
    original_total_images: int = 0

    # Optimized metrics
    optimized_type: str = ""
    optimized_device: str = ""
    optimized_firmware: str = ""
    optimized_timestamp: str = ""
    optimized_book_open_ms: Optional[int] = None
    optimized_cover_success: bool = False
    optimized_cover_time_ms: Optional[int] = None
    optimized_page_times: List[int] = None
    optimized_num_pages: int = 0
    optimized_avg_page_time_ms: float = 0.0
    optimized_total_images: int = 0

    # Comparison metrics
    cover_time_diff_ms: Optional[float] = None
    avg_page_time_diff_ms: Optional[float] = None
    avg_page_time_diff_pct: Optional[float] = None

    # Status
    data_complete: bool = False
    comparison_fair: bool = True  # False if cover generation differs

    def __post_init__(self):
        if self.original_page_times is None:
            self.original_page_times = []
        if self.optimized_page_times is None:
            self.optimized_page_times = []

        # Calculate comparisons
        if self.original_page_times and self.optimized_page_times:
            self.original_avg_page_time_ms = mean(self.original_page_times)
            self.optimized_avg_page_time_ms = mean(self.optimized_page_times)
            self.avg_page_time_diff_ms = self.original_avg_page_time_ms - self.optimized_avg_page_time_ms
            if self.original_avg_page_time_ms > 0:
                self.avg_page_time_diff_pct = (self.avg_page_time_diff_ms / self.original_avg_page_time_ms) * 100

        # Check if comparison is fair (both should generate cover or both fail)
        if self.original_cover_success != self.optimized_cover_success:
            self.comparison_fair = False

        # Check if data is complete
        self.data_complete = all([
            self.original_type,
            self.optimized_type,
            len(self.original_page_times) > 0,
            len(self.optimized_page_times) > 0,
            self.original_num_pages == self.optimized_num_pages
        ])

def parse_benchmark_log(log_path: Path) -> BenchmarkMetrics:
    """Parse a benchmark log file and extract metrics"""

    if not log_path.exists():
        return BenchmarkMetrics()

    try:
        with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()

        metrics = BenchmarkMetrics()

        # Extract CAPTURE_METADATA (first line)
        metadata_match = re.search(r'CAPTURE_METADATA:\s*Type=([^,]+),\s*Device=([^,]+),\s*Timestamp=([^,]+),\s*firmware\+Branch=([^\r\n]+)', content)
        if metadata_match:
            metrics.capture_type = metadata_match.group(1).strip()
            metrics.device = metadata_match.group(2).strip()
            metrics.timestamp = metadata_match.group(3).strip()
            metrics.firmware_branch = metadata_match.group(4).strip()

        # Extract page render times
        # Format: [14712] [DBG] [ERS] Rendered page in 1795ms
        page_times = []
        for match in re.finditer(r'\[DBG\]\s*\[ERS\]\s*Rendered page in (\d+)ms', content):
            page_times.append(int(match.group(1)))

        metrics.page_times = page_times
        metrics.num_pages = len(page_times)
        if page_times:
            metrics.avg_page_time_ms = mean(page_times)

        # Extract cover generation (if present)
        # Look for cover generation events
        cover_match = re.search(r'\[DBG\]\s*\[ERS\]\s*Generated cover in (\d+)ms', content)
        if cover_match:
            metrics.cover_generated = True
            metrics.cover_time_ms = int(cover_match.group(1))

        # Extract image count (if present in analysis)
        # This might be in a different format, checking for image-related logs
        image_matches = re.findall(r'Images:\s*(\d+)', content)
        if image_matches:
            metrics.total_images = sum(int(img) for img in image_matches)

        return metrics

    except Exception as e:
        print(f"⚠️  Error parsing {log_path}: {e}")
        return BenchmarkMetrics()

def parse_analysis_csv(csv_path: Path) -> Optional[Dict]:
    """Parse the analysis CSV generated by benchmark tool"""

    if not csv_path.exists():
        return None

    try:
        import csv

        with open(csv_path, 'r', encoding='utf-8') as f:
            reader = csv.DictReader(f)
            rows = list(reader)

        if not rows:
            return None

        # Extract summary statistics
        # Find summary row if exists
        summary_rows = [row for row in rows if row.get('Page', '').startswith('Summary')]

        # Count winners
        ties = sum(1 for row in rows if row.get('Winner', '') == 'TIE')
        orig_wins = sum(1 for row in rows if 'orig' in row.get('Winner', '').lower())
        opt_wins = sum(1 for row in rows if 'int' in row.get('Winner', '').lower() or 'opt' in row.get('Winner', '').lower())

        return {
            'total_pages': len(rows) - 1,  # Exclude header
            'ties': ties,
            'original_wins': orig_wins,
            'optimized_wins': opt_wins
        }

    except Exception as e:
        print(f"⚠️  Error parsing CSV {csv_path}: {e}")
        return None

def compare_benchmark_logs(log1_path: Path, log2_path: Path, csv_path: Path = None) -> BookComparison:
    """Compare two benchmark logs (original vs optimized)"""

    # Parse both logs
    metrics1 = parse_benchmark_log(log1_path)
    metrics2 = parse_benchmark_log(log2_path)

    # Determine which is original and which is optimized
    # Based on capture_type naming convention
    if 'orig' in metrics1.capture_type.lower():
        original_metrics, optimized_metrics = metrics1, metrics2
    elif 'orig' in metrics2.capture_type.lower():
        original_metrics, optimized_metrics = metrics2, metrics1
    else:
        # Fallback: assume first is original
        original_metrics, optimized_metrics = metrics1, metrics2

    # Parse CSV if available
    csv_data = parse_analysis_csv(csv_path) if csv_path else None

    # Create comparison
    comparison = BookComparison(
        book_id=log1_path.stem.split('_')[0],  # Extract from filename
        original_type=original_metrics.capture_type,
        original_device=original_metrics.device,
        original_firmware=original_metrics.firmware_branch,
        original_timestamp=original_metrics.timestamp,
        original_cover_success=original_metrics.cover_generated,
        original_cover_time_ms=original_metrics.cover_time_ms,
        original_page_times=original_metrics.page_times,
        original_num_pages=original_metrics.num_pages,
        original_total_images=original_metrics.total_images,

        optimized_type=optimized_metrics.capture_type,
        optimized_device=optimized_metrics.device,
        optimized_firmware=optimized_metrics.firmware_branch,
        optimized_timestamp=optimized_metrics.timestamp,
        optimized_cover_success=optimized_metrics.cover_generated,
        optimized_cover_time_ms=optimized_metrics.cover_time_ms,
        optimized_page_times=optimized_metrics.page_times,
        optimized_num_pages=optimized_metrics.num_pages,
        optimized_total_images=optimized_metrics.total_images,
    )

    return comparison

def main():
    """Test the extractor with current benchmark logs"""

    # Use py launcher for Windows compatibility
    import subprocess
    try:
        # Test if we're running with py launcher
        result = subprocess.run(['py', '--version'], capture_output=True, text=True)
        if result.returncode == 0:
            print(f"🐍 Using Python: {result.stdout.strip()}")
    except:
        pass

    logs_dir = Path(r"C:\Users\Pablo\github\epub-optimization-benchmark\logs")

    # Find most recent log pair
    log_files = sorted(logs_dir.glob("COM*_*.txt"), key=lambda x: x.stat().st_mtime, reverse=True)

    if len(log_files) < 2:
        print("❌ Not enough log files found")
        return

    # Get the two most recent
    log1 = log_files[0]
    log2 = log_files[1]

    # Find corresponding CSV
    csv_files = sorted(logs_dir.glob("analysis_*.csv"), key=lambda x: x.stat().st_mtime, reverse=True)
    csv_path = csv_files[0] if csv_files else None

    print("🔬 EPUB Benchmark Statistical Data Extractor")
    print("=" * 60)
    print()

    print("📁 Analizando:")
    print(f"  Log 1: {log1.name}")
    print(f"  Log 2: {log2.name}")
    if csv_path:
        print(f"  CSV:  {csv_path.name}")
    print()

    # Compare logs
    comparison = compare_benchmark_logs(log1, log2, csv_path)

    print("📊 Resultados del Análisis:")
    print()
    print(f"Book ID: {comparison.book_id}")
    print()

    print("ORIGINAL:")
    print(f"  Type: {comparison.original_type}")
    print(f"  Device: {comparison.original_device}")
    print(f"  Firmware: {comparison.original_firmware}")
    print(f"  Pages: {comparison.original_num_pages}")
    print(f"  Avg page time: {comparison.original_avg_page_time_ms:.1f}ms")
    print(f"  Cover generated: {comparison.original_cover_success}")
    if comparison.original_cover_time_ms:
        print(f"  Cover time: {comparison.original_cover_time_ms}ms")
    print()

    print("OPTIMIZED:")
    print(f"  Type: {comparison.optimized_type}")
    print(f"  Device: {comparison.optimized_device}")
    print(f"  Firmware: {comparison.optimized_firmware}")
    print(f"  Pages: {comparison.optimized_num_pages}")
    print(f"  Avg page time: {comparison.optimized_avg_page_time_ms:.1f}ms")
    print(f"  Cover generated: {comparison.optimized_cover_success}")
    if comparison.optimized_cover_time_ms:
        print(f"  Cover time: {comparison.optimized_cover_time_ms}ms")
    print()

    print("COMPARISON:")
    print(f"  Avg time diff: {comparison.avg_page_time_diff_ms:.1f}ms")
    print(f"  Avg time diff: {comparison.avg_page_time_diff_pct:.2f}%")
    print(f"  Comparison fair: {comparison.comparison_fair}")
    if not comparison.comparison_fair:
        print(f"  ⚠️  WARNING: Cover generation differs between versions!")
    print()

    if comparison.data_complete:
        print("✅ Data complete - Ready for statistical analysis")
    else:
        print("⚠️  Data incomplete - Check logs")

if __name__ == '__main__':
    main()
