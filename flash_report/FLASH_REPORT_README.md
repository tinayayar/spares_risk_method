# RSPL Flash Report

A daily spare-parts stock-health dashboard for RME sites. It answers one question:
**for the critical spare parts each site is supposed to stock, are they on hand — and
if not, is a replenishment order in progress?**

Live report (permanent link): **https://d8et2kyudtix3.cloudfront.net/**

---

## What it does

For every target site and product line, the report:

1. Takes the official target parts list (**RSPL** — identified by manufacturer part
   number `MPN` and/or catalogue reference `CRN`).
2. Maps each RSPL part to the site's inventory-system part number (**APN**) in APM.
3. Pulls current stock, min/max levels, open purchase requisitions (PRs), and open
   purchase orders (POs) for those APNs.
4. Renders an interactive HTML dashboard, filterable by product and site.

## Products & site groups

The report covers **USP** and **URL** equipment. USP and URL each have regional /
revision variants that draw from **different RSPL target-part lists** but are labelled
for the reader:

| Label in report | RSPL source table | Sites |
|---|---|---|
| USP | `default.rspl_target_parts` | NA "6.NA" sites (30) |
| USP B1 | `default.rspl_target_parts_usp_b1` | NA "B1" sites (24) |
| USP EU | `default.rspl_target_parts_usp_eu` | EU sites (14) |
| URL Rev C / C2 / D | `default.rspl_target_parts_URL` (by `product`) | URL sites |

Site→group membership for USP comes from the **`Rev` column** of the *USP Tracker* tab
in `URL & USP Spares & Training Tracker.xlsx` (`6.NA`, `B1`, `6.EU`).

## Dashboard tabs (KPIs)

| Tab | KPI | What it shows |
|---|---|---|
| 1 | Stock Status Detail | Every RSPL part × site: MPN, CRN, APN, description, OH qty, MIN/MAX, in-APM Y/N. Rows highlight **red** when stocked out — but only if *no* APN in the same MPN+CRN group has stock (a covered part is not flagged). |
| 2 | % Below Min Without Active PR | Parts below minimum with no active requisition — the actionable replenishment gaps. |
| 3 | Open PRs > 1 Week | Requisitions that have been open more than 7 days (stuck PRs). |
| 4 | RSPL Receipt Rate | Qty received ÷ qty ordered, per site/product. |
| 5 | Open Purchase Orders | Outstanding PO lines (work in progress). |
| 6 | APN Heatmap | MPN × site grid showing coverage (green = APN found, red ✗ = no APN, – = n/a). |

Key definitions:
- **Zero-OH / stockout** is evaluated at the **MPN+CRN group** level: a part counts as
  stocked out only when *no* APN mapped to it at that site has on-hand > 0. `NULL`
  on-hand is treated as 0.
- **Has active PR** = an active requisition (`req_status='A'` and line `rql_status='A'`).

## How the pipeline works

```
RSPL target lists  ─┐
                    ├─> query_mapping_datasource.sql ──> default.rspl_apn_mapping  (CTAS table)
APM catalogue/stock ┘                                          │
                                                               ▼
                                    flash_report_all_queries.sql ──> flash_report_datasource.csv
                                                               │
                                                               ▼
                                        generate_flash_report.py ──> flash_report.html
                                                               │
                                                               ▼
                                        S3 (private) ── CloudFront (OAC) ──> permanent URL
```

1. **Mapping** (`query_mapping_datasource.sql`): resolves RSPL MPN/CRN → APN via two
   paths (stock `sto_prefmanufactpart` and catalogue `cat_ref`), scopes each part list
   to its own sites, and writes the `default.rspl_apn_mapping` table (CTAS).
2. **Main query** (`flash_report_all_queries.sql`): joins the mapping table to APM
   stock, requisitions, and orders; produces one CSV row per APN+site with OH, PR, PO,
   and KPI flags. Part descriptions come from the R5 catalogue keyed by the matched
   `cat_ref` (not `MAX(cat_desc)`, which surfaced junk labels).
3. **HTML** (`generate_flash_report.py`): reads the CSV and builds the tabbed dashboard.
4. **Publish** (`generate_flash_report_auto.py`): orchestrates the above, uploads the
   HTML to the private S3 bucket, and invalidates CloudFront so the permanent URL serves
   the fresh report.

## Automation

Runs unattended on an EC2 instance (see `infra/README.md` for full details):
- Scheduled daily at **05:00 America/Los_Angeles** via a systemd timer.
- Authenticates through an IAM instance role that assumes `AthenaFullAccess-alpha`
  (which holds the cross-account Lake Formation access the `andes` federated tables
  need) — no Midway/ada dependency.
- Serves through CloudFront + OAC, so the bucket stays private and the URL never expires.

Manual run (Athena creds required):
```
python3 generate_flash_report_auto.py --refresh-mapping   # rebuild mapping + report + publish
python3 generate_flash_report_auto.py --skip-publish      # local only, keep last mapping
```

## Key files

| File | Purpose |
|---|---|
| `query_mapping_datasource.sql` | Builds the RSPL→APN mapping table (per-product site routing) |
| `flash_report_all_queries.sql` | Main query: mapping ⋈ stock/PR/PO → datasource CSV |
| `generate_flash_report.py` | Renders the HTML dashboard from the CSV |
| `generate_flash_report_auto.py` | Orchestrator: Athena → CSV → HTML → S3 → CloudFront |
| `infra/` | EC2 / IAM / CloudFront / systemd config + setup docs |
| `adhoc/` | One-off analyses (e.g. site zero-OH + PR checks) |

## Data sources (Athena, `andes` catalog)

- Stock: `rme-gdl.r5stock_apm_{na,eu}`
- Catalogue: `rme-gdl.r5catalogue_apm_{na,eu}`
- Requisitions: `rme-gdl.r5requisitions_apm_{na,eu}` + `r5requislines_apm_{na,eu}`
- Orders: `rme-gdl.r5orders_apm_{na,eu}` + `r5orderlines_apm_{na,eu}`
- Consumption: `ar-performance-n-insights.hw_raw_consumption_daily`
- Site/equipment: `am_dps_public.{url,ecopac}_machine_daily`, `ar-performance-n-insights.*`

RSPL inputs live in the `default` database: `rspl_target_parts`,
`rspl_target_parts_usp_b1`, `rspl_target_parts_usp_eu`, `rspl_target_parts_URL`.
