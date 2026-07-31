# Flash Report

## How to Generate
1. Run the SQL queries in Athena to produce the CSV datasources
2. Place the CSVs in this folder
3. Run `python3 generate_flash_report_tabs.py`
4. Open `flash_report.html` in a browser

## Datasource Mapping

| CSV File | Generated From | Description |
|----------|---------------|-------------|
| tab1_2_6_datasource.csv | stockout_flash_report_athena.sql | Zero OH, below min, order fill rate (all criticalities) |
| tab3_datasource.csv | adhoc_daily_flash_report.sql → Query 4 | Open PRs > 1 week |
| tab4_datasource.csv | adhoc_daily_flash_report.sql → Query 5 | Replacement rates |
| tab5_datasource.csv | adhoc_daily_flash_report.sql → Query 8 | Expected vs actual failure rate |
| tab7_datasource_RSC.csv | External (Coupa/RSC export) | Open purchase orders with past due info |

## Dashboard Tabs

| Tab | Name | Key Metrics |
|-----|------|-------------|
| 1 | Zero OH % | % Crit 1 parts at zero on-hand |
| 2 | Below Min No PR % | % Crit 1 parts below min without PR |
| 3 | Open PRs > 1wk | Stuck purchase requisitions |
| 4 | Top 10 Replacement | Highest consumption parts by product |
| 5 | Expected vs Actual | Min/LT implied rate vs actual consumption |
| 6 | Order Fill Rate | Qty received / qty ordered |
| 7 | Open PO Past Due | PO lines past due date |
| 8 | Site Scorecard | Composite risk ranking (Crit 1 USP only) |
