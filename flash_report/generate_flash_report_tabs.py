"""
Generate multi-tab HTML flash report.
Usage: python3 generate_flash_report_tabs.py

Expects these CSV files in the same directory:
  - tab1_2_6_datasource.csv (from stockout_flash_report_athena output)
  - tab3_datasource.csv (from Query 4: open PRs > 1 week)
  - tab4_datasource.csv (from Query 5: replacement rates)
  - tab5_datasource.csv (from Query 8: expected vs actual failure rate)
"""

import pandas as pd
from datetime import date
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FILE = os.path.join(SCRIPT_DIR, 'flash_report.html')

def load_csv(filename):
    path = os.path.join(SCRIPT_DIR, filename)
    if not os.path.exists(path):
        print(f"WARNING: {filename} not found, skipping")
        return None
    return pd.read_csv(path)

def html_table(df, max_rows=None, table_id=None):
    if df is None or df.empty:
        return "<p>No data available</p>"
    if max_rows:
        df = df.head(max_rows)
    tid = f' id="{table_id}"' if table_id else ''
    html = f'<table{tid}><tr>' + ''.join(f'<th>{c}</th>' for c in df.columns) + '</tr>\n'
    for _, row in df.iterrows():
        sto_class_val = row.get('sto_class', '') if 'sto_class' in df.columns else ''
        html += f'<tr data-class="{sto_class_val}">' + ''.join(f'<td>{v}</td>' for v in row.values) + '</tr>\n'
    html += '</table>'
    return html

def generate_report():
    today = date.today().strftime('%B %d, %Y')

    # Load data
    df12 = load_csv('tab1_2_6_datasource.csv')
    df3 = load_csv('tab3_datasource.csv')
    df4 = load_csv('tab4_datasource.csv')
    df5 = load_csv('tab5_datasource.csv')
    df7 = load_csv('tab7_datasource_RSC.csv')

    # --- TAB 1: Zero OH % ---
    tab1_content = "<h2>% of Criticality 1 Parts at Zero On-Hand</h2>"
    if df12 is not None:
        df1 = df12[df12['sto_class'] == '01 HIGH'].copy() if 'sto_class' in df12.columns else df12.copy()
        # Network by product
        net1 = df1.groupby('product').agg(
            total=('apn', 'count'), at_zero=('is_zero_oh', 'sum')
        ).reset_index()
        net1['pct'] = (100.0 * net1['at_zero'] / net1['total']).round(2)
        tab1_content += "<h3>Network Level</h3>" + html_table(net1)
        # Site by product
        site1 = df1.groupby(['site', 'product']).agg(
            total=('apn', 'count'), at_zero=('is_zero_oh', 'sum')
        ).reset_index()
        site1['pct'] = (100.0 * site1['at_zero'] / site1['total']).round(2)
        site1 = site1.sort_values(['product', 'pct'], ascending=[True, False])
        # Site and product filters for site-level table
        sites_list = sorted(site1['site'].unique().tolist())
        products_list = sorted(site1['product'].dropna().unique().tolist())
        site_opts = '<option value="all">All Sites</option>' + ''.join(f'<option value="{s}">{s}</option>' for s in sites_list)
        prod_opts = '<option value="all">All Products</option>' + ''.join(f'<option value="{p}">{p}</option>' for p in products_list)
        tab1_content += '<h3>Site Level</h3>'
        tab1_content += f'<div class="filter-bar"><label>Site: </label><select onchange="filterTab1Site()"  id="tab1_site_filter">{site_opts}</select>'
        tab1_content += f'<label> Product: </label><select onchange="filterTab1Site()" id="tab1_product_filter">{prod_opts}</select></div>'
        tab1_content += html_table(site1, table_id='tab1_site_table')
        # Detail: all parts with zero on-hand
        zero_parts = df1[df1['is_zero_oh'] == 1].copy()
        if not zero_parts.empty:
            detail_cols = [c for c in ['site', 'apn', 'product', 'part_description', 'site_oh_qty', 'min_level', 'max_level'] if c in zero_parts.columns]
            zero_parts = zero_parts[detail_cols].sort_values(['site', 'apn'])
            tab1_content += "<h3>Parts at Zero On-Hand</h3>"
            tab1_content += html_table(zero_parts, table_id='tab1_detail_table')
    else:
        tab1_content += "<p>No data</p>"

    # --- TAB 2: Below Min No PR % ---
    tab2_content = "<h2>% of Criticality 1 Parts Below Min Without Active PR</h2>"
    if df12 is not None:
        df2 = df12[df12['sto_class'] == '01 HIGH'].copy() if 'sto_class' in df12.columns else df12.copy()
        # Network by product
        net2 = df2.groupby('product').agg(
            total=('apn', 'count'), below_min_no_pr=('is_below_min_no_pr', 'sum')
        ).reset_index()
        net2['pct'] = (100.0 * net2['below_min_no_pr'] / net2['total']).round(2)
        tab2_content += "<h3>Network Level</h3>" + html_table(net2)
        # Site by product
        site2 = df2.groupby(['site', 'product']).agg(
            total=('apn', 'count'), below_min_no_pr=('is_below_min_no_pr', 'sum')
        ).reset_index()
        site2['pct'] = (100.0 * site2['below_min_no_pr'] / site2['total']).round(2)
        site2 = site2.sort_values(['product', 'pct'], ascending=[True, False])
        # Site and product filters
        sites_list2 = sorted(site2['site'].unique().tolist())
        products_list2 = sorted(site2['product'].dropna().unique().tolist())
        site_opts2 = '<option value="all">All Sites</option>' + ''.join(f'<option value="{s}">{s}</option>' for s in sites_list2)
        prod_opts2 = '<option value="all">All Products</option>' + ''.join(f'<option value="{p}">{p}</option>' for p in products_list2)
        tab2_content += '<h3>Site Level</h3>'
        tab2_content += f'<div class="filter-bar"><label>Site: </label><select onchange="filterTab2Site()" id="tab2_site_filter">{site_opts2}</select>'
        tab2_content += f'<label> Product: </label><select onchange="filterTab2Site()" id="tab2_product_filter">{prod_opts2}</select></div>'
        tab2_content += html_table(site2, table_id='tab2_site_table')
        # Detail: all parts below min with no PR
        below_min_parts = df2[df2['is_below_min_no_pr'] == 1].copy()
        if not below_min_parts.empty:
            detail_cols2 = [c for c in ['site', 'apn', 'product', 'part_description', 'site_oh_qty', 'min_level', 'max_level'] if c in below_min_parts.columns]
            below_min_parts = below_min_parts[detail_cols2].sort_values(['site', 'apn'])
            tab2_content += "<h3>Parts Below Min Without Active PR</h3>"
            tab2_content += html_table(below_min_parts, table_id='tab2_detail_table')
    else:
        tab2_content += "<p>No data</p>"

    # --- TAB 3: Open PRs > 1 Week ---
    tab3_content = "<h2>Parts with Open Purchase Requisitions &gt; 1 Week</h2>"
    if df3 is not None:
        sto_classes_3 = sorted(df3['sto_class'].dropna().unique().tolist()) if 'sto_class' in df3.columns else []
        filter_opts = '<option value="all">All</option>' + ''.join(f'<option value="{v}">{v}</option>' for v in sto_classes_3)
        # Get all unique sites and products for filters
        sites_list3 = sorted(df3['site'].unique().tolist()) if 'site' in df3.columns else []
        products_list3 = sorted(df3['product'].dropna().unique().tolist()) if 'product' in df3.columns else []
        site_opts3 = '<option value="all">All Sites</option>' + ''.join(f'<option value="{s}">{s}</option>' for s in sites_list3)
        prod_opts3 = '<option value="all">All Products</option>' + ''.join(f'<option value="{p}">{p}</option>' for p in products_list3)
        tab3_content += f'<div class="filter-bar"><label>Criticality: </label><select onchange="switchView(\'tab3\', this.value)">{filter_opts}</select>'
        tab3_content += f' <label>Site: </label><select onchange="filterTab3Site()" id="tab3_site_filter">{site_opts3}</select>'
        tab3_content += f' <label>Product: </label><select onchange="filterTab3Site()" id="tab3_product_filter">{prod_opts3}</select></div>'
        # Generate content for each sto_class + all
        for cls_val in ['all'] + sto_classes_3:
            df3_f = df3 if cls_val == 'all' else df3[df3['sto_class'] == cls_val]
            display = 'block' if cls_val == 'all' else 'none'
            net3 = df3_f.groupby('product').agg(parts_with_old_pr=('apn', 'nunique')).reset_index()
            site3 = df3_f.groupby(['site', 'product']).agg(parts_with_old_pr=('apn', 'nunique')).reset_index()
            site3 = site3.sort_values('parts_with_old_pr', ascending=False)
            detail_cols = [c for c in ['site', 'apn', 'product', 'part_description', 'sto_class', 'req_number', 'req_qty', 'req_date', 'days_open'] if c in df3_f.columns]
            df3_sorted = df3_f[detail_cols].sort_values('days_open', ascending=False) if 'days_open' in df3_f.columns else df3_f[detail_cols]
            safe_cls = cls_val.replace(' ', '_')
            tab3_content += f'<div id="tab3_{safe_cls}" style="display:{display}">'
            tab3_content += "<h3>Network Summary</h3>" + html_table(net3)
            tab3_content += "<h3>Site Summary</h3>" + html_table(site3, table_id=f'tab3_site_{safe_cls}')
            tab3_content += "<h3>Detail List</h3>" + html_table(df3_sorted, table_id=f'tab3_detail_{safe_cls}')
            tab3_content += '</div>'
    else:
        tab3_content += "<p>No data</p>"

    # --- TAB 4: Top 10 Highest Replacement Rate by Product ---
    tab4_content = "<h2>Top 10 Parts by Replacement Rate (150d) — by Product</h2>"
    if df4 is not None:
        rate_col = 'rate_150d' if 'rate_150d' in df4.columns else 'actual_daily_rate'
        if rate_col in df4.columns and 'product' in df4.columns:
            products = sorted(df4['product'].dropna().unique().tolist())
            for prod in products:
                df4_prod = df4[df4['product'] == prod].copy()
                if df4_prod.empty:
                    continue
                top10 = df4_prod.nlargest(10, rate_col)
                display_cols = [c for c in ['site', 'apn', 'product', 'part_description', 'sto_class', rate_col, 'consumed_150d'] if c in top10.columns]
                tab4_content += f"<h3>{prod}</h3>" + html_table(top10[display_cols])
        else:
            tab4_content += "<p>Rate column or product column not found</p>"
    else:
        tab4_content += "<p>No data</p>"

    # --- TAB 5: Expected vs Actual Failure Rate ---
    tab5_content = "<h2>Expected vs Actual Failure Rate</h2>"
    if df5 is not None:
        sto_classes_5 = sorted(df5['sto_class'].dropna().unique().tolist()) if 'sto_class' in df5.columns else []
        filter_opts5 = '<option value="all">All</option>' + ''.join(f'<option value="{v}">{v}</option>' for v in sto_classes_5)
        sites_list5 = sorted(df5['site'].unique().tolist()) if 'site' in df5.columns else []
        products_list5 = sorted(df5['product'].dropna().unique().tolist()) if 'product' in df5.columns else []
        site_opts5 = '<option value="all">All Sites</option>' + ''.join(f'<option value="{s}">{s}</option>' for s in sites_list5)
        prod_opts5_html = '<option value="all">All Products</option>' + ''.join(f'<option value="{p}">{p}</option>' for p in products_list5)
        tab5_content += f'<div class="filter-bar"><label>Criticality: </label><select onchange="switchView(\'tab5\', this.value)">{filter_opts5}</select>'
        tab5_content += f' <label>Site: </label><select onchange="filterTab5Site()" id="tab5_site_filter">{site_opts5}</select>'
        tab5_content += f' <label>Product: </label><select onchange="filterTab5Site()" id="tab5_product_filter">{prod_opts5_html}</select></div>'
        for cls_val in ['all'] + sto_classes_5:
            df5_f = df5 if cls_val == 'all' else df5[df5['sto_class'] == cls_val]
            display = 'block' if cls_val == 'all' else 'none'
            net5 = df5_f.groupby('product').agg(
                avg_expected=('expected_daily_rate', 'mean'),
                avg_actual=('actual_daily_rate', 'mean'),
                parts_actual_gt_expected=('actual_vs_expected_ratio', lambda x: (x > 1).sum()),
                total_parts=('apn', 'count')
            ).reset_index()
            net5['avg_expected'] = net5['avg_expected'].round(4)
            net5['avg_actual'] = net5['avg_actual'].round(4)
            site5 = df5_f.groupby(['site', 'product']).agg(
                avg_expected=('expected_daily_rate', 'mean'),
                avg_actual=('actual_daily_rate', 'mean'),
                parts_actual_gt_expected=('actual_vs_expected_ratio', lambda x: (x > 1).sum()),
                total_parts=('apn', 'count')
            ).reset_index()
            site5['avg_expected'] = site5['avg_expected'].round(4)
            site5['avg_actual'] = site5['avg_actual'].round(4)
            site5 = site5.sort_values(['product', 'site'])
            over = df5_f[df5_f['actual_vs_expected_ratio'] > 1].copy() if 'actual_vs_expected_ratio' in df5_f.columns else df5_f.head(0)
            over = over.sort_values('actual_vs_expected_ratio', ascending=False)
            detail_cols = [c for c in ['site', 'apn', 'product', 'part_description', 'sto_class', 'min_level', 'supplier_lead_time', 'expected_daily_rate', 'actual_daily_rate', 'actual_vs_expected_ratio'] if c in over.columns]
            safe_cls = cls_val.replace(' ', '_')
            tab5_content += f'<div id="tab5_{safe_cls}" style="display:{display}">'
            tab5_content += "<h3>Network Avg by Product</h3>" + html_table(net5)
            tab5_content += "<h3>Site Avg by Product</h3>" + html_table(site5, table_id=f'tab5_site_{safe_cls}')
            tab5_content += "<h3>Parts with Actual &gt; Expected</h3>" + html_table(over[detail_cols], table_id=f'tab5_detail_{safe_cls}')
            tab5_content += '</div>'
    else:
        tab5_content += "<p>No data</p>"

    # --- TAB 6: Order Fill Rate (pre-computed per criticality using switchView) ---
    tab6_content = "<h2>Order Fill Rate (Qty Received / Qty Ordered)</h2>"
    if df12 is not None and 'total_ordered' in df12.columns:
        df6 = df12[df12['total_ordered'] > 0].copy()
        sto_classes_6 = sorted(df6['sto_class'].dropna().unique().tolist()) if 'sto_class' in df6.columns else []
        sites_list6 = sorted(df6['site'].unique().tolist()) if 'site' in df6.columns else []
        products_list6 = sorted(df6['product'].dropna().unique().tolist()) if 'product' in df6.columns else []
        cls_opts6 = '<option value="all">All</option>' + ''.join(f'<option value="{v}">{v}</option>' for v in sto_classes_6)
        site_opts6 = '<option value="all">All Sites</option>' + ''.join(f'<option value="{s}">{s}</option>' for s in sites_list6)
        prod_opts6 = '<option value="all">All Products</option>' + ''.join(f'<option value="{p}">{p}</option>' for p in products_list6)
        tab6_content += f'<div class="filter-bar"><label>Criticality: </label><select onchange="switchView(\'tab6\', this.value); filterTab6()" id="tab6_class_filter">{cls_opts6}</select>'
        tab6_content += f' <label>Site: </label><select onchange="filterTab6()" id="tab6_site_filter">{site_opts6}</select>'
        tab6_content += f' <label>Product: </label><select onchange="filterTab6()" id="tab6_product_filter">{prod_opts6}</select></div>'
        # Generate per-criticality views
        for cls_val in ['all'] + sto_classes_6:
            df6_f = df6 if cls_val == 'all' else df6[df6['sto_class'] == cls_val]
            display = 'block' if cls_val == 'all' else 'none'
            safe_cls = cls_val.replace(' ', '_')
            # Network by product
            net6 = df6_f.groupby('product').agg(
                total_ordered=('total_ordered', 'sum'),
                total_received=('total_received', 'sum')
            ).reset_index()
            net6['pct_received'] = (100.0 * net6['total_received'] / net6['total_ordered']).round(2)
            # Site by product
            site6 = df6_f.groupby(['site', 'product']).agg(
                total_ordered=('total_ordered', 'sum'),
                total_received=('total_received', 'sum')
            ).reset_index()
            site6['pct_received'] = (100.0 * site6['total_received'] / site6['total_ordered']).round(2)
            site6 = site6.sort_values(['product', 'pct_received'], ascending=[True, True])
            # Detail
            detail_cols6 = [c for c in ['site', 'apn', 'product', 'part_description', 'sto_class', 'total_ordered', 'total_received', 'pct_received'] if c in df6_f.columns]
            df6_detail = df6_f[detail_cols6].sort_values(['site', 'apn'])
            tab6_content += f'<div id="tab6_{safe_cls}" style="display:{display}">'
            tab6_content += "<h3>Network Level</h3>" + html_table(net6)
            tab6_content += "<h3>Site Level</h3>" + html_table(site6, table_id=f'tab6_site_{safe_cls}')
            tab6_content += "<h3>Part Detail</h3>" + html_table(df6_detail, table_id=f'tab6_detail_{safe_cls}')
            tab6_content += '</div>'
    else:
        tab6_content += "<p>No data (total_ordered column not found in tab1_2_6_datasource.csv)</p>"

    # --- TAB 7: Open PO Past Due ---
    tab7_content = "<h2>Open Purchase Orders - Past Due Summary</h2>"
    if df7 is not None:
        # Clean column name for Past Due Days
        past_due_col = 'Past Due Days' if 'Past Due Days' in df7.columns else None
        site_col = 'Site' if 'Site' in df7.columns else 'site'
        if past_due_col and site_col in df7.columns:
            df7[past_due_col] = pd.to_numeric(df7[past_due_col], errors='coerce').fillna(0)
            df7['is_past_due'] = (df7[past_due_col] > 0).astype(int)
            # Filters
            sites7 = sorted(df7[site_col].dropna().unique().tolist())
            crit7 = sorted(df7['Criticality'].dropna().unique().tolist()) if 'Criticality' in df7.columns else []
            site_opts7 = '<option value="all">All Sites</option>' + ''.join(f'<option value="{s}">{s}</option>' for s in sites7)
            crit_opts7 = '<option value="all">All</option>' + ''.join(f'<option value="{c}">{c}</option>' for c in crit7)
            tab7_content += f'<div class="filter-bar"><label>Criticality: </label><select onchange="filterTab7()" id="tab7_crit_filter">{crit_opts7}</select>'
            tab7_content += f' <label>Site: </label><select onchange="filterTab7()" id="tab7_site_filter">{site_opts7}</select></div>'
            # Network summary
            net7 = pd.DataFrame([{
                'total_open_po_lines': len(df7),
                'past_due_lines': int(df7['is_past_due'].sum()),
                'pct_past_due': round(100.0 * df7['is_past_due'].sum() / len(df7), 2) if len(df7) > 0 else 0
            }])
            tab7_content += "<h3>Network Summary</h3>" + html_table(net7)
            # Site summary
            site7 = df7.groupby(site_col).agg(
                total_open_po_lines=(past_due_col, 'count'),
                past_due_lines=('is_past_due', 'sum')
            ).reset_index()
            site7['pct_past_due'] = (100.0 * site7['past_due_lines'] / site7['total_open_po_lines']).round(2)
            site7 = site7.sort_values('pct_past_due', ascending=False)
            site7.columns = ['site', 'total_open_po_lines', 'past_due_lines', 'pct_past_due']
            tab7_content += "<h3>Site Summary</h3>" + html_table(site7, table_id='tab7_site_table')
            # Detail list
            detail_cols7 = [c for c in [site_col, 'APN', 'APN Description', 'Criticality', 'Order Number', 'Line Number', 'Supplier Name', 'Order Date', 'Due Date', past_due_col, 'Ordered Qty', 'Received Qty', 'Remaining Qty', 'Line Status'] if c in df7.columns]
            df7_detail = df7[detail_cols7].sort_values([past_due_col], ascending=False)
            tab7_content += "<h3>Open PO Details</h3>" + html_table(df7_detail, table_id='tab7_detail_table')
        else:
            tab7_content += "<p>Required columns not found</p>"
    else:
        tab7_content += "<p>No data (tab7_datasource_RSC.csv not found)</p>"

    # --- TAB 8: Site Scorecard ---
    tab8_content = "<h2>Site Scorecard — Criticality 1 USP Priority Ranking</h2>"
    scorecard_rows = []
    # Get sites from tab1_2_6 data
    if df12 is not None and 'site' in df12.columns:
        df_high = df12[(df12['sto_class'] == '01 HIGH') & (df12['product'] == 'USP')].copy() if 'sto_class' in df12.columns and 'product' in df12.columns else df12.copy()
        sites_all = df_high['site'].unique().tolist()
        for site in sites_all:
            site_data = df_high[df_high['site'] == site]
            total_parts = len(site_data)
            if total_parts == 0:
                continue
            # % zero OH
            zero_oh = int(site_data['is_zero_oh'].sum()) if 'is_zero_oh' in site_data.columns else 0
            pct_zero = round(100.0 * zero_oh / total_parts, 1)
            # % below min no PR
            below_min_no_pr = int(site_data['is_below_min_no_pr'].sum()) if 'is_below_min_no_pr' in site_data.columns else 0
            pct_below_min = round(100.0 * below_min_no_pr / total_parts, 1)
            # Order fill rate
            ordered = site_data['total_ordered'].sum() if 'total_ordered' in site_data.columns else 0
            received = site_data['total_received'].sum() if 'total_received' in site_data.columns else 0
            fill_rate = round(100.0 * received / ordered, 1) if ordered > 0 else None
            # Product
            product = site_data['product'].mode().iloc[0] if 'product' in site_data.columns and len(site_data['product'].mode()) > 0 else ''
            # Stuck PRs from tab3 (USP + 01 HIGH only)
            stuck_prs = 0
            if df3 is not None and 'site' in df3.columns:
                df3_filtered = df3[(df3['site'] == site)]
                if 'product' in df3.columns:
                    df3_filtered = df3_filtered[df3_filtered['product'] == 'USP']
                if 'sto_class' in df3.columns:
                    df3_filtered = df3_filtered[df3_filtered['sto_class'] == '01 HIGH']
                stuck_prs = len(df3_filtered)
            # PO past due from tab7 (USP + 01 HIGH only)
            po_past_due_pct = None
            if df7 is not None:
                site_col7 = 'Site' if 'Site' in df7.columns else 'site'
                if site_col7 in df7.columns:
                    site7_data = df7[df7[site_col7] == site]
                    if 'Criticality' in df7.columns:
                        site7_data = site7_data[site7_data['Criticality'] == '01 HIGH']
                    if 'APN Category' in df7.columns:
                        # Filter to USP APNs by checking if APN is in USP target list
                        usp_apns = set(df_high[df_high['site'] == site]['apn'].tolist()) if 'apn' in df_high.columns else set()
                        apn_col7 = 'APN' if 'APN' in site7_data.columns else 'apn'
                        if apn_col7 in site7_data.columns and usp_apns:
                            site7_data = site7_data[site7_data[apn_col7].isin(usp_apns)]
                    if len(site7_data) > 0:
                        po_past_due_pct = round(100.0 * site7_data['is_past_due'].sum() / len(site7_data), 1)
            # Risk score (weighted)
            risk = (3 * pct_zero) + (3 * pct_below_min) + (2 * stuck_prs) + (2 * (po_past_due_pct if po_past_due_pct else 0)) + (1 * (100 - fill_rate if fill_rate else 50))
            scorecard_rows.append({
                'site': site, 'product': product, 'total_crit1_parts': total_parts,
                'pct_zero_oh': pct_zero, 'pct_below_min_no_pr': pct_below_min,
                'stuck_prs': stuck_prs, 'pct_po_past_due': po_past_due_pct if po_past_due_pct else '-',
                'fill_rate': fill_rate if fill_rate else '-',
                'risk_score': round(risk, 1)
            })
    if scorecard_rows:
        scorecard_df = pd.DataFrame(scorecard_rows)
        scorecard_df = scorecard_df.sort_values('risk_score', ascending=False)
        scorecard_df['rank'] = range(1, len(scorecard_df) + 1)
        scorecard_df = scorecard_df[['rank', 'site', 'product', 'total_crit1_parts', 'pct_zero_oh', 'pct_below_min_no_pr', 'stuck_prs', 'pct_po_past_due', 'fill_rate', 'risk_score']]
        scorecard_df.columns = ['Rank', 'Site', 'Product', 'Total Crit1 Parts', '% Zero OH', '% Below Min (No PR)', 'Stuck PRs (>1wk)', '% PO Past Due', 'Fill Rate %', 'Risk Score']
        # Color coding via inline styles
        tab8_html = '<table id="tab8_table"><tr>'
        for col in scorecard_df.columns:
            tab8_html += f'<th>{col}</th>'
        tab8_html += '</tr>\n'
        for _, row in scorecard_df.iterrows():
            # Color risk_score
            score = row['Risk Score']
            if score > 200:
                color = '#d13212'
            elif score > 100:
                color = '#ff9900'
            else:
                color = '#1d8102'
            tab8_html += '<tr>'
            for col in scorecard_df.columns:
                val = row[col]
                if col == 'Risk Score':
                    tab8_html += f'<td style="color:{color};font-weight:bold">{val}</td>'
                elif col == '% Zero OH' and isinstance(val, (int, float)) and val > 10:
                    tab8_html += f'<td style="color:#d13212;font-weight:bold">{val}%</td>'
                elif col == '% Below Min (No PR)' and isinstance(val, (int, float)) and val > 10:
                    tab8_html += f'<td style="color:#d13212;font-weight:bold">{val}%</td>'
                elif col in ('% Zero OH', '% Below Min (No PR)', '% PO Past Due', 'Fill Rate %') and val != '-':
                    tab8_html += f'<td>{val}%</td>'
                else:
                    tab8_html += f'<td>{val}</td>'
            tab8_html += '</tr>\n'
        tab8_html += '</table>'
        tab8_content += "<p>Sites ranked by composite risk score for <b>Criticality 1 (01 HIGH)</b> parts only. Higher score = higher priority.</p>"
        tab8_content += "<p><small>Score = 3×(% zero OH) + 3×(% below min no PR) + 2×(stuck PRs) + 2×(% PO past due) + 1×(100 - fill rate)</small></p>"
        tab8_content += tab8_html
    else:
        tab8_content += "<p>No data available for scorecard</p>"

    # --- BUILD HTML ---
    html = f"""<!DOCTYPE html>
<html>
<head>
<title>Critical Spares Flash Report - {today}</title>
<style>
  body {{ font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }}
  h1 {{ color: #232f3e; }}
  h2 {{ color: #ff9900; }}
  h3 {{ color: #333; margin-top: 20px; }}
  .tabs {{ display: flex; gap: 2px; margin-bottom: 0; }}
  .tabs button {{ padding: 10px 20px; border: none; background: #ddd; cursor: pointer; font-size: 14px; border-radius: 4px 4px 0 0; }}
  .tabs button.active {{ background: #232f3e; color: white; }}
  .tab-content {{ display: none; padding: 20px; background: white; border-radius: 0 4px 4px 4px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
  .tab-content.active {{ display: block; }}
  table {{ border-collapse: collapse; width: 100%; margin-top: 10px; font-size: 13px; }}
  th {{ background: #232f3e; color: white; padding: 8px 6px; text-align: left; position: sticky; top: 0; }}
  td {{ padding: 6px; border-bottom: 1px solid #eee; }}
  tr:hover {{ background: #f9f9f9; }}
  .date {{ color: #666; font-size: 14px; }}
  .filter-bar {{ margin: 10px 0; padding: 10px; background: #eee; border-radius: 4px; }}
  .filter-bar select {{ padding: 4px 8px; margin-right: 10px; }}
</style>
</head>
<body>
<h1>Critical Spares Daily Flash Report</h1>
<p class="date">Report Date: {today}</p>

<div class="tabs">
  <button class="active" onclick="openTab(event,'tab1')">Zero OH %</button>
  <button onclick="openTab(event,'tab2')">Below Min No PR %</button>
  <button onclick="openTab(event,'tab3')">Open PRs &gt; 1wk</button>
  <button onclick="openTab(event,'tab4')">Top 10 Replacement</button>
  <button onclick="openTab(event,'tab5')">Expected vs Actual</button>
  <button onclick="openTab(event,'tab6')">Order Fill Rate</button>
  <button onclick="openTab(event,'tab7')">Open PO Past Due</button>
  <button onclick="openTab(event,'tab8')">Site Scorecard</button>
</div>

<div id="tab1" class="tab-content active">{tab1_content}</div>
<div id="tab2" class="tab-content">{tab2_content}</div>
<div id="tab3" class="tab-content">{tab3_content}</div>
<div id="tab4" class="tab-content">{tab4_content}</div>
<div id="tab5" class="tab-content">{tab5_content}</div>
<div id="tab6" class="tab-content">{tab6_content}</div>
<div id="tab7" class="tab-content">{tab7_content}</div>
<div id="tab8" class="tab-content">{tab8_content}</div>

<script>
function switchView(prefix, value) {{
  var safeVal = value.replace(/ /g, '_');
  var allDivs = document.querySelectorAll('div[id^="' + prefix + '_"]');
  allDivs.forEach(function(div) {{ div.style.display = 'none'; }});
  var target = document.getElementById(prefix + '_' + safeVal);
  if (target) target.style.display = 'block';
}}

function filterTab1Site() {{
  var siteVal = document.getElementById('tab1_site_filter').value;
  var prodVal = document.getElementById('tab1_product_filter').value;
  // Filter site summary table
  var table = document.getElementById('tab1_site_table');
  var rows = table.querySelectorAll('tr');
  for (var i = 1; i < rows.length; i++) {{
    var cells = rows[i].querySelectorAll('td');
    if (cells.length < 2) continue;
    var rowSite = cells[0].textContent;
    var rowProd = cells[1].textContent;
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    rows[i].style.display = (showSite && showProd) ? '' : 'none';
  }}
  // Filter detail table (site is col 0, product is col 2)
  var detailTable = document.getElementById('tab1_detail_table');
  if (detailTable) {{
    var dRows = detailTable.querySelectorAll('tr');
    for (var j = 1; j < dRows.length; j++) {{
      var dCells = dRows[j].querySelectorAll('td');
      if (dCells.length < 3) continue;
      var dSite = dCells[0].textContent;
      var dProd = dCells[2].textContent;
      var dShowSite = (siteVal === 'all' || dSite === siteVal);
      var dShowProd = (prodVal === 'all' || dProd === prodVal);
      dRows[j].style.display = (dShowSite && dShowProd) ? '' : 'none';
    }}
  }}
}}

function filterTab7() {{
  var critVal = document.getElementById('tab7_crit_filter').value;
  var siteVal = document.getElementById('tab7_site_filter').value;
  // Site table: site(0)
  var siteTable = document.getElementById('tab7_site_table');
  if (siteTable) {{
    var rows = siteTable.querySelectorAll('tr');
    for (var i = 1; i < rows.length; i++) {{
      var cells = rows[i].querySelectorAll('td');
      if (cells.length < 1) continue;
      var rowSite = cells[0].textContent;
      rows[i].style.display = (siteVal === 'all' || rowSite === siteVal) ? '' : 'none';
    }}
  }}
  // Detail table: site(0), APN(1), desc(2), criticality(3)
  var detailTable = document.getElementById('tab7_detail_table');
  if (detailTable) {{
    var dRows = detailTable.querySelectorAll('tr');
    for (var j = 1; j < dRows.length; j++) {{
      var dCells = dRows[j].querySelectorAll('td');
      if (dCells.length < 4) continue;
      var dSite = dCells[0].textContent;
      var dCrit = dCells[3].textContent;
      var dShowSite = (siteVal === 'all' || dSite === siteVal);
      var dShowCrit = (critVal === 'all' || dCrit === critVal);
      dRows[j].style.display = (dShowSite && dShowCrit) ? '' : 'none';
    }}
  }}
}}

function filterTab6() {{
  var siteVal = document.getElementById('tab6_site_filter').value;
  var prodVal = document.getElementById('tab6_product_filter').value;
  // Filter all visible tab6 site and detail tables by site and product
  var tables = document.querySelectorAll('[id^="tab6_site_"], [id^="tab6_detail_"]');
  tables.forEach(function(table) {{
    var rows = table.querySelectorAll('tr');
    for (var i = 1; i < rows.length; i++) {{
      var cells = rows[i].querySelectorAll('td');
      if (cells.length < 2) continue;
      var rowSite = cells[0].textContent;
      var rowProd = cells[1].textContent;
      // For detail tables, product is at index 2
      if (cells.length > 4) rowProd = cells[2].textContent;
      var showSite = (siteVal === 'all' || rowSite === siteVal);
      var showProd = (prodVal === 'all' || rowProd === prodVal);
      rows[i].style.display = (showSite && showProd) ? '' : 'none';
    }}
  }});
}}

function filterTab5Site() {{
  var siteVal = document.getElementById('tab5_site_filter').value;
  var prodVal = document.getElementById('tab5_product_filter').value;
  var tables = document.querySelectorAll('[id^="tab5_site_"], [id^="tab5_detail_"]');
  tables.forEach(function(table) {{
    var rows = table.querySelectorAll('tr');
    for (var i = 1; i < rows.length; i++) {{
      var cells = rows[i].querySelectorAll('td');
      if (cells.length < 2) continue;
      var rowSite = cells[0].textContent;
      var rowProd = cells[1].textContent;
      var showSite = (siteVal === 'all' || rowSite === siteVal);
      var showProd = (prodVal === 'all' || rowProd === prodVal);
      rows[i].style.display = (showSite && showProd) ? '' : 'none';
    }}
  }});
}}

function filterTab3Site() {{
  var siteVal = document.getElementById('tab3_site_filter').value;
  var prodVal = document.getElementById('tab3_product_filter').value;
  // Filter all visible tab3 site summary and detail tables
  var tables = document.querySelectorAll('[id^="tab3_site_"], [id^="tab3_detail_"]');
  tables.forEach(function(table) {{
    var rows = table.querySelectorAll('tr');
    for (var i = 1; i < rows.length; i++) {{
      var cells = rows[i].querySelectorAll('td');
      if (cells.length < 2) continue;
      var rowSite = cells[0].textContent;
      var rowProd = cells[1].textContent;
      var showSite = (siteVal === 'all' || rowSite === siteVal);
      var showProd = (prodVal === 'all' || rowProd === prodVal);
      rows[i].style.display = (showSite && showProd) ? '' : 'none';
    }}
  }});
}}

function filterTab2Site() {{
  var siteVal = document.getElementById('tab2_site_filter').value;
  var prodVal = document.getElementById('tab2_product_filter').value;
  // Filter site summary table
  var table = document.getElementById('tab2_site_table');
  var rows = table.querySelectorAll('tr');
  for (var i = 1; i < rows.length; i++) {{
    var cells = rows[i].querySelectorAll('td');
    if (cells.length < 2) continue;
    var rowSite = cells[0].textContent;
    var rowProd = cells[1].textContent;
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    rows[i].style.display = (showSite && showProd) ? '' : 'none';
  }}
  // Filter detail table (site=col0, product=col2)
  var detailTable = document.getElementById('tab2_detail_table');
  if (detailTable) {{
    var dRows = detailTable.querySelectorAll('tr');
    for (var j = 1; j < dRows.length; j++) {{
      var dCells = dRows[j].querySelectorAll('td');
      if (dCells.length < 3) continue;
      var dSite = dCells[0].textContent;
      var dProd = dCells[2].textContent;
      var dShowSite = (siteVal === 'all' || dSite === siteVal);
      var dShowProd = (prodVal === 'all' || dProd === prodVal);
      dRows[j].style.display = (dShowSite && dShowProd) ? '' : 'none';
    }}
  }}
}}

function openTab(evt, tabId) {{
  document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.tabs button').forEach(b => b.classList.remove('active'));
  document.getElementById(tabId).classList.add('active');
  evt.target.classList.add('active');
}}
</script>
</body>
</html>"""

    with open(OUTPUT_FILE, 'w') as f:
        f.write(html)
    print(f"Report generated: {OUTPUT_FILE}")

if __name__ == '__main__':
    generate_report()
