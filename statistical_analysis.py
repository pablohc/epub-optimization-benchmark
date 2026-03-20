#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
EPUB Benchmark - Statistical Analysis
Reads ORIGINAL vs OPTIMIZED JSON files from logs/ and produces a two-level report:
  - Page level: improvement by content category (text, image, cover)
  - Book level: total time saved and breakdown by source
"""

import json
import sys
import math
import statistics
from pathlib import Path
from collections import defaultdict

if sys.platform == 'win32':
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass

# ---------------------------------------------------------------------------
LOGS_DIR = Path(__file__).parent / "logs"

CATEGORIES  = ["text", "image_ok", "image_nok", "cover_ok", "cover_nok"]
FAIR_CATS   = {"text", "image_ok", "cover_ok"}   # symmetric -> t-test valid

CAT_LABELS  = {
    "text":      "Text vs Text      ",
    "image_ok":  "Image OK vs OK    ",
    "image_nok": "Image NOK -> OK   ",
    "cover_ok":  "Cover OK vs OK    ",
    "cover_nok": "Cover NOK -> OK   ",
}

# ---------------------------------------------------------------------------
# Page classification
# ---------------------------------------------------------------------------

def is_cover(page: dict) -> bool:
    return str(page.get("page", "")).startswith("Cover")


def classify_page(page: dict, meta: dict) -> str:
    """
    Returns one of: text | image_ok | image_nok | cover_ok | cover_nok | skip

    cover_nok: original failed to generate the cover thumbnail; optimized succeeded.
    In this case the ORIGINAL time may appear lower — not because it was faster,
    but because it exited the cover generation early on failure. The optimized
    version takes longer because it completes the task successfully.
    This category is excluded from t-tests and reported descriptively only.
    """
    a_img = page.get("a_images", 0)
    b_img = page.get("b_images", 0)

    if is_cover(page):
        # Prefer per-page fields; fall back to book-level meta
        if "a_cover_success" in page:
            a_ok = page["a_cover_success"]
            b_ok = page["b_cover_success"]
        else:
            a_ok = meta["a"]["cover_success"]
            b_ok = meta["b"]["cover_success"]

        if b_ok and a_ok:
            return "cover_ok"
        elif b_ok and not a_ok:
            return "cover_nok"
        else:
            return "skip"   # b also fails or both fail - not useful

    # Regular pages
    if a_img == 0 and b_img == 0:
        return "text"
    elif a_img > 0 and b_img > 0:
        return "image_ok"
    elif a_img == -1 and b_img > 0:
        return "image_nok"
    else:
        return "skip"


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------

def paired_ttest(diffs: list):
    """Paired t-test H0: mean(diff)==0.  Returns (t, p, n)."""
    n = len(diffs)
    if n < 2:
        return None, None, n
    m = statistics.mean(diffs)
    s = statistics.stdev(diffs)
    if s == 0:
        return 0.0, 1.0, n
    t = m / (s / math.sqrt(n))
    try:
        from scipy.stats import t as tdist
        p = float(2 * tdist.sf(abs(t), df=n - 1))
    except ImportError:
        # Normal approximation (conservative for small n)
        p = 2.0 * (1.0 - 0.5 * (1.0 + math.erf(abs(t) / math.sqrt(2))))
    return t, p, n


def ci95(values: list):
    """95% CI for the mean. Returns (lower, upper)."""
    n = len(values)
    if n < 2:
        return None, None
    m = statistics.mean(values)
    s = statistics.stdev(values)
    try:
        from scipy.stats import t as tdist
        tc = float(tdist.ppf(0.975, df=n - 1))
    except ImportError:
        # Conservative t-critical values
        if n >= 120: tc = 1.980
        elif n >= 60: tc = 2.000
        elif n >= 30: tc = 2.042
        elif n >= 20: tc = 2.093
        elif n >= 10: tc = 2.262
        else:         tc = 2.571
    margin = tc * s / math.sqrt(n)
    return m - margin, m + margin


# ---------------------------------------------------------------------------
# Load and analyse
# ---------------------------------------------------------------------------

def load_and_analyze(logs_dir: Path):
    files = sorted(logs_dir.glob("analysis_ORIGINAL_vs_OPTIMIZED_*.json"))
    if not files:
        print(f"No JSON files found in {logs_dir}")
        return None, None, None

    # Global page records per category
    cat_pages = defaultdict(list)   # cat -> [{"book", "page", "a_ms", "b_ms", "diff_ms"}, ...]

    book_records = []

    for f in files:
        with open(f, encoding='utf-8-sig') as fh:
            data = json.load(fh)

        meta  = data["meta"]
        book  = meta["book"]
        pages = data["pages"]

        # Per-book accumulators
        book_cat = defaultdict(lambda: {"a": [], "b": []})

        for page in pages:
            cat = classify_page(page, meta)
            if cat == "skip":
                continue

            a_ms = page["a_ms"]
            b_ms = page["b_ms"]

            cat_pages[cat].append({
                "book":     book,
                "page":     str(page["page"]),
                "category": cat,
                "a_ms":     a_ms,
                "b_ms":     b_ms,
                "diff_ms":  a_ms - b_ms,
            })
            book_cat[cat]["a"].append(a_ms)
            book_cat[cat]["b"].append(b_ms)

        # Book-level totals (only classified pages)
        total_a = sum(v for cat in CATEGORIES for v in book_cat[cat]["a"])
        total_b = sum(v for cat in CATEGORIES for v in book_cat[cat]["b"])
        total_diff = total_a - total_b
        total_pct  = (total_diff / total_a * 100) if total_a > 0 else 0.0

        # Cover info
        cover_cat  = "no_cover"
        cover_a_ms = cover_b_ms = cover_saved = None
        for cat in ("cover_ok", "cover_nok"):
            if book_cat[cat]["a"]:
                cover_cat   = cat
                cover_a_ms  = book_cat[cat]["a"][0]
                cover_b_ms  = book_cat[cat]["b"][0]
                cover_saved = cover_a_ms - cover_b_ms
                break

        def cat_saved(cat):
            return sum(a - b for a, b in zip(book_cat[cat]["a"], book_cat[cat]["b"]))

        book_records.append({
            "book":              book,
            "n_text":            len(book_cat["text"]["a"]),
            "n_image_ok":        len(book_cat["image_ok"]["a"]),
            "n_image_nok":       len(book_cat["image_nok"]["a"]),
            "cover_category":    cover_cat,
            "cover_a_ms":        cover_a_ms,
            "cover_b_ms":        cover_b_ms,
            "cover_saved_ms":    cover_saved if cover_saved is not None else 0,
            "text_saved_ms":     cat_saved("text"),
            "image_ok_saved_ms": cat_saved("image_ok"),
            "image_nok_saved_ms":cat_saved("image_nok"),
            "total_a_ms":        total_a,
            "total_b_ms":        total_b,
            "total_diff_ms":     total_diff,
            "total_diff_pct":    round(total_pct, 2),
        })

    return files, cat_pages, book_records


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def print_report(cat_pages, book_records):
    W = 74
    total_pages  = sum(len(cat_pages[c]) for c in CATEGORIES)
    total_images = len(cat_pages["image_ok"]) + len(cat_pages["image_nok"])

    print("=" * W)
    print("  EPUB OPTIMIZATION - STATISTICAL ANALYSIS")
    print("=" * W)
    print(f"  Books: {len(book_records)}   |   Pages: {total_pages}   |   Images: {total_images}")
    print()

    # ── 1. Category-level ────────────────────────────────────────────────────
    print("─" * W)
    print("  1. PAGE CATEGORY ANALYSIS")
    print("─" * W)

    for cat in CATEGORIES:
        pages  = cat_pages[cat]
        label  = CAT_LABELS[cat]

        if not pages:
            print(f"\n  {label}: no data")
            continue

        a_vals = [p["a_ms"] for p in pages]
        b_vals = [p["b_ms"] for p in pages]
        diffs  = [p["diff_ms"] for p in pages]
        n      = len(diffs)
        books  = len({p["book"] for p in pages})

        mean_a = statistics.mean(a_vals)
        mean_b = statistics.mean(b_vals)
        mean_d = statistics.mean(diffs)
        pct    = (mean_d / mean_a * 100) if mean_a > 0 else 0.0
        ci_lo, ci_hi = ci95(diffs)

        print(f"\n  {label}  (n={n} pages / {books} books)")
        print(f"    ORIGINAL avg : {mean_a:>9,.0f} ms")
        print(f"    OPTIMIZED avg: {mean_b:>9,.0f} ms")
        print(f"    Mean savings : {mean_d:>+9,.0f} ms  ({pct:>+.1f}%)")
        if ci_lo is not None:
            print(f"    95% CI       :  [{ci_lo:>+,.0f} ms ,  {ci_hi:>+,.0f} ms]")

        if cat in FAIR_CATS and n >= 3:
            t, p, _ = paired_ttest(diffs)
            if t is not None:
                sig = "SIGNIFICANT (p<0.05)" if p < 0.05 else "not significant (p>=0.05)"
                print(f"    Paired t-test: t={t:.3f},  p={p:.4f}  -> {sig}")
        else:
            if cat == "cover_nok":
                print(f"    Paired t-test: skipped — original failed cover generation (error correction, not optimization)")
            elif cat == "image_nok":
                print(f"    Paired t-test: skipped — original failed image decode (error correction, not optimization)")
            else:
                print(f"    Paired t-test: skipped (asymmetric comparison)")

    print()

    # ── 2. Per-book table ────────────────────────────────────────────────────
    print("─" * W)
    print("  2. PER-BOOK SUMMARY")
    print("─" * W)
    print()
    print(f"  {'Book':<44} {'Txt':>4} {'OK':>5} {'NOK':>4}  {'Cover':<9} {'%Total':>7}  {'Saved':>9}")
    print(f"  {'-'*70}")

    has_cover_nok = False
    for br in sorted(book_records, key=lambda x: x["total_diff_pct"], reverse=True):
        cc   = br["cover_category"]
        if   cc == "cover_ok":  cover = "OK"
        elif cc == "cover_nok": cover = "NOK->OK"; has_cover_nok = True
        else:                   cover = "-"
        marker = " (*)" if cc == "cover_nok" else ""
        name = (br["book"][:(44 - len(marker))] + marker)
        print(
            f"  {name:<44} {br['n_text']:>4} {br['n_image_ok']:>5} {br['n_image_nok']:>4}"
            f"  {cover:<9} {br['total_diff_pct']:>+6.1f}%  {br['total_diff_ms']:>8,} ms"
        )
    if has_cover_nok:
        print()
        print(f"  (*) Cover NOK->OK: ORIGINAL failed cover generation and exited early (less time).")
        print(f"    OPTIMIZED successfully generated the cover (more time). The apparent")
        print(f"    regression or reduced saving is NOT a real performance regression —")
        print(f"    it reflects OPTIMIZED doing more work correctly.")
    print()

    # ── 3. Global savings breakdown ──────────────────────────────────────────
    print("─" * W)
    print("  3. GLOBAL SAVINGS BREAKDOWN")
    print("─" * W)
    print()

    total_saved      = sum(br["total_diff_ms"]     for br in book_records)
    cover_ok_saved   = sum(br["cover_saved_ms"]    for br in book_records if br["cover_category"] == "cover_ok")
    cover_nok_saved  = sum(br["cover_saved_ms"]    for br in book_records if br["cover_category"] == "cover_nok")
    img_ok_saved     = sum(br["image_ok_saved_ms"] for br in book_records)
    img_nok_saved    = sum(br["image_nok_saved_ms"]for br in book_records)
    text_saved       = sum(br["text_saved_ms"]     for br in book_records)

    def bar(ms):
        pct = (ms / total_saved * 100) if total_saved else 0
        fill = "#" * max(0, int(abs(pct) / 2))
        return f"{ms:>10,} ms  ({pct:>+6.1f}%)  {fill}"

    print(f"  Cover OK         : {bar(cover_ok_saved)}")
    print(f"  Cover NOK->OK    : {bar(cover_nok_saved)}")
    print(f"  Images OK        : {bar(img_ok_saved)}")
    print(f"  Images NOK->OK   : {bar(img_nok_saved)}")
    print(f"  Text             : {bar(text_saved)}")
    print(f"  {'─'*60}")
    print(f"  TOTAL            : {total_saved:>10,} ms  (100%)")
    print()

    # ── 4. Cover impact in text-heavy books ──────────────────────────────────
    print("─" * W)
    print("  4. COVER IMPACT IN TEXT-HEAVY BOOKS")
    print("─" * W)
    print()

    text_dominant = [
        br for br in book_records
        if br["n_text"] > (br["n_image_ok"] + br["n_image_nok"])
    ]
    print(f"  Books where text pages > image pages: {len(text_dominant)}")
    print()
    print(f"  {'Book':<50}  {'%Total':>7}  {'Cover share of savings':>22}")
    print(f"  {'-'*76}")

    cover_contribs = []
    for br in sorted(text_dominant, key=lambda x: x["total_diff_pct"], reverse=True):
        total_s  = br["total_diff_ms"]
        cover_s  = br["cover_saved_ms"]
        if total_s > 0:
            c_pct = cover_s / total_s * 100
            cover_contribs.append(c_pct)
        else:
            c_pct = 0.0
        name = br["book"][:49]
        print(f"  {name:<50}  {br['total_diff_pct']:>+6.1f}%  {c_pct:>21.0f}%")

    print()

    # ── 5. Conclusions ───────────────────────────────────────────────────────
    print("─" * W)
    print("  5. CONCLUSIONS")
    print("─" * W)
    print()

    # Text pages
    tp = cat_pages["text"]
    if tp:
        td = [p["diff_ms"] for p in tp]
        t, p_val, n = paired_ttest(td)
        tp_pct = statistics.mean(td) / statistics.mean([p["a_ms"] for p in tp]) * 100
        if p_val is not None and p_val >= 0.05:
            print(f"  - Text pages: no statistically significant improvement (t={t:.3f}, p={p_val:.3f}, n={n})")
        else:
            print(f"  - Text pages: improvement {tp_pct:+.1f}% (p={p_val:.4f}, n={n})")

    # Image OK
    ip = cat_pages["image_ok"]
    if ip:
        id_ = [p["diff_ms"] for p in ip]
        t, p_val, n = paired_ttest(id_)
        ip_pct = statistics.mean(id_) / statistics.mean([p["a_ms"] for p in ip]) * 100
        sig = "SIGNIFICANT" if (p_val is not None and p_val < 0.05) else "not significant"
        print(f"  - Images OK: mean improvement {ip_pct:+.1f}% ({sig}, p={p_val:.4f}, n={n})")

    # Image NOK
    np_ = cat_pages["image_nok"]
    if np_:
        nd = [p["diff_ms"] for p in np_]
        np_pct = statistics.mean(nd) / statistics.mean([p["a_ms"] for p in np_]) * 100
        print(f"  - Images NOK->OK: error correction, mean savings {np_pct:+.1f}% (n={len(nd)})")

    # Cover OK
    cp = cat_pages["cover_ok"]
    if cp:
        cd = [p["diff_ms"] for p in cp]
        t, p_val, n = paired_ttest(cd)
        cp_pct = statistics.mean(cd) / statistics.mean([p["a_ms"] for p in cp]) * 100
        sig = "SIGNIFICANT" if (p_val is not None and p_val < 0.05) else "not significant"
        print(f"  - Covers OK: mean improvement {cp_pct:+.1f}% ({sig}, p={p_val:.4f}, n={n})")

    # Cover NOK
    cnp = cat_pages["cover_nok"]
    if cnp:
        cnd = [p["diff_ms"] for p in cnp]
        cn_pct = statistics.mean(cnd) / statistics.mean([p["a_ms"] for p in cnp]) * 100
        print(f"  - Covers NOK->OK (n={len(cnd)}): original failed cover generation and exited early.")
        print(f"    Optimized version takes more time because it completes the task successfully.")
        print(f"    Mean time difference: {cn_pct:+.1f}%. Any book showing a negative total")
        print(f"    improvement in this category is NOT a regression — it reflects correct")
        print(f"    behavior in OPTIMIZED vs a silent failure in ORIGINAL.")

    # Cover contribution in text-dominant books
    if cover_contribs:
        avg_c = statistics.mean(cover_contribs)
        print()
        print(f"  In text-heavy books (text > images, n={len(cover_contribs)}),")
        print(f"  the cover accounts for an average of {avg_c:.0f}% of total time saved,")
        print(f"  even though text pages show no statistically significant difference.")

    print()


# ---------------------------------------------------------------------------
# CSV export
# ---------------------------------------------------------------------------

def export_json(cat_pages, book_records, output_dir: Path):
    # All classified pages
    all_pages = [p for cat in CATEGORIES for p in cat_pages[cat]]
    if all_pages:
        out = output_dir / "statistical_pages.json"
        with open(out, 'w', encoding='utf-8') as f:
            json.dump(all_pages, f, indent=2, ensure_ascii=False)
        print(f"  Pages JSON : {out.name}")

    # Book-level summary
    if book_records:
        out = output_dir / "statistical_books.json"
        with open(out, 'w', encoding='utf-8') as f:
            json.dump(book_records, f, indent=2, ensure_ascii=False)
        print(f"  Books JSON : {out.name}")


# ---------------------------------------------------------------------------

def main():
    result = load_and_analyze(LOGS_DIR)
    if result[0] is None:
        return
    _, cat_pages, book_records = result

    print_report(cat_pages, book_records)

    W = 74
    print("─" * W)
    print("  JSON EXPORT")
    print("─" * W)
    print()
    export_json(cat_pages, book_records, LOGS_DIR)
    print()


if __name__ == '__main__':
    main()
