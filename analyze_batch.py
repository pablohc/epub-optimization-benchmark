#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EPUB Benchmark Batch Analyzer
Reads analysis JSONs from logs/ and generates aggregate PR report.

Usage:
    py analyze_batch.py
    py analyze_batch.py --logs <path>  --pr <path>
"""

import json
import re
import sys
import argparse
from pathlib import Path
from statistics import mean, stdev
from datetime import datetime
from collections import defaultdict

if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

# ── Default paths ─────────────────────────────────────────────────────────────
DEFAULT_LOGS_DIR = Path(__file__).parent / "logs"
DEFAULT_PR_DIR   = Path(r"C:\Users\Pablo\Downloads\eBooks\PR-1224")

# Group labels from PR-1224 test-books folder naming convention
PR_GROUP_LABELS = {
    "01-txt-only":  "Group 1 — Text Only",
    "02-img-txt":   "Group 2 — Image + Text",
    "03-more-test": "Group 3 — Extended Test",
}


# ── Data loading ──────────────────────────────────────────────────────────────

def load_all_jsons(logs_dir: Path) -> list:
    """Load all analysis_*.json files, sorted by filename (chronological)."""
    results = []
    for f in sorted(logs_dir.glob("analysis_*.json")):
        try:
            with open(f, encoding='utf-8') as fp:
                data = json.load(fp)
            data['_file'] = f.name
            results.append(data)
        except Exception as e:
            print(f"  ⚠️  Skipping {f.name}: {e}")
    return results


def deduplicate(analyses: list) -> dict:
    """
    For each unique (book, label_a, label_b) keep only the most recent analysis.
    - ORIGINAL/OPTIMIZED are treated as standard labels
    - Custom labels must match exactly to be considered the same comparison
    - Different custom names produce separate entries (e.g. my-v1 vs my-v2 ≠ my-v1 vs my-v3)
    Returns dict keyed by (book, label_a, label_b).
    """
    groups = defaultdict(list)
    for a in analyses:
        book    = a['meta']['book'].strip()
        label_a = a['meta']['a']['label']
        label_b = a['meta']['b']['label']
        groups[(book, label_a, label_b)].append(a)

    return {
        k: max(v, key=lambda x: x['meta']['timestamp'])
        for k, v in groups.items()
    }


# ── Group detection ───────────────────────────────────────────────────────────

def get_group_from_folder(epub_folder: str | None) -> str:
    """
    Derive group label directly from the epub_folder stored in the JSON.
    e.g. "orig-01-txt-only" or "int-01-txt-only" → "Group 1 — Text Only"

    The folder name comes from the "Loading ePub:" line in the device log:
      [DBG] [EBP] Loading ePub: /01 - Original/orig-01-txt-only/Book.epub
    so it is always exact — no fuzzy matching needed.
    """
    if not epub_folder:
        return "Uncategorized"

    # Strip orig-/int- prefix to get the group key: "01-txt-only"
    folder = epub_folder.lower()
    for prefix in ('orig-', 'int-'):
        if folder.startswith(prefix):
            folder = folder[len(prefix):]
            break

    return PR_GROUP_LABELS.get(folder, epub_folder)


# ── Statistics ────────────────────────────────────────────────────────────────

def aggregate_stats(analyses_by_key: dict) -> dict:
    diffs_pct = [a['summary']['avg_diff_percent'] for a in analyses_by_key.values()]
    diffs_ms  = [a['summary']['avg_diff_ms']      for a in analyses_by_key.values()]

    b_win_pages = sum(a['summary']['b_wins'] for a in analyses_by_key.values())
    a_win_pages = sum(a['summary']['a_wins'] for a in analyses_by_key.values())
    tie_pages   = sum(a['summary']['ties']   for a in analyses_by_key.values())

    b_win_books = sum(1 for a in analyses_by_key.values()
                      if a['summary']['b_wins'] > a['summary']['a_wins'])
    a_win_books = sum(1 for a in analyses_by_key.values()
                      if a['summary']['a_wins'] > a['summary']['b_wins'])

    return {
        'n':              len(diffs_pct),
        'avg_pct':        mean(diffs_pct),
        'stdev_pct':      stdev(diffs_pct) if len(diffs_pct) > 1 else 0.0,
        'min_pct':        min(diffs_pct),
        'max_pct':        max(diffs_pct),
        'avg_ms':         mean(diffs_ms),
        'b_win_pages':    b_win_pages,
        'a_win_pages':    a_win_pages,
        'tie_pages':      tie_pages,
        'b_win_books':    b_win_books,
        'a_win_books':    a_win_books,
        'tie_books':      len(diffs_pct) - b_win_books - a_win_books,
    }


# ── Markdown generation ───────────────────────────────────────────────────────

def _short_book(name: str, max_len: int = 50) -> str:
    """Remove trailing identifiers like [3967] (r1.7) and truncate."""
    s = re.sub(r'\s*[\[\(]\s*\d{3,}.*$', '', name).strip()
    return s[:max_len] + ('…' if len(s) > max_len else '')


def generate_markdown(analyses_by_key: dict, pr_dir: Path = None) -> str:
    lines = []
    now   = datetime.now().strftime('%Y-%m-%d %H:%M')

    # Infer A/B labels from first entry
    first   = next(iter(analyses_by_key.values()))
    label_a = first['meta']['a']['label']
    label_b = first['meta']['b']['label']
    fw_a    = f"{first['meta']['a']['firmware']}+{first['meta']['a']['branch']}"
    fw_b    = f"{first['meta']['b']['firmware']}+{first['meta']['b']['branch']}"

    # ── Header ────────────────────────────────────────────────────────────────
    lines += [
        "# EPUB Optimization Benchmark — PR Analysis Report",
        "",
        f"**Generated:** {now}  ",
        f"**A (baseline):** `{label_a}` — `{fw_a}`  ",
        f"**B (optimized):** `{label_b}` — `{fw_b}`  ",
        f"**Books analyzed:** {len(analyses_by_key)}",
        "",
    ]

    # ── Executive summary ────────────────────────────────────────────────────
    st = aggregate_stats(analyses_by_key)
    overall = "**B is faster on average**" if st['avg_pct'] < -1 else \
              "**A is faster on average**" if st['avg_pct'] >  1 else \
              "**Statistically insignificant overall difference (< 1%)**"

    lines += [
        "## Executive Summary",
        "",
        f"{overall}",
        "",
        "| Metric | Value |",
        "|--------|------:|",
        f"| Avg page render diff (B−A) | **{st['avg_pct']:+.1f}%** |",
        f"| Std deviation              | {st['stdev_pct']:.1f}% |",
        f"| Range                      | {st['min_pct']:+.1f}% → {st['max_pct']:+.1f}% |",
        f"| Avg diff per page          | {st['avg_ms']:+.1f} ms |",
        f"| Books: B wins / A wins / TIE | {st['b_win_books']} / {st['a_win_books']} / {st['tie_books']} |",
        f"| Pages:  B wins / A wins / TIE | {st['b_win_pages']} / {st['a_win_pages']} / {st['tie_pages']} |",
        "",
    ]

    # ── Per-book results by group ─────────────────────────────────────────────
    by_group = defaultdict(list)
    for key, a in analyses_by_key.items():
        epub_folder = a['meta']['a'].get('epub_folder') or a['meta']['b'].get('epub_folder')
        group = get_group_from_folder(epub_folder)
        by_group[group].append(a)

    lines += ["## Results by Book", ""]

    for group_name in sorted(by_group.keys()):
        group_list = sorted(by_group[group_name], key=lambda a: a['meta']['book'])

        lines += [
            f"### {group_name}",
            "",
            "| Book | A avg ms | B avg ms | Diff ms | % | A wins | B wins | Ties | ⚠️ |",
            "|------|--------:|--------:|-------:|--:|------:|------:|-----:|:---:|",
        ]

        for a in group_list:
            s     = a['summary']
            book  = _short_book(a['meta']['book'])
            d_ms  = s['avg_diff_ms']
            d_pct = s['avg_diff_percent']
            unfair = "⚠️" if s['has_unfair_pages'] else "✅"

            # Bold B wins if B wins overall for this book
            bw = f"**{s['b_wins']}**" if s['b_wins'] > s['a_wins'] else str(s['b_wins'])
            aw = f"**{s['a_wins']}**" if s['a_wins'] > s['b_wins'] else str(s['a_wins'])

            lines.append(
                f"| {book} "
                f"| {s['avg_a_ms']:.0f} | {s['avg_b_ms']:.0f} "
                f"| {d_ms:+.0f} | {d_pct:+.1f}% "
                f"| {aw} | {bw} | {s['ties']} | {unfair} |"
            )

        lines.append("")

    # ── Unfair comparison detail ──────────────────────────────────────────────
    unfair_entries = [(k, a) for k, a in analyses_by_key.items() if a['summary']['has_unfair_pages']]

    if unfair_entries:
        lines += [
            "## ⚠️ Unfair Comparison Details",
            "",
            "> Pages marked ⚠️ have content discrepancies between A and B.",
            "> - **Winner had fewer images/failed cover** → result may be *misleading* (did less work)",
            "> - **Loser had fewer images/failed cover** → result is *conservative* (winner did more work and still won)",
            "",
        ]

        for _key, a in sorted(unfair_entries, key=lambda x: x[1]['meta']['book']):
            book        = _short_book(a['meta']['book'])
            unfair_pgs  = [p for p in a['pages'] if p['unfair']]
            lines.append(f"**{book}**")

            for p in unfair_pgs:
                w     = p['winner']
                img_a = p['a_images']
                img_b = p['b_images']

                if 'a_cover_success' in p:
                    sa = "OK"    if p['a_cover_success'] else "FAIL"
                    sb = "OK"    if p['b_cover_success'] else "FAIL"
                    misleading = (w == 'B' and not p['b_cover_success']) or \
                                 (w == 'A' and not p['a_cover_success'])
                    tag = "*misleading*" if misleading else "*conservative*"
                    lines.append(f"- Cover — A: {sa}, B: {sb} → winner: {w} ({tag})")
                else:
                    misleading = (w == 'B' and img_b < img_a) or \
                                 (w == 'A' and img_a < img_b)
                    tag = "*misleading*" if misleading else "*conservative*"
                    lines.append(
                        f"- Page {p['page']} — A_img: {img_a}, B_img: {img_b} "
                        f"→ winner: {w} ({tag})"
                    )

            lines.append("")

    # ── Footer ────────────────────────────────────────────────────────────────
    lines += [
        "---",
        "*Generated by [EPUB Optimization Benchmark](https://github.com/pablohc/epub-optimization-benchmark)*",
    ]

    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="EPUB Benchmark Batch Analyzer")
    parser.add_argument('--logs', type=Path, default=DEFAULT_LOGS_DIR,
                        help=f"Path to logs directory (default: {DEFAULT_LOGS_DIR})")
    parser.add_argument('--pr',   type=Path, default=DEFAULT_PR_DIR,
                        help=f"Path to PR-1224 directory for book group detection")
    parser.add_argument('--out',  type=Path, default=None,
                        help="Output markdown file (default: logs/batch_analysis_report.md)")
    args = parser.parse_args()

    out_path = args.out or (args.logs / "batch_analysis_report.md")

    print("🔬 EPUB Benchmark Batch Analyzer")
    print("=" * 60)
    print(f"📂 Logs dir : {args.logs}")
    print(f"📂 PR dir   : {args.pr}")
    print()

    # Load
    analyses = load_all_jsons(args.logs)
    if not analyses:
        print("❌ No analysis_*.json files found.")
        return

    print(f"📄 Found {len(analyses)} JSON file(s)")

    # Deduplicate
    by_key = deduplicate(analyses)
    print(f"📚 Unique comparisons: {len(by_key)}")
    print()

    for (book, la, lb), a in sorted(by_key.items(), key=lambda x: x[0][0]):
        s = a['summary']
        print(f"  {_short_book(book, 42):42}  {s['avg_diff_percent']:+6.1f}%  "
              f"[A:{s['a_wins']} B:{s['b_wins']} TIE:{s['ties']}]"
              f"{'  ⚠️' if s['has_unfair_pages'] else ''}")

    # Generate
    print()
    print("📝 Generating report...")
    md = generate_markdown(by_key, args.pr)
    out_path.write_text(md, encoding='utf-8')
    print(f"✅ Saved: {out_path}")
    print()
    print(md)


if __name__ == '__main__':
    main()
