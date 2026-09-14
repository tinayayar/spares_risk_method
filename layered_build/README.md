# Critical Spares Risk Scoring

This folder contains the SQL logic for calculating risk scores for critical spare parts across USP and URL product lines.

## Overview

The risk scoring uses a **two-layer architecture**:

| Layer | Purpose | Key Output |
|-------|---------|------------|
| **Layer 2 (Base Scores)** | Consumption-based structural risk | Projected stockout days, days of supply |
| **Layer 1 + Layer 2 Combined** | Full risk picture with RSPL membership | Situational + structural risk scores |

---

## Files

| File | Description |
|------|-------------|
| `layer2_base_scores.sql` | Structural risk scoring based on consumption patterns (Athena) |
| `layer2_base_scores_andes.sql` | Andes/QuickSight variant of base scores |
| `layer2_with_layer1.sql` | Combined Layer 1 + Layer 2 with live inventory enrichment (Athena) |
| `layer2_with_layer1_andes.sql` | Andes/QuickSight variant of combined layer |
| `layer2_with_layer1_qs.sql` | QuickSight/Redshift variant of combined layer |

---

## Data Sources

### Provided by Soumya (AR Performance & Insights)
- `hw_raw_consumption_daily` — Daily consumption transactions by site + APN
- `hw_critical_spares_apm_setup_details` — RSPL membership and APM setup quality flags

### Live Inventory (r5stock / r5orderlines)
- `r5stock_apm_na/eu` — Current on-hand, MIN, MAX levels
- `r5orderlines_apm_na/eu` + `r5orders_apm_na/eu` — Open POs and back orders

### Other Sources
- `hw_component_control_limit_thresholds` (BADS) — Product lookup by cat_ref
- `hw_critical_spares_coupa_leadtime` — Supplier lead time from Coupa
- `r5catalogue_apm_na/eu` — Part descriptions, cat_ref lookup
- `dweeb_hx_order` / `dweeb-coming-order` — AR order history and coming orders

---

## Risk Score Definitions

### Situational Score (0–1)
Measures **current inventory position** — is stock adequate right now?

| Tier | Condition | Score | Indicator Flag |
|------|-----------|-------|----------------|
| Critical | OH = 0 AND no PO | 1.00 | `is_stockout_no_po` |
| High | OH = 0 (PO exists) | 0.75 | `is_stockout_with_po` |
| Medium | 0 < OH ≤ MIN AND no PO | 0.50 | `is_below_min_no_po` |
| Low | 0 < OH ≤ MIN (PO exists) | 0.25 | `is_below_min_with_po` |
| OK | OH > MIN | 0.00 | — |

### Structural Risk (0–1)
Measures **long-term stockout exposure** based on consumption patterns vs. MIN levels and replenishment times.

```
structural_risk = combined_stockout_days_yr / 365
```

### Criticality Weighting
All scores are weighted by part class:

| sto_class | Weight |
|-----------|--------|
| 01 HIGH | 1.00 |
| 02 MED | 0.75 |
| 03 LOW | 0.50 |
| Other | 0.25 |

### Overall Score
```
overall_score_criticality = situational_score_criticality + structural_risk_combo_criticality
```

---

## Products & Sites Covered

- **USP** — 54 NA sites + 14 EU sites (normalized to single product)
- **URL Rev C** — 3 sites
- **URL Rev C2** — 8 sites
- **URL Rev D** — 13 sites

Site-to-product mapping is enforced via the `target_sites` CTE.

---

## Part Eligibility

| Part Type | Structural Risk | Situational Risk |
|-----------|-----------------|------------------|
| In Layer 2 (consumed parts) | ✅ Calculated | ✅ Calculated |
| Layer 1 only (RSPL but unconsumed) | ❌ NULL | ✅ Calculated from live r5stock |
| Layer 2 only (consumed, not on RSPL) | ✅ Calculated | ✅ Calculated |

---

## APM Data Quality Flags

Row-level flags (per MPN):
- `not_set_up_in_apm`
- `missing_mpn_network`
- `missing_mpn_site`
- `missing_crn`
- `incorrect_mpn`
- `multiple_apns`
- `incorrect_apm_setup` (any of the above)

Site+product aggregates:
- `sp_*_count` — Distinct MPNs with each flag
- `sp_incorrect_apm_setup_penalty` — 5 if ≥50 MPNs have issues, else 0
- `sp_no_apn_mapped_penalty` — 5 if ≥10 MPNs have no APN, else 0

---

## Key Metrics

| Metric | Description |
|--------|-------------|
| `days_of_supply_150d` | (OH + back_order) / consumption_rate |
| `depletion_date_150d` | Projected date when stock runs out |
| `projected_order_date_150d` | When to order to avoid stockout (depletion - lead time) |
| `stockout_days_yr_min_150d` | Annual stockout days based on MIN coverage gap |
| `combined_stockout_days_yr_150d` | Max of MIN-based and actual rep time-based stockout days |
| `trend_ratio` | (30d order rate - 150d order rate) / 150d rate |

---

## Usage

### Athena
```sql
-- Run layer2_base_scores.sql to populate hw_critical_spares_score_base
-- Then run layer2_with_layer1.sql to get the combined output
```

### QuickSight
Use the `_andes.sql` or `_qs.sql` variants which reference `andes_bi_ext` tables.

---

## Contributing

- **Soumya** — Data source pipelines (`hw_raw_consumption_daily`, `hw_critical_spares_apm_setup_details`)
- **Tina** — Risk scoring methodology and combined data model

---

## Change Log

| Date | Change |
|------|--------|
| 2026-09 | Added situational tier indicator flags (`is_stockout_no_po`, etc.) |
| 2026-09 | Extended situational scoring to Layer-1-only parts via live r5stock |
| 2026-09 | Added live inventory enrichment (OH, MIN, MAX, back_order_qty) for unconsumed parts |
| 2026-09 | Converted to cross-engine compatible syntax (SELECT UNION ALL for target_sites) |
