# Statistical Analysis Methodology

## Objective

Validate that EPUB optimization produces statistically significant improvements in page render
times on e-ink devices, identifying where the improvement comes from and how much it contributes
to the overall reading experience.

---

## Two-Level Analysis Approach

The analysis operates at two complementary levels:

### Level 1 — Page Categories (Mechanics)

Every page in every captured session is classified into one of five categories based on the
image content present in each version:

| Category | Definition | Statistical treatment |
|----------|-----------|----------------------|
| **Text vs Text** | No images on either version | Paired t-test |
| **Image OK vs OK** | Both versions decoded images successfully | Paired t-test |
| **Image NOK → OK** | Original failed to decode; optimized succeeded | Descriptive only |
| **Cover OK vs OK** | Cover page generated successfully on both | Paired t-test |
| **Cover NOK → OK** | Cover failed on original; succeeded on optimized | Descriptive only |

Paired t-test (H0: no difference) is applied to symmetric categories where both versions
performed the same type of work. Asymmetric categories (NOK → OK) represent error correction,
not optimization — they are reported descriptively without significance testing.

### Level 2 — Book Aggregate (User Experience)

For each book, the total time saved is decomposed by category:

```
Total saved = Cover saved + Image OK saved + Image NOK saved + Text saved
```

This answers the question: *of the total improvement the user perceives, how much comes from
each type of content?*

---

## Key Insight: Cover Impact on Text-Heavy Books

A book composed entirely of text pages will still show measurable total improvement because
every book has a cover page. Cover generation is one of the largest beneficiaries of EPUB
optimization. In text-heavy books, the cover can account for the majority of total time saved,
even when text pages show no statistically significant difference.

This means the analysis must always distinguish between:
- **Page-level improvement** (what type of content benefits)
- **Book-level improvement** (what the user actually experiences)

---

## Statistical Tests

| Test | Applied to | Interpretation |
|------|-----------|---------------|
| Paired t-test | Text, Image OK, Cover OK | p < 0.05 = statistically significant improvement |
| 95% Confidence Interval | All categories | Range where the true mean improvement lies |
| Descriptive stats | Image NOK, Cover NOK | Mean savings reported without significance claim |

The paired t-test uses each page render time difference (original − optimized) as the paired
observation. A positive mean difference means the optimized version was faster.

---

## How to Run

```powershell
# Full report with console output + CSV export
py statistical_analysis.py

# Same, double-click friendly
run_analysis.bat
```

The script reads all `analysis_ORIGINAL_vs_OPTIMIZED_*.json` files from `logs/` automatically.
No configuration needed.

### Output

| File | Contents |
|------|---------|
| Console | Per-category stats, per-book table, savings breakdown, conclusions |
| `logs/statistical_pages.csv` | One row per classified page across all sessions |
| `logs/statistical_books.csv` | One row per book with totals and category breakdown |

### Report Sections

1. **Per-category page analysis** — n, mean ORIGINAL, mean OPTIMIZED, improvement %, IC 95%, t-test result
2. **Per-book summary** — composition (text / image OK / image NOK / cover), total improvement %, total ms saved
3. **Global savings breakdown** — what % of total time saved comes from covers, images, and text
4. **Cover impact in text-heavy books** — for books where text pages outnumber image pages, shows what fraction of the total saving is explained by the cover alone
5. **Conclusions** — plain-language summary of which categories show significant improvement

---

## Classification Rules (for reference)

The `statistical_analysis.py` script classifies each page using the following logic from the
JSON output of `EPUB-Optimization-Benchmark.ps1`:

```
is_cover   : page name starts with "Cover"
a_images   : number of images decoded by original (-1 = decode failure, 0 = none, >0 = success)
b_images   : same for optimized version
cover fields: a_cover_success / b_cover_success (per-page or from session metadata)

Text        : not cover AND a_images == 0 AND b_images == 0
Image OK    : not cover AND a_images > 0  AND b_images > 0
Image NOK   : not cover AND a_images == -1 AND b_images > 0
Cover OK    : is cover AND a_cover_success == true  AND b_cover_success == true
Cover NOK   : is cover AND a_cover_success == false AND b_cover_success == true
Skip        : all other cases (both fail, b fails, etc.)
```
