"""
Generate RSPL Flash Report from single datasource.
Usage: python3 generate_flash_report.py

Input: flash_report_datasource.csv (from flash_report_all_queries.sql)
Output: flash_report.html
"""

import pandas as pd
from datetime import date
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_FILE = os.path.join(SCRIPT_DIR, 'flash_report.html')


def html_table(df, table_id=None, show_product=False):
    """Generate HTML table. If _product col exists, add as data-product attr on rows.
    If show_product=True, also display it as a visible 'Product' column."""
    if df is None or df.empty:
        return "<p>No data available</p>"
    tid = f' id="{table_id}"' if table_id else ''
    if show_product and '_product' in df.columns:
        display_cols = ['_product'] + [c for c in df.columns if c != '_product']
        header_names = ['Product'] + [c for c in df.columns if c != '_product']
    else:
        display_cols = [c for c in df.columns if c != '_product']
        header_names = display_cols
    html = f'<table{tid}><tr>' + ''.join(f'<th>{c}</th>' for c in header_names) + '</tr>\n'
    for _, row in df.iterrows():
        prod_attr = f' data-product="{row["_product"]}"' if '_product' in df.columns else ''
        html += f'<tr{prod_attr}>' + ''.join(f'<td>{row[c]}</td>' for c in display_cols) + '</tr>\n'
    html += '</table>'
    return html


def generate_report():
    today = date.today().strftime('%B %d, %Y')

    df = pd.read_csv(os.path.join(SCRIPT_DIR, 'flash_report_datasource.csv'))

    # Fill NaN sto_class for "Not in APM" parts
    df['sto_class'] = df['sto_class'].fillna('Not in APM')

    # Handle product column - default to 'USP' if not present
    if 'product' not in df.columns:
        df['product'] = 'USP'
    df['product'] = df['product'].fillna('USP')

    # Numeric conversions
    for col in ['site_oh_qty', 'min_level', 'max_level', 'is_zero_oh', 'is_below_min',
                'is_below_min_no_pr', 'has_active_pr', 'total_ordered', 'total_received',
                'pct_received', 'req_qty', 'days_open']:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors='coerce')

    # Site launch date lookup
    site_launch = {}
    if 'launch_date' in df.columns:
        site_launch = df.groupby('site')['launch_date'].first().to_dict()

    # Product + Site filter options
    products = sorted(df['product'].unique().tolist())
    product_opts = '<option value="all">All Products</option>' + ''.join(f'<option value="{p}">{p}</option>' for p in products)

    sites = sorted(df['site'].dropna().unique().tolist())
    site_opts = '<option value="all">All Sites</option>' + ''.join(f'<option value="{s}">{s}</option>' for s in sites)

    # =========================================================================
    # TAB 1: Full Detail View
    # =========================================================================
    detail_cols = ['product', 'site', 'mpn', 'catalog_reference', 'r5_apn', 'part_description',
                   'site_oh_qty', 'min_level', 'max_level', 'mapping_status']
    df_detail = df[detail_cols].sort_values(['product', 'site', 'mpn', 'r5_apn']).copy()
    # Derive Y/N flag from mapping_status: "No APN found" → N, anything else → Y
    df_detail['created_in_apm'] = df_detail['mapping_status'].apply(
        lambda x: 'N' if str(x).strip() == 'No APN found' else 'Y'
    )
    df_detail = df_detail.drop(columns=['mapping_status'])
    df_detail.columns = ['Product', 'Site', 'MPN', 'Catalogue Ref', 'APN', 'Description',
                         'OH Qty', 'MIN', 'MAX', 'Created in APM']

    # Site summary: per MPN+CatRef combination
    df_combo = df.groupby(['product', 'site', 'mpn', 'catalog_reference']).agg(
        total_apns=('r5_apn', 'count'),
        any_oh_gt_zero=('site_oh_qty', lambda x: (x.fillna(0) > 0).any()),
        is_not_in_apm=('mapping_status', lambda x: (x == 'No APN found').all())
    ).reset_index()

    site_summary = df_combo.groupby(['product', 'site']).agg(
        total_rspl=('mpn', 'count'),
        in_apm=('is_not_in_apm', lambda x: (~x).sum()),
        zero_oh=('any_oh_gt_zero', lambda x: (~x).sum())
    ).reset_index()
    # zero_oh includes "not in apm" parts — subtract those that are not in APM
    not_in_apm_count = df_combo.groupby(['product', 'site'])['is_not_in_apm'].sum().reset_index()
    not_in_apm_count.columns = ['product', 'site', 'not_in_apm_cnt']
    site_summary = site_summary.merge(not_in_apm_count, on=['product', 'site'], how='left')
    site_summary['zero_oh'] = site_summary['zero_oh'] - site_summary['not_in_apm_cnt']
    site_summary = site_summary.sort_values(['product', 'site'])
    site_summary['launch_date'] = site_summary['site'].map(site_launch)
    site_summary = site_summary[['product', 'site', 'launch_date', 'total_rspl', 'in_apm', 'zero_oh']]
    site_summary.columns = ['_product', 'Site', 'Launch Date', 'Total RSPL Parts (Unique MPN/CRN)', 'RSPL Parts in APM', 'MPN/CRN with 0/Null OH']

    # Group-level stock coverage: a (product, site, mpn, catref) combo is "covered"
    # if ANY of its APNs has OH > 0. When covered, we do NOT red-highlight its
    # zero/null-OH sibling APNs — the part is usable via the stocked APN.
    covered_groups = set(
        tuple(r) for r in df_combo.loc[df_combo['any_oh_gt_zero'],
                                       ['product', 'site', 'mpn', 'catalog_reference']].itertuples(index=False, name=None)
    )

    def _norm(v):
        return v if pd.notna(v) else None

    # Build detail table with red highlighting and product attr
    detail_html = '<table id="tab1_detail"><tr>' + ''.join(f'<th>{c}</th>' for c in df_detail.columns) + '</tr>\n'
    for _, row in df_detail.iterrows():
        oh = row['OH Qty']
        prod = row['Product']
        group_key = (_norm(row['Product']), _norm(row['Site']), _norm(row['MPN']), _norm(row['Catalogue Ref']))
        group_covered = group_key in covered_groups
        # Not-in-APM (no APN) is always flagged. A stockout (0/null OH) is flagged
        # only when no sibling APN in the same MPN+CRN group has stock.
        is_stockout = pd.isna(oh) or str(oh).strip() in ('', 'nan') or float(oh) == 0
        is_not_in_apm = str(row['Created in APM']).strip() == 'N'
        is_red = is_not_in_apm or (is_stockout and not group_covered)
        color = 'background:#ffe0e0;' if is_red else ''
        red_attr = ' data-red="1"' if is_red else ''
        detail_html += f'<tr data-product="{prod}"{red_attr} style="{color}">'
        for col in df_detail.columns:
            val = row[col] if pd.notna(row[col]) else ''
            detail_html += f'<td>{val}</td>'
        detail_html += '</tr>\n'
    detail_html += '</table>'

    # Network summaries per product + "all"
    def build_net_summary(df_c):
        total = len(df_c)
        in_apm = int((~df_c['is_not_in_apm']).sum())
        niapm = int(df_c['is_not_in_apm'].sum())
        zoh = int((~df_c['any_oh_gt_zero']).sum()) - niapm
        ns = df_c['site'].nunique()
        return {
            'Total Sites': ns,
            'Total RSPL Parts (Unique MPN/CRN)': total,
            'RSPL Parts in APM': in_apm,
            'MPN/CRN with 0/Null OH': zoh,
            '% in APM': round(100.0 * in_apm / max(total, 1), 2),
            '% 0/Null OH': round(100.0 * zoh / max(total, 1), 2)
        }

    # Network summaries per product as a table with Product column
    net_rows = []
    for p in products:
        row_data = build_net_summary(df_combo[df_combo['product'] == p])
        row_data['_product'] = p
        net_rows.append(row_data)
    # Add "All" row
    all_row = build_net_summary(df_combo)
    all_row['_product'] = 'All'
    net_rows.append(all_row)
    net_df = pd.DataFrame(net_rows)
    # Reorder columns
    net_df = net_df[['_product', 'Total Sites', 'Total RSPL Parts (Unique MPN/CRN)', 'RSPL Parts in APM',
                     'MPN/CRN with 0/Null OH', '% in APM', '% 0/Null OH']]

    tab1 = "<h2>KPI 1: Stock Status Detail</h2>"
    tab1 += f"""<div class="filter-bar">
  <label>Product: </label><select onchange="applyProductFilter()" id="tab1_product_filter">{product_opts}</select>
  <label>Site: </label><select onchange="filterDetailTable()" id="tab1_site_filter">{site_opts}</select>
  <label>MPN Search: </label><input type="text" id="tab1_mpn_search" onkeyup="filterDetailTable()" placeholder="Type MPN..." style="padding:4px 8px">
  <label style="margin-left:12px;"><input type="checkbox" id="tab1_red_only" onchange="filterDetailTable()"> Red rows only (stockout or not in APM)</label>
</div>"""
    tab1 += "<h3>Network Summary</h3>" + html_table(net_df, table_id='tab1_network', show_product=True)
    tab1 += "<h3>Site Summary</h3>" + html_table(site_summary, table_id='tab1_summary', show_product=True)
    tab1 += "<h3>Detail</h3>" + '<button class="export-btn" onclick="exportTableCSV(\'tab1_detail\',\'kpi1_stock_detail.csv\')">Export CSV</button>' + detail_html

    # =========================================================================
    # TAB 2: Below Min No PR %
    # =========================================================================
    df_in_apm = df[df['mapping_status'] != 'No APN found']

    # Network level per product as table
    net2_rows = []
    for p in products:
        sub = df_in_apm[df_in_apm['product'] == p]
        sub_combo = df_combo[df_combo['product'] == p]
        t_rspl = len(sub_combo)
        t_apns = len(sub)
        t_below = int(sub['is_below_min_no_pr'].sum())
        pct = round(100.0 * t_below / max(t_apns, 1), 2)
        net2_rows.append({
            '_product': p,
            'Total RSPL Parts (MPN×Site)': t_rspl,
            'Total APNs': t_apns,
            'Below MIN (No PR)': t_below,
            '% Below MIN (No PR)': pct
        })
    # All row
    t_rspl_all = len(df_combo)
    t_apns_all = len(df_in_apm)
    t_below_all = int(df_in_apm['is_below_min_no_pr'].sum())
    pct_all = round(100.0 * t_below_all / max(t_apns_all, 1), 2)
    net2_rows.append({
        '_product': 'All',
        'Total RSPL Parts (MPN×Site)': t_rspl_all,
        'Total APNs': t_apns_all,
        'Below MIN (No PR)': t_below_all,
        '% Below MIN (No PR)': pct_all
    })
    net2_df = pd.DataFrame(net2_rows)

    # Site level
    rspl_per_site = df.groupby(['product', 'site'])['mpn'].nunique().reset_index()
    rspl_per_site.columns = ['product', 'site', 'total_rspl']

    site2 = df_in_apm.groupby(['product', 'site']).agg(
        total_apns=('r5_apn', 'count'),
        below_min_no_pr=('is_below_min_no_pr', 'sum')
    ).reset_index()
    site2 = site2.merge(rspl_per_site, on=['product', 'site'], how='left')
    site2['% Below MIN (No PR)'] = (100.0 * site2['below_min_no_pr'] / site2['total_apns']).round(2)
    site2 = site2.sort_values('% Below MIN (No PR)', ascending=False)
    site2['launch_date'] = site2['site'].map(site_launch)
    site2 = site2[['product', 'site', 'launch_date', 'total_rspl', 'total_apns', 'below_min_no_pr', '% Below MIN (No PR)']]
    site2.columns = ['_product', 'Site', 'Launch Date', 'Total RSPL Parts', 'Total APNs', 'Below MIN (No PR)', '% Below MIN (No PR)']

    tab2 = "<h2>KPI 3: % of Parts Below Min Without Active PR</h2>"
    tab2 += f"""<div class="filter-bar">
  <label>Product: </label><select onchange="applyProductFilter()" id="tab2_product_filter">{product_opts}</select>
  <label>Site: </label><select onchange="filterSiteTable('tab2_site');filterTab2Detail()" id="tab2_site_filter">{site_opts}</select>
  <label>MPN Search: </label><input type="text" id="tab2_mpn_search" onkeyup="filterTab2Detail()" placeholder="Type MPN..." style="padding:4px 8px">
</div>"""
    tab2 += "<h3>Network Level</h3>" + html_table(net2_df, table_id='tab2_network', show_product=True)
    tab2 += "<h3>Site Level</h3>" + html_table(site2, table_id='tab2_site', show_product=True)

    # Detail: parts below MIN with no PR
    df_below = df_in_apm[df_in_apm['is_below_min_no_pr'] == 1].copy()
    if not df_below.empty:
        detail2 = df_below[['product', 'site', 'mpn', 'catalog_reference', 'r5_apn', 'part_description',
                            'site_oh_qty', 'min_level', 'max_level']].sort_values(['product', 'site', 'mpn'])
        detail2.columns = ['_product', 'Site', 'MPN', 'Catalogue Ref', 'APN', 'Description', 'OH Qty', 'MIN', 'MAX']
    else:
        detail2 = pd.DataFrame()
    tab2 += "<h3>Detail: Parts Below MIN (No PR)</h3>" + '<button class="export-btn" onclick="exportTableCSV(\'tab2_detail\',\'kpi3_below_min_no_pr.csv\')">Export CSV</button>' + html_table(detail2, table_id='tab2_detail', show_product=True)

    # =========================================================================
    # TAB 3: Open PRs > 1 week
    # =========================================================================
    df_pr = df[(df['has_active_pr'] == 1) & (df['days_open'] > 7)].copy()

    site3 = df_in_apm.groupby(['product', 'site']).agg(
        total_apns=('r5_apn', 'count')
    ).reset_index()
    site3 = site3.merge(rspl_per_site, on=['product', 'site'], how='left')
    pr_by_site = df_pr.groupby(['product', 'site']).agg(stuck_prs=('r5_apn', 'nunique')).reset_index()
    site3 = site3.merge(pr_by_site, on=['product', 'site'], how='left')
    site3['stuck_prs'] = site3['stuck_prs'].fillna(0).astype(int)
    site3 = site3.sort_values('stuck_prs', ascending=False)
    site3['launch_date'] = site3['site'].map(site_launch)
    site3 = site3[['product', 'site', 'launch_date', 'total_rspl', 'total_apns', 'stuck_prs']]
    site3.columns = ['_product', 'Site', 'Launch Date', 'Total RSPL Parts', 'Total APNs', 'APNs with PR > 1wk']

    if not df_pr.empty:
        detail3 = df_pr[['product', 'site', 'mpn', 'r5_apn', 'part_description',
                         'req_number', 'req_qty', 'req_date', 'days_open']].sort_values('days_open', ascending=False)
        detail3.columns = ['_product', 'Site', 'MPN', 'APN', 'Description', 'PR Number', 'PR Qty', 'PR Date', 'Days Open']
    else:
        detail3 = pd.DataFrame()

    tab3 = "<h2>KPI 4: Parts with Open Purchase Requisitions &gt; 1 Week</h2>"
    tab3 += f"""<div class="filter-bar">
  <label>Product: </label><select onchange="applyProductFilter()" id="tab3_product_filter">{product_opts}</select>
  <label>Site: </label><select onchange="filterSiteTable('tab3_site');filterTab3Detail()" id="tab3_site_filter">{site_opts}</select>
  <label>MPN Search: </label><input type="text" id="tab3_mpn_search" onkeyup="filterTab3Detail()" placeholder="Type MPN..." style="padding:4px 8px">
</div>"""
    tab3 += "<h3>Site Summary</h3>" + html_table(site3, table_id='tab3_site', show_product=True)
    tab3 += "<h3>Detail</h3>" + '<button class="export-btn" onclick="exportTableCSV(\'tab3_detail\',\'kpi4_open_prs_gt_1wk.csv\')">Export CSV</button>' + html_table(detail3, table_id='tab3_detail', show_product=True)

    # =========================================================================
    # TAB 4: RSPL Receipt Rate
    # =========================================================================
    df_ord = df_in_apm[df_in_apm['total_ordered'] > 0].copy()

    site4 = df_in_apm.groupby(['product', 'site']).agg(
        total_apns=('r5_apn', 'count')
    ).reset_index()
    site4 = site4.merge(rspl_per_site, on=['product', 'site'], how='left')
    ord_by_site = df_ord.groupby(['product', 'site']).agg(
        total_ordered=('total_ordered', 'sum'),
        total_received=('total_received', 'sum')
    ).reset_index()
    ord_by_site['Receipt %'] = (100.0 * ord_by_site['total_received'] / ord_by_site['total_ordered']).round(2)
    site4 = site4.merge(ord_by_site, on=['product', 'site'], how='left')
    site4 = site4.sort_values('Receipt %', ascending=True)
    site4['launch_date'] = site4['site'].map(site_launch)
    site4 = site4[['product', 'site', 'launch_date', 'total_rspl', 'total_apns', 'total_ordered', 'total_received', 'Receipt %']]
    site4.columns = ['_product', 'Site', 'Launch Date', 'Total RSPL Parts', 'Total APNs', 'Qty Ordered', 'Qty Received', 'Receipt %']

    if not df_ord.empty:
        detail4 = df_ord[['product', 'site', 'mpn', 'r5_apn', 'part_description',
                          'total_ordered', 'total_received', 'pct_received']].sort_values(['product', 'site', 'mpn'])
        detail4.columns = ['_product', 'Site', 'MPN', 'APN', 'Description', 'Qty Ordered', 'Qty Received', 'Receipt %']
    else:
        detail4 = pd.DataFrame()

    tab4 = "<h2>KPI 5: RSPL Receipt Rate</h2>"
    tab4 += f"""<div class="filter-bar">
  <label>Product: </label><select onchange="applyProductFilter()" id="tab4_product_filter">{product_opts}</select>
  <label>Site: </label><select onchange="filterSiteTable('tab4_site');filterTab4Detail()" id="tab4_site_filter">{site_opts}</select>
  <label>MPN Search: </label><input type="text" id="tab4_mpn_search" onkeyup="filterTab4Detail()" placeholder="Type MPN..." style="padding:4px 8px">
</div>"""
    tab4 += "<h3>Site Summary</h3>" + html_table(site4, table_id='tab4_site', show_product=True)
    tab4 += "<h3>Detail</h3>" + '<button class="export-btn" onclick="exportTableCSV(\'tab4_detail\',\'kpi5_receipt_rate.csv\')">Export CSV</button>' + html_table(detail4, table_id='tab4_detail', show_product=True)

    # =========================================================================
    # TAB 5: Open POs
    # =========================================================================
    has_po_data = 'po_number' in df.columns
    if has_po_data:
        df_po = df[df['po_number'].notna() & (df['po_number'] != '')].copy()
        for col in ['po_qty_ordered', 'po_qty_received', 'po_qty_outstanding']:
            if col in df_po.columns:
                df_po[col] = pd.to_numeric(df_po[col], errors='coerce')
    else:
        df_po = pd.DataFrame()

    if not df_po.empty:
        # Site summary: count of APNs with open POs per site
        po_site = df_po.groupby(['product', 'site']).agg(
            open_po_lines=('r5_apn', 'count'),
            total_outstanding=('po_qty_outstanding', 'sum')
        ).reset_index()
        # Add total RSPL parts per site and total with open PO (unique MPN/CRN)
        rspl_per_site_po = df.groupby(['product', 'site'])[['mpn', 'catalog_reference']].apply(
            lambda x: x.drop_duplicates().shape[0]).reset_index()
        rspl_per_site_po.columns = ['product', 'site', 'total_rspl']
        rspl_with_po = df_po.groupby(['product', 'site'])[['mpn']].apply(
            lambda x: x.drop_duplicates().shape[0]).reset_index()
        rspl_with_po.columns = ['product', 'site', 'rspl_with_po']
        po_site = po_site.merge(rspl_per_site_po, on=['product', 'site'], how='left')
        po_site = po_site.merge(rspl_with_po, on=['product', 'site'], how='left')
        po_site['launch_date'] = po_site['site'].map(site_launch)
        po_site = po_site.sort_values('total_outstanding', ascending=False)
        po_site = po_site[['product', 'site', 'launch_date', 'total_rspl', 'rspl_with_po', 'open_po_lines', 'total_outstanding']]
        po_site.columns = ['_product', 'Site', 'Launch Date', 'Total RSPL Parts (MPN×Site)', 'RSPL Parts with Open PO', 'Open PO Lines', 'Total Qty Outstanding']

        # Detail
        detail5 = df_po[['product', 'site', 'mpn', 'catalog_reference', 'r5_apn', 'part_description',
                         'po_number', 'po_qty_ordered', 'po_qty_received', 'po_qty_outstanding',
                         'po_date']].sort_values(['product', 'site', 'po_number', 'r5_apn'])
        detail5.columns = ['_product', 'Site', 'MPN', 'CRN', 'APN', 'Description',
                           'PO Number', 'Qty Ordered', 'Qty Received', 'Qty Outstanding', 'PO Date']
    else:
        po_site = pd.DataFrame()
        detail5 = pd.DataFrame()

    tab5 = "<h2>KPI 6: Open Purchase Orders</h2>"
    tab5 += f"""<div class="filter-bar">
  <label>Product: </label><select onchange="applyProductFilter()" id="tab5_product_filter">{product_opts}</select>
  <label>Site: </label><select onchange="filterSiteTable('tab5_site');filterTab5Detail()" id="tab5_site_filter">{site_opts}</select>
  <label>MPN Search: </label><input type="text" id="tab5_mpn_search" onkeyup="filterTab5Detail()" placeholder="Type MPN..." style="padding:4px 8px">
</div>"""
    tab5 += "<h3>Site Summary</h3>" + html_table(po_site, table_id='tab5_site', show_product=True)
    tab5 += "<h3>Detail</h3>" + '<button class="export-btn" onclick="exportTableCSV(\'tab5_detail\',\'kpi6_open_pos.csv\')">Export CSV</button>' + html_table(detail5, table_id='tab5_detail', show_product=True)

    # =========================================================================
    # TAB 6: APN Heatmap (MPN × Site)
    # =========================================================================
    heatmap_sites = sorted(df['site'].dropna().unique().tolist())
    heatmap_mpns = df.groupby(['mpn', 'catalog_reference', 'product']).size().reset_index()[['mpn', 'catalog_reference', 'product']].drop_duplicates()
    heatmap_mpns = heatmap_mpns.sort_values(['product', 'mpn'])

    # Build site-to-products mapping (which products each site belongs to)
    site_products = df.groupby('site')['product'].apply(lambda x: ','.join(sorted(x.unique()))).to_dict()

    # Build pivot: for each mpn+site, comma-join the APNs
    pivot_data = df[df['mapping_status'] != 'No APN found'].groupby(['mpn', 'catalog_reference', 'site'])['r5_apn'].apply(
        lambda x: ', '.join(sorted(x.dropna().astype(str).unique()))
    ).reset_index()
    pivot_data.columns = ['mpn', 'catalog_reference', 'site', 'apns']

    # Sites with no APN found
    no_apn_sites = df[df['mapping_status'] == 'No APN found'][['mpn', 'catalog_reference', 'site']].drop_duplicates()
    no_apn_set = set(zip(no_apn_sites['mpn'], no_apn_sites['site']))

    # Build HTML heatmap table
    heatmap_html = '<div style="overflow-x:auto;max-height:80vh;overflow-y:auto;"><table id="heatmap_table" style="font-size:12px;border-collapse:collapse;table-layout:fixed;"><tr><th style="position:sticky;left:0;top:0;background:#232f3e;z-index:3;min-width:180px;width:180px;">MPN</th><th style="position:sticky;left:180px;top:0;background:#232f3e;z-index:3;min-width:90px;width:90px;">CatRef</th>'
    for site in heatmap_sites:
        prods_for_site = site_products.get(site, '')
        heatmap_html += f'<th class="heatmap-site-col" data-site="{site}" data-products="{prods_for_site}" style="position:sticky;top:0;background:#232f3e;z-index:1;min-width:55px;width:55px;text-align:center;padding:4px 2px;font-size:10px;white-space:nowrap;">{site}</th>'
    heatmap_html += '</tr>\n'

    for _, mpn_row in heatmap_mpns.iterrows():
        mpn = mpn_row['mpn']
        catref = mpn_row['catalog_reference'] if pd.notna(mpn_row['catalog_reference']) else ''
        prod = mpn_row['product']
        heatmap_html += f'<tr data-mpn="{mpn}" data-product="{prod}"><td style="position:sticky;left:0;background:white;z-index:2;white-space:nowrap;font-weight:500;border-right:1px solid #ddd;padding:4px 6px;">{mpn}</td><td style="position:sticky;left:180px;background:white;z-index:2;white-space:nowrap;font-size:11px;border-right:2px solid #232f3e;padding:4px 6px;">{catref}</td>'
        for site in heatmap_sites:
            match = pivot_data[(pivot_data['mpn'] == mpn) & (pivot_data['site'] == site)]
            if not match.empty:
                apns = match.iloc[0]['apns']
                heatmap_html += f'<td style="background:#d4edda;padding:3px 4px;font-size:11px;text-align:center;overflow:hidden;text-overflow:ellipsis;max-width:55px;" title="{apns}">{apns}</td>'
            elif (mpn, site) in no_apn_set:
                heatmap_html += '<td style="background:#f8d7da;text-align:center;padding:3px;">✗</td>'
            else:
                heatmap_html += '<td style="background:#eee;text-align:center;padding:3px;">-</td>'
        heatmap_html += '</tr>\n'
    heatmap_html += '</table></div>'

    # Summary stats
    total_cells = len(heatmap_mpns) * len(heatmap_sites)
    green_cells = len(pivot_data.drop_duplicates(['mpn', 'site']))
    red_cells = len(no_apn_set)

    # KPI 6 product filter: single product only, default USP
    product_opts_kpi6 = ''.join(
        f'<option value="{p}"{" selected" if p == "USP" else ""}>{p}</option>' for p in products
    )

    tab6 = "<h2>KPI 7: APN Heatmap</h2>"
    tab6 += f"""<div class="filter-bar">
  <label>Product: </label><select onchange="applyProductFilter()" id="tab6_product_filter">{product_opts_kpi6}</select>
  <label>Site: </label><select onchange="filterHeatmap()" id="tab6_site_filter">{site_opts}</select>
  <label>MPN Search: </label><input type="text" id="tab6_mpn_search" onkeyup="filterHeatmap()" placeholder="Type MPN..." style="padding:4px 8px">
</div>"""
    tab6 += f"<p>MPNs: {len(heatmap_mpns)} | Sites: {len(heatmap_sites)} | "
    tab6 += f"<span style='color:green'>Green: {green_cells} ({round(100*green_cells/max(total_cells,1),1)}%)</span> | "
    tab6 += f"<span style='color:red'>Red: {red_cells} ({round(100*red_cells/max(total_cells,1),1)}%)</span></p>"
    tab6 += heatmap_html

    # =========================================================================
    # TAB 7: Unavailable Parts — PR/PO Status
    #   Parts that are stocked out (0 or NULL OH) OR not in APM.
    #   One row per MPN/CRN + APN (+ site). PR (req_status='A') and open PO
    #   (ord_status IN ('A','PR') & orl_status='A') come straight from the CSV.
    #   Not-in-APM rows: no APN, blank PR/PO, flagged "Not available in APM".
    # =========================================================================
    oh_num = pd.to_numeric(df['site_oh_qty'], errors='coerce')
    df['_oh_num_k7'] = oh_num
    not_in_apm_mask = df['mapping_status'] == 'No APN found'
    # Group-level stock coverage (same definition as KPI 1): a (product, site,
    # mpn, catalog_reference) group is "covered" if ANY of its APNs has OH > 0.
    # When covered, the whole MPN/CRN is excluded from KPI 7 — even its zero-OH
    # sibling APNs — because the part is usable via the stocked APN.
    grp_cols = ['product', 'site', 'mpn', 'catalog_reference']
    covered = (df.groupby(grp_cols)['_oh_num_k7']
                 .transform(lambda x: (x.fillna(0) > 0).any()))
    # Include a row if: its group is NOT covered (all APNs 0/NULL OH) OR it's not in APM.
    zero_or_null_oh_mask = ~covered
    df7 = df[(zero_or_null_oh_mask) | not_in_apm_mask].copy()

    if not df7.empty:
        df7['APM Status'] = df7['mapping_status'].apply(
            lambda x: 'Not available in APM' if str(x).strip() == 'No APN found' else 'In APM')
        is_nia = df7['APM Status'] == 'Not available in APM'

        # PR/PO only meaningful for in-APM rows; blank them for not-in-APM.
        def blank_if_nia(col):
            if col not in df7.columns:
                return ''
            return df7[col].where(~is_nia, '')

        # Format numeric-looking IDs/qtys as clean integers (the CSV reads e.g.
        # req_number as a float -> "1914666.0"). Leave non-numeric values (e.g.
        # a PO number like "2D-22360117") and blanks untouched.
        def as_int_str(series):
            def fmt(v):
                if v is None or (isinstance(v, float) and pd.isna(v)):
                    return ''
                s = str(v).strip()
                if s in ('', 'nan'):
                    return ''
                try:
                    f = float(s)
                    if f == int(f):
                        return str(int(f))
                    return s
                except (ValueError, TypeError):
                    return s
            return series.apply(fmt)

        df7['has_pr_disp'] = pd.to_numeric(df7.get('has_active_pr'), errors='coerce').fillna(0)
        df7['Has PR'] = df7['has_pr_disp'].apply(lambda v: 'Yes' if v == 1 else 'No')
        df7.loc[is_nia, 'Has PR'] = ''
        df7['Has PO'] = df7.get('po_number')
        df7['Has PO'] = df7['Has PO'].apply(lambda v: 'Yes' if (pd.notna(v) and str(v).strip() not in ('', 'nan')) else 'No')
        df7.loc[is_nia, 'Has PO'] = ''

        # Action priority from PR/PO combo (in-APM rows only):
        #   P1 = no PO & no PR (nothing in motion — act first)
        #   P2 = PO (not '101') & no PR & PO date > 30 days ago (outdated PO)
        #   P3 = PO # starts with '101' & no PR (APM-only PO — needs data validation)
        #   P4 = no PO & PR (pending PO)
        #   P5 = PO (not '101') & no PR & PO date within last 30 days (recent PO — no action)
        #   P6 = PO & PR (no action required)
        # Not-in-APM rows get no priority (separate category).
        _today = pd.Timestamp(date.today())

        def action_priority(hp_pr, hp_po, po_num, po_dt):
            if hp_pr == 'No' and hp_po == 'No':
                return 'P1: No PO & No PR'
            if hp_pr == 'No' and hp_po == 'Yes':
                if str(po_num).strip().startswith('101'):
                    return 'P3: APM-only PO - needs data validation'
                # Split by PO age. Missing/unparseable date -> treat as outdated.
                d = pd.to_datetime(po_dt, errors='coerce')
                if pd.notna(d) and (_today - d).days <= 30:
                    return 'P5: Recent PO, No PR - no action required'
                return 'P2: Outdated PO, No PR'
            if hp_pr == 'Yes' and hp_po == 'No':
                return 'P4: PR, No PO'
            if hp_pr == 'Yes' and hp_po == 'Yes':
                return 'P6: PO & PR - no action required'
            return ''
        _po_str = as_int_str(df7.get('po_number'))
        _po_date = df7.get('po_date')
        df7['Action Priority'] = [action_priority(pr, po, pn, pd_)
                                  for pr, po, pn, pd_ in zip(df7['Has PR'], df7['Has PO'], _po_str, _po_date)]
        df7.loc[is_nia, 'Action Priority'] = ''

        out7 = pd.DataFrame({
            '_product': df7['product'],
            'Site': df7['site'],
            'MPN': df7['mpn'],
            'CRN': df7['catalog_reference'],
            'APN': df7['r5_apn'].where(~is_nia, ''),
            'Description': df7['part_description'],
            'OH Qty': df7['site_oh_qty'],
            'APM Status': df7['APM Status'],
            'Action Priority': df7['Action Priority'],
            'Has PR': df7['Has PR'],
            'Req #': as_int_str(blank_if_nia('req_number')),
            'Req Qty': as_int_str(blank_if_nia('req_qty')),
            'Req Date': blank_if_nia('req_date'),
            'Days Open': as_int_str(blank_if_nia('days_open')),
            'Has PO': df7['Has PO'],
            'PO #': as_int_str(blank_if_nia('po_number')),
            'PO Qty Ordered': as_int_str(blank_if_nia('po_qty_ordered')),
            'PO Date': blank_if_nia('po_date'),
        })
        # One row per MPN/CRN + APN (+ site + product)
        out7 = out7.drop_duplicates(subset=['_product', 'Site', 'MPN', 'CRN', 'APN'])
        out7 = out7.fillna('')
        # Sort by priority (P1 first), not-in-APM last, then site/mpn
        _prio_rank = {'P1: No PO & No PR': 1,
                      'P2: Outdated PO, No PR': 2,
                      'P3: APM-only PO - needs data validation': 3,
                      'P4: PR, No PO': 4,
                      'P5: Recent PO, No PR - no action required': 5,
                      'P6: PO & PR - no action required': 6, '': 9}
        out7['_prank'] = out7['Action Priority'].map(_prio_rank).fillna(9)
        out7 = out7.sort_values(['_prank', '_product', 'Site', 'MPN', 'APN']).drop(columns=['_prank'])

        n_total = len(out7)
        n_nia = int((out7['APM Status'] == 'Not available in APM').sum())
        n_stockout = n_total - n_nia
        n_no_pr = int(((out7['APM Status'] == 'In APM') & (out7['Has PR'] == 'No')).sum())
    else:
        out7 = pd.DataFrame()
        n_total = n_nia = n_stockout = n_no_pr = 0

    tab7 = "<h2>KPI 2: Unavailable Parts &mdash; PR/PO Status</h2>"
    tab7 += f"""<div class="filter-bar">
  <label>Product: </label><select onchange="applyProductFilter()" id="tab7_product_filter">{product_opts}</select>
  <label>Site: </label><select onchange="filterTab7Detail()" id="tab7_site_filter">{site_opts}</select>
  <label>Action Priority: </label><select onchange="filterTab7Detail()" id="tab7_prio_filter"><option value="all">All</option><option value="P1">P1: No PO &amp; No PR</option><option value="P2">P2: Outdated PO, No PR</option><option value="P3">P3: APM-only PO - needs data validation</option><option value="P4">P4: PR, No PO</option><option value="P5">P5: Recent PO, No PR - no action required</option><option value="P6">P6: PO &amp; PR - no action required</option><option value="NIA">Not in APM</option></select>
  <label>Has PR: </label><select onchange="filterTab7Detail()" id="tab7_haspr_filter"><option value="all">All</option><option value="Yes">Yes</option><option value="No">No</option></select>
  <label>Has PO: </label><select onchange="filterTab7Detail()" id="tab7_haspo_filter"><option value="all">All</option><option value="Yes">Yes</option><option value="No">No</option></select>
  <label>MPN Search: </label><input type="text" id="tab7_mpn_search" onkeyup="filterTab7Detail()" placeholder="Type MPN..." style="padding:4px 8px">
</div>"""
    tab7 += '<p id="tab7_summary"></p>'
    tab7 += ('<div style="margin:10px 0;padding:10px 12px;background:#fff3cd;'
             'border-left:4px solid #ff9900;border-radius:4px;font-size:13px;">'
             '<b>P3 &mdash; APM-only PO (needs data validation):</b> These parts have an '
             'APM-only PO (number starting with 101, no Coupa PO) with a received quantity, '
             'yet never appear as available inventory in APM (r5stock). RME ISP needs to '
             'confirm what happened to these received parts.</div>')
    tab7 += '<button class="export-btn" onclick="exportTableCSV(\'tab7_detail\',\'kpi2_unavailable_parts_pr_po.csv\')">Export CSV</button>'
    tab7 += html_table(out7, table_id='tab7_detail', show_product=True)

    # =========================================================================
    # BUILD HTML
    # =========================================================================
    html = f"""<!DOCTYPE html>
<html>
<head>
<title>RSPL Flash Report - {today}</title>
<style>
  body {{ font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }}
  h1 {{ color: #232f3e; }}
  h2 {{ color: #ff9900; }}
  h3 {{ color: #333; margin-top: 20px; }}
  .tabs {{ display: flex; gap: 2px; margin-bottom: 0; flex-wrap: wrap; }}
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
  .filter-bar label {{ font-weight: bold; margin-right: 4px; }}
  /* KPI 2 (tab7): narrow the Description column (6th col) */
  #tab7_detail td:nth-child(6), #tab7_detail th:nth-child(6) {{
    max-width: 160px; white-space: normal; word-break: break-word; font-size: 11px;
  }}
  .export-btn {{ margin: 6px 0; padding: 5px 12px; background: #ff9900; color: #232f3e;
    border: none; border-radius: 4px; cursor: pointer; font-size: 12px; font-weight: bold; }}
  .export-btn:hover {{ background: #e88a00; }}
</style>
</head>
<body>
<h1>RSPL Daily Flash Report</h1>
<p class="date">Report Date: {today}</p>

<div class="tabs">
  <button class="active" onclick="openTab(event,'tab1')">KPI 1: Stock Detail</button>
  <button onclick="openTab(event,'tab7')">KPI 2: Unavailable Parts PR/PO</button>
  <button onclick="openTab(event,'tab2')">KPI 3: Below Min No PR %</button>
  <button onclick="openTab(event,'tab3')">KPI 4: Open PRs &gt; 1 wk</button>
  <button onclick="openTab(event,'tab4')">KPI 5: Receipt Rate</button>
  <button onclick="openTab(event,'tab5')">KPI 6: Open POs (WIP)</button>
  <button onclick="openTab(event,'tab6')">KPI 7: APN Heatmap</button>
</div>

<div id="tab1" class="tab-content active">{tab1}</div>
<div id="tab7" class="tab-content">{tab7}</div>
<div id="tab2" class="tab-content">{tab2}</div>
<div id="tab3" class="tab-content">{tab3}</div>
<div id="tab4" class="tab-content">{tab4}</div>
<div id="tab5" class="tab-content">{tab5}</div>
<div id="tab6" class="tab-content">{tab6}</div>

<script>
function openTab(evt, tabId) {{
  document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.tabs button').forEach(b => b.classList.remove('active'));
  document.getElementById(tabId).classList.add('active');
  evt.target.classList.add('active');
}}

// Global product filter - applies to active tab
function applyProductFilter() {{
  // Find active tab
  var activeTab = document.querySelector('.tab-content.active');
  if (!activeTab) return;
  var tabId = activeTab.id;

  var productFilter = document.getElementById(tabId + '_product_filter');
  if (!productFilter) return;
  var prodVal = productFilter.value;

  // Filter rows in tables that have data-product attribute
  activeTab.querySelectorAll('table').forEach(function(table) {{
    var rows = table.querySelectorAll('tr[data-product]');
    rows.forEach(function(row) {{
      var rowProd = row.getAttribute('data-product');
      var showProd = (prodVal === 'all' || rowProd === prodVal);
      row.style.display = showProd ? '' : 'none';
    }});
  }});

  // Re-apply site/mpn filters on top of product filter
  if (tabId === 'tab1') filterDetailTable();
  else if (tabId === 'tab2') {{ filterSiteTable('tab2_site'); filterTab2Detail(); }}
  else if (tabId === 'tab3') {{ filterSiteTable('tab3_site'); filterTab3Detail(); }}
  else if (tabId === 'tab4') {{ filterSiteTable('tab4_site'); filterTab4Detail(); }}
  else if (tabId === 'tab5') {{ filterSiteTable('tab5_site'); filterTab5Detail(); }}
  else if (tabId === 'tab6') filterHeatmap();
  else if (tabId === 'tab7') filterTab7Detail();
}}

function getProductVal(tabPrefix) {{
  var el = document.getElementById(tabPrefix + '_product_filter');
  return el ? el.value : 'all';
}}

function filterSiteTable(tableId) {{
  var tabPrefix = tableId.split('_')[0];
  var filterEl = document.getElementById(tabPrefix + '_site_filter');
  if (!filterEl) return;
  var siteVal = filterEl.value;
  var prodVal = getProductVal(tabPrefix);
  var table = document.getElementById(tableId);
  if (!table) return;
  var rows = table.querySelectorAll('tr[data-product]');
  rows.forEach(function(row) {{
    var rowProd = row.getAttribute('data-product');
    var cells = row.querySelectorAll('td');
    if (cells.length < 2) return;
    // Product is col 0, Site is col 1
    var rowSite = cells[1].textContent;
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    row.style.display = (showProd && showSite) ? '' : 'none';
  }});
}}

function filterDetailTable() {{
  var siteVal = document.getElementById('tab1_site_filter').value;
  var mpnVal = document.getElementById('tab1_mpn_search').value.toLowerCase();
  var prodVal = getProductVal('tab1');
  var redOnlyEl = document.getElementById('tab1_red_only');
  var redOnly = redOnlyEl && redOnlyEl.checked;
  var table = document.getElementById('tab1_detail');
  var rows = table.querySelectorAll('tr[data-product]');
  rows.forEach(function(row) {{
    var rowProd = row.getAttribute('data-product');
    var isRed = row.getAttribute('data-red') === '1';
    var cells = row.querySelectorAll('td');
    if (cells.length < 3) return;
    var rowSite = cells[1].textContent;
    var rowMpn = cells[2].textContent.toLowerCase();
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showMpn = (mpnVal === '' || rowMpn.indexOf(mpnVal) >= 0);
    var showRed = (!redOnly || isRed);
    row.style.display = (showProd && showSite && showMpn && showRed) ? '' : 'none';
  }});
  // Filter network summary
  var netTable = document.getElementById('tab1_network');
  if (netTable) {{
    netTable.querySelectorAll('tr[data-product]').forEach(function(row) {{
      var rp = row.getAttribute('data-product');
      var sp = (prodVal === 'all' || rp === prodVal || rp === 'All');
      row.style.display = sp ? '' : 'none';
    }});
  }}
  // Filter site summary
  var sumTable = document.getElementById('tab1_summary');
  if (sumTable) {{
    sumTable.querySelectorAll('tr[data-product]').forEach(function(row) {{
      var rp = row.getAttribute('data-product');
      var cells = row.querySelectorAll('td');
      // Product is col 0, Site is col 1
      var rs = cells.length > 1 ? cells[1].textContent : '';
      var sp = (prodVal === 'all' || rp === prodVal);
      var ss = (siteVal === 'all' || rs === siteVal);
      row.style.display = (sp && ss) ? '' : 'none';
    }});
  }}
}}

function filterTab2Detail() {{
  var siteVal = document.getElementById('tab2_site_filter').value;
  var mpnVal = document.getElementById('tab2_mpn_search').value.toLowerCase();
  var prodVal = getProductVal('tab2');
  var table = document.getElementById('tab2_detail');
  if (!table) return;
  var rows = table.querySelectorAll('tr[data-product]');
  rows.forEach(function(row) {{
    var rowProd = row.getAttribute('data-product');
    var cells = row.querySelectorAll('td');
    if (cells.length < 3) return;
    var rowSite = cells[1].textContent;
    var rowMpn = cells[2].textContent.toLowerCase();
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showMpn = (mpnVal === '' || rowMpn.indexOf(mpnVal) >= 0);
    row.style.display = (showProd && showSite && showMpn) ? '' : 'none';
  }});
}}

function filterTab3Detail() {{
  var siteVal = document.getElementById('tab3_site_filter').value;
  var mpnVal = document.getElementById('tab3_mpn_search').value.toLowerCase();
  var prodVal = getProductVal('tab3');
  var table = document.getElementById('tab3_detail');
  if (!table) return;
  var rows = table.querySelectorAll('tr[data-product]');
  rows.forEach(function(row) {{
    var rowProd = row.getAttribute('data-product');
    var cells = row.querySelectorAll('td');
    if (cells.length < 3) return;
    var rowSite = cells[1].textContent;
    var rowMpn = cells[2].textContent.toLowerCase();
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showMpn = (mpnVal === '' || rowMpn.indexOf(mpnVal) >= 0);
    row.style.display = (showProd && showSite && showMpn) ? '' : 'none';
  }});
}}

function filterTab4Detail() {{
  var siteVal = document.getElementById('tab4_site_filter').value;
  var mpnVal = document.getElementById('tab4_mpn_search').value.toLowerCase();
  var prodVal = getProductVal('tab4');
  var table = document.getElementById('tab4_detail');
  if (!table) return;
  var rows = table.querySelectorAll('tr[data-product]');
  rows.forEach(function(row) {{
    var rowProd = row.getAttribute('data-product');
    var cells = row.querySelectorAll('td');
    if (cells.length < 3) return;
    var rowSite = cells[1].textContent;
    var rowMpn = cells[2].textContent.toLowerCase();
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showMpn = (mpnVal === '' || rowMpn.indexOf(mpnVal) >= 0);
    row.style.display = (showProd && showSite && showMpn) ? '' : 'none';
  }});
}}

function filterTab5Detail() {{
  var siteVal = document.getElementById('tab5_site_filter').value;
  var mpnVal = document.getElementById('tab5_mpn_search').value.toLowerCase();
  var prodVal = getProductVal('tab5');
  var table = document.getElementById('tab5_detail');
  if (!table) return;
  var rows = table.querySelectorAll('tr[data-product]');
  rows.forEach(function(row) {{
    var rowProd = row.getAttribute('data-product');
    var cells = row.querySelectorAll('td');
    if (cells.length < 3) return;
    var rowSite = cells[1].textContent;
    var rowMpn = cells[2].textContent.toLowerCase();
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showMpn = (mpnVal === '' || rowMpn.indexOf(mpnVal) >= 0);
    row.style.display = (showProd && showSite && showMpn) ? '' : 'none';
  }});
}}

function filterTab7Detail() {{
  var siteVal = document.getElementById('tab7_site_filter').value;
  var mpnVal = document.getElementById('tab7_mpn_search').value.toLowerCase();
  var prodVal = getProductVal('tab7');
  var hasPrEl = document.getElementById('tab7_haspr_filter');
  var hasPoEl = document.getElementById('tab7_haspo_filter');
  var prioEl = document.getElementById('tab7_prio_filter');
  var hasPrVal = hasPrEl ? hasPrEl.value : 'all';
  var hasPoVal = hasPoEl ? hasPoEl.value : 'all';
  var prioVal = prioEl ? prioEl.value : 'all';
  var table = document.getElementById('tab7_detail');
  if (!table) return;
  // Column indices: Site=1, MPN=2, CRN=3, APM Status=7, Has PR=9, Has PO=14.
  // Summary counts are DISTINCT MPN/CRN (a part may span multiple APN rows).
  var totalSet = {{}}, niaSet = {{}}, stockoutSet = {{}}, noPrSet = {{}};
  var rows = table.querySelectorAll('tr[data-product]');
  rows.forEach(function(row) {{
    var rowProd = row.getAttribute('data-product');
    var cells = row.querySelectorAll('td');
    if (cells.length < 15) return;
    var rowSite = cells[1].textContent;
    var rowMpn = cells[2].textContent.toLowerCase();
    var rowHasPr = cells[9].textContent.trim();
    var rowHasPo = cells[14].textContent.trim();
    var rowPrio = cells[8].textContent.trim();
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    var showSite = (siteVal === 'all' || rowSite === siteVal);
    var showMpn = (mpnVal === '' || rowMpn.indexOf(mpnVal) >= 0);
    var showPr = (hasPrVal === 'all' || rowHasPr === hasPrVal);
    var showPo = (hasPoVal === 'all' || rowHasPo === hasPoVal);
    var showPrio = (prioVal === 'all'
      || (prioVal === 'NIA' && rowPrio === '')
      || (prioVal !== 'NIA' && rowPrio.indexOf(prioVal) === 0));
    var show = showProd && showSite && showMpn && showPr && showPo && showPrio;
    row.style.display = show ? '' : 'none';
    if (show) {{
      // key on product+site+MPN+CRN so distinct parts are counted once
      var key = rowProd + '|' + rowSite + '|' + cells[2].textContent + '|' + cells[3].textContent;
      totalSet[key] = 1;
      var apmStatus = cells[7].textContent.trim();
      if (apmStatus === 'Not available in APM') {{ niaSet[key] = 1; }}
      else {{ stockoutSet[key] = 1; if (cells[9].textContent.trim() === 'No') {{ noPrSet[key] = 1; }} }}
    }}
  }});
  var total = Object.keys(totalSet).length;
  var nia = Object.keys(niaSet).length;
  var stockout = Object.keys(stockoutSet).length;
  var noPr = Object.keys(noPrSet).length;
  var el = document.getElementById('tab7_summary');
  if (el) {{
    el.innerHTML = 'MPN/CRN with 0/NULL on-hand or not in APM: <b>' + total + '</b> ' +
      '(stocked out in APM: ' + stockout + ', of which no active PR: ' + noPr + '; ' +
      'not available in APM: ' + nia + ')';
  }}
}}

function filterHeatmap() {{
  var siteVal = document.getElementById('tab6_site_filter').value;
  var mpnVal = document.getElementById('tab6_mpn_search').value.toLowerCase();
  var prodVal = getProductVal('tab6');
  var table = document.getElementById('heatmap_table');
  if (!table) return;

  // Filter rows by MPN and product
  var rows = table.querySelectorAll('tr[data-mpn]');
  for (var i = 0; i < rows.length; i++) {{
    var rowMpn = rows[i].getAttribute('data-mpn').toLowerCase();
    var rowProd = rows[i].getAttribute('data-product');
    var showMpn = (mpnVal === '' || rowMpn.indexOf(mpnVal) >= 0);
    var showProd = (prodVal === 'all' || rowProd === prodVal);
    rows[i].style.display = (showMpn && showProd) ? '' : 'none';
  }}

  // Filter columns by site AND by product (hide sites that don't have the selected product)
  var headerRow = table.querySelector('tr');
  var headers = headerRow.querySelectorAll('th.heatmap-site-col');
  var colIndices = [];
  for (var j = 0; j < headers.length; j++) {{
    var hSite = headers[j].getAttribute('data-site');
    var hProducts = headers[j].getAttribute('data-products') || '';
    var showSite = (siteVal === 'all' || hSite === siteVal);
    // Exact match within comma-separated list
    var prodList = hProducts.split(',');
    var showProdSite = (prodVal === 'all' || prodList.indexOf(prodVal) >= 0);
    var showCol = showSite && showProdSite;
    headers[j].style.display = showCol ? '' : 'none';
    colIndices.push({{idx: j + 2, show: showCol}});
  }}

  // Show/hide data cells in each row
  var allRows = table.querySelectorAll('tr');
  for (var r = 1; r < allRows.length; r++) {{
    var cells = allRows[r].querySelectorAll('td');
    for (var c = 0; c < colIndices.length; c++) {{
      if (colIndices[c].idx < cells.length) {{
        cells[colIndices[c].idx].style.display = colIndices[c].show ? '' : 'none';
      }}
    }}
  }}
}}
// Export a table's currently-visible rows to CSV (respects active filters).
function exportTableCSV(tableId, filename) {{
  var table = document.getElementById(tableId);
  if (!table) return;
  function esc(v) {{
    v = (v == null ? '' : String(v)).replace(/\\u00a0/g, ' ').trim();
    if (/[",\\n]/.test(v)) {{ v = '"' + v.replace(/"/g, '""') + '"'; }}
    return v;
  }}
  var lines = [];
  var headerCells = table.querySelectorAll('tr th');
  if (headerCells.length) {{
    lines.push(Array.prototype.map.call(headerCells, function(th) {{ return esc(th.textContent); }}).join(','));
  }}
  var rows = table.querySelectorAll('tr');
  rows.forEach(function(row) {{
    if (row.querySelectorAll('th').length) return;          // skip header row
    if (row.offsetParent === null || row.style.display === 'none') return;  // visible only
    var cells = row.querySelectorAll('td');
    if (!cells.length) return;
    lines.push(Array.prototype.map.call(cells, function(td) {{ return esc(td.textContent); }}).join(','));
  }});
  var blob = new Blob(['\\ufeff' + lines.join('\\n')], {{ type: 'text/csv;charset=utf-8;' }});
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url; a.download = filename || (tableId + '.csv');
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  URL.revokeObjectURL(url);
}}

// On page load, apply KPI5 default product filter (USP) and populate KPI7 summary
document.addEventListener('DOMContentLoaded', function() {{
  filterHeatmap();
  filterTab7Detail();
}});
</script>
</body>
</html>"""

    with open(OUTPUT_FILE, 'w') as f:
        f.write(html)
    print(f"Report generated: {OUTPUT_FILE}")


if __name__ == '__main__':
    generate_report()
