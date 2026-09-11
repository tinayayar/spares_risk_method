#!/usr/bin/env python3
"""
generate_flash_report_auto.py

End-to-end automation for the RSPL Flash Report.

What it does:
  1. Runs flash_report_all_queries.sql on Athena via boto3
  2. Waits for the query to finish
  3. Downloads the result CSV to flash_report_datasource.csv
  4. Runs generate_flash_report.py to build flash_report.html
  5. Uploads the HTML to S3 and prints a 7-day presigned URL

Optional:
  --refresh-mapping   Also refresh the default.rspl_apn_mapping table first
                      by running query_mapping_datasource.sql (wrapped as CTAS).
                      Use this when RSPL parts, sites, or products have changed.
  --skip-publish      Skip the S3 upload / presigned URL step.

Usage:
  # Simple refresh (mapping table already current):
  python3 generate_flash_report_auto.py

  # Full refresh (rebuild mapping table then run main query):
  python3 generate_flash_report_auto.py --refresh-mapping

Prereqs (EC2 deployment):
  - Runs on the flash-report-runner EC2 instance; AWS credentials come from the
    attached IAM instance role (no ada/Midway, no named profile).
  - The report is served via CloudFront (distribution ELG9AX6DKEU8D) fronting the
    private bucket, so the viewer URL is permanent. Publish uploads to S3 and
    invalidates the CloudFront cache.
  - Python packages: boto3, pandas (installed in /opt/flashreport/venv).
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import date
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

# ---------------------------------------------------------------------------
# Configuration — change here if the AWS setup changes
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

AWS_REGION            = "us-east-1"
ATHENA_DATABASE       = "default"                       # default database for queries
ATHENA_WORKGROUP      = "primary"
ATHENA_OUTPUT_S3      = "s3://tinayay-athena-results-use1/spares/"

MAPPING_TABLE         = "default.rspl_apn_mapping"      # table the main query reads
MAPPING_TABLE_S3      = "s3://tinayay-athena-results-use1/spares/rspl_apn_mapping/"

# Publish config — report is served via CloudFront (permanent URL), bucket is private.
PUBLISH_BUCKET        = "tinayay-flash-report-2026"
PUBLISH_KEY           = "flash_report.html"             # fixed key
CLOUDFRONT_DIST_ID    = "ELG9AX6DKEU8D"                 # distribution fronting the bucket via OAC
CLOUDFRONT_URL        = "https://d8et2kyudtix3.cloudfront.net/"  # permanent, non-expiring URL

# Slack — webhook URL is read from env var SLACK_WEBHOOK_URL (not stored in code).
# If unset, Slack posting is skipped.
SLACK_WEBHOOK_ENV     = "SLACK_WEBHOOK_URL"

MAIN_SQL_FILE         = os.path.join(SCRIPT_DIR, "flash_report_all_queries.sql")
MAPPING_SQL_FILE      = os.path.join(SCRIPT_DIR, "query_mapping_datasource.sql")
OUTPUT_CSV            = os.path.join(SCRIPT_DIR, "flash_report_datasource.csv")
HTML_GENERATOR        = os.path.join(SCRIPT_DIR, "generate_flash_report.py")

POLL_INTERVAL_SEC     = 5
QUERY_TIMEOUT_SEC     = 30 * 60   # 30 minutes


# ---------------------------------------------------------------------------
# Athena helpers
# ---------------------------------------------------------------------------
def make_clients():
    """Create boto3 clients. Uses whichever credentials are in the env / profile."""
    session = boto3.Session(region_name=AWS_REGION)
    return session.client("athena"), session.client("s3"), session


def start_query(athena, sql, database=ATHENA_DATABASE):
    """Submit a query to Athena and return its execution id."""
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": database},
        ResultConfiguration={"OutputLocation": ATHENA_OUTPUT_S3},
        WorkGroup=ATHENA_WORKGROUP,
    )
    return resp["QueryExecutionId"]


def wait_for_query(athena, execution_id, label):
    """Poll until the query finishes. Return the final QueryExecution dict.

    Raises on FAILED / CANCELLED / timeout.
    """
    start = time.time()
    last_state = None
    while True:
        info = athena.get_query_execution(QueryExecutionId=execution_id)["QueryExecution"]
        state = info["Status"]["State"]
        if state != last_state:
            elapsed = int(time.time() - start)
            print(f"  [{label}] {state} ({elapsed}s)")
            last_state = state

        if state in ("SUCCEEDED",):
            return info
        if state in ("FAILED", "CANCELLED"):
            reason = info["Status"].get("StateChangeReason", "no reason returned")
            raise RuntimeError(f"Athena query {label} {state}: {reason}")

        if time.time() - start > QUERY_TIMEOUT_SEC:
            raise TimeoutError(f"Athena query {label} exceeded {QUERY_TIMEOUT_SEC}s timeout")

        time.sleep(POLL_INTERVAL_SEC)


def download_result_csv(s3, execution_info, local_path):
    """Download the CSV that Athena wrote for a SELECT query to local_path."""
    output_uri = execution_info["ResultConfiguration"]["OutputLocation"]
    parsed = urlparse(output_uri)
    bucket = parsed.netloc
    key = parsed.path.lstrip("/")
    print(f"  Downloading s3://{bucket}/{key} -> {local_path}")
    s3.download_file(bucket, key, local_path)


# ---------------------------------------------------------------------------
# Mapping table refresh (optional)
# ---------------------------------------------------------------------------
def refresh_mapping_table(athena, s3):
    """Rebuild default.rspl_apn_mapping from query_mapping_datasource.sql.

    Strategy:
      1. DROP TABLE IF EXISTS default.rspl_apn_mapping
      2. Delete existing S3 data at MAPPING_TABLE_S3 (Athena won't overwrite)
      3. CREATE TABLE ... AS <mapping SELECT>  (CTAS)
    """
    print("Refreshing mapping table...")

    with open(MAPPING_SQL_FILE, "r") as fh:
        mapping_select = fh.read()

    # 1. Drop the existing table (definition only, not the S3 data)
    print("  Dropping existing table...")
    drop_id = start_query(athena, f"DROP TABLE IF EXISTS {MAPPING_TABLE}")
    wait_for_query(athena, drop_id, "drop-mapping")

    # 2. Clear old S3 data at the CTAS location
    parsed = urlparse(MAPPING_TABLE_S3)
    bucket = parsed.netloc
    prefix = parsed.path.lstrip("/")
    print(f"  Clearing s3://{bucket}/{prefix} ...")
    paginator = s3.get_paginator("list_objects_v2")
    to_delete = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            to_delete.append({"Key": obj["Key"]})
            if len(to_delete) == 1000:
                s3.delete_objects(Bucket=bucket, Delete={"Objects": to_delete})
                to_delete = []
    if to_delete:
        s3.delete_objects(Bucket=bucket, Delete={"Objects": to_delete})

    # 3. Recreate with CTAS (Parquet, snappy) at a fixed S3 location
    ctas_sql = (
        f"CREATE TABLE {MAPPING_TABLE}\n"
        f"WITH (\n"
        f"  format = 'PARQUET',\n"
        f"  parquet_compression = 'SNAPPY',\n"
        f"  external_location = '{MAPPING_TABLE_S3}'\n"
        f") AS\n"
        f"{mapping_select}"
    )
    print("  Creating table (CTAS)...")
    ctas_id = start_query(athena, ctas_sql)
    wait_for_query(athena, ctas_id, "ctas-mapping")
    print("  Mapping table refreshed.\n")


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------
def run_main_query(athena, s3):
    """Run flash_report_all_queries.sql and drop the CSV into OUTPUT_CSV."""
    print("Running flash_report_all_queries.sql...")
    with open(MAIN_SQL_FILE, "r") as fh:
        sql = fh.read()

    exec_id = start_query(athena, sql)
    info = wait_for_query(athena, exec_id, "main-query")

    scanned_mb = info.get("Statistics", {}).get("DataScannedInBytes", 0) / (1024 * 1024)
    print(f"  Data scanned: {scanned_mb:.1f} MB")

    download_result_csv(s3, info, OUTPUT_CSV)
    print(f"  CSV written to {OUTPUT_CSV}\n")


def generate_html():
    """Invoke the existing generate_flash_report.py to build flash_report.html."""
    print("Generating HTML report...")
    result = subprocess.run(
        [sys.executable, HTML_GENERATOR],
        cwd=SCRIPT_DIR,
        capture_output=True,
        text=True,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        raise RuntimeError(f"generate_flash_report.py exited with code {result.returncode}")
    print("Done.\n")


def check_credentials(session):
    """Print who we're authenticating as. Fail fast on bad creds."""
    sts = session.client("sts")
    try:
        ident = sts.get_caller_identity()
    except ClientError as e:
        print("AWS credentials are not usable:", e, file=sys.stderr)
        print(
            "\nRefresh credentials with:\n"
            "  ada credentials update --account 727615359903 "
            "--provider conduit --role AthenaFullAccess-alpha --once",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"AWS account: {ident['Account']}  role: {ident['Arn'].split('/')[-2]}\n")


def publish_report():
    """Upload flash_report.html to S3 and invalidate CloudFront.

    The report is served through a CloudFront distribution (OAC) fronting the
    private bucket, so the viewer URL is permanent and never expires. We upload
    with the ambient credentials (EC2 instance role) — no presigning, no signer
    IAM user — then invalidate the cached object so viewers see the fresh copy.
    """
    html_path = os.path.join(SCRIPT_DIR, "flash_report.html")
    if not os.path.exists(html_path):
        raise FileNotFoundError(f"HTML not found at {html_path} — did generate_html() run?")

    print("Publishing report to S3...")

    session = boto3.Session(region_name=AWS_REGION)
    s3 = session.client("s3")

    # Upload — ContentType lets browsers open it directly instead of downloading
    s3.upload_file(
        Filename=html_path,
        Bucket=PUBLISH_BUCKET,
        Key=PUBLISH_KEY,
        ExtraArgs={"ContentType": "text/html; charset=utf-8"},
    )
    print(f"  Uploaded s3://{PUBLISH_BUCKET}/{PUBLISH_KEY}")

    # Invalidate the CloudFront cache so the new report is served immediately.
    cf = session.client("cloudfront")
    inv = cf.create_invalidation(
        DistributionId=CLOUDFRONT_DIST_ID,
        InvalidationBatch={
            "Paths": {"Quantity": 2, "Items": ["/flash_report.html", "/"]},
            "CallerReference": str(int(time.time())),
        },
    )
    print(f"  CloudFront invalidation {inv['Invalidation']['Id']} created ({CLOUDFRONT_DIST_ID})")

    url = CLOUDFRONT_URL
    print(f"  Permanent URL: {url}")

    # Drop the URL into a sibling file so other tools can find it easily
    url_file = os.path.join(SCRIPT_DIR, "flash_report_url.txt")
    with open(url_file, "w") as fh:
        fh.write(url + "\n")
    print(f"  URL saved to {url_file}\n")

    return url


def post_to_slack(url):
    """Post the daily report URL to Slack via an Incoming Webhook.

    Reads the webhook URL from env var SLACK_WEBHOOK_URL. Silently skips if unset.
    Never raises — Slack down should not fail the report pipeline.
    """
    webhook = os.environ.get(SLACK_WEBHOOK_ENV, "").strip()
    if not webhook:
        print("Slack: no webhook configured (set SLACK_WEBHOOK_URL to enable). Skipping.\n")
        return

    print("Posting to Slack...")
    today = date.today().strftime("%B %d, %Y")

    payload = {
        # Fallback text (used in notifications and older Slack clients)
        "text": f"RSPL Daily Flash Report - {today}: {url}",
        # Rich formatting via Block Kit
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": f":memo: RSPL Daily Flash Report — {today}"},
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"Latest report is ready.\n"
                        f"<{url}|*Open Report*>  _(link valid 7 days)_"
                    ),
                },
            },
        ],
    }

    try:
        req = urllib.request.Request(
            webhook,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            if resp.status != 200 or body.strip() != "ok":
                print(f"  Slack returned status={resp.status} body={body!r}")
                return
        print("  Message posted.\n")
    except Exception as e:
        # Don't let Slack failures kill the pipeline
        print(f"  Slack post failed (non-fatal): {e}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--refresh-mapping",
        action="store_true",
        help="Rebuild default.rspl_apn_mapping from query_mapping_datasource.sql before the main query.",
    )
    parser.add_argument(
        "--skip-html",
        action="store_true",
        help="Fetch the CSV but do not regenerate the HTML.",
    )
    parser.add_argument(
        "--skip-publish",
        action="store_true",
        help="Do not upload the HTML to S3 / generate a presigned URL.",
    )
    parser.add_argument(
        "--skip-slack",
        action="store_true",
        help="Do not post the URL to Slack even if SLACK_WEBHOOK_URL is set.",
    )
    args = parser.parse_args()

    athena, s3, session = make_clients()
    check_credentials(session)

    if args.refresh_mapping:
        refresh_mapping_table(athena, s3)

    run_main_query(athena, s3)

    if not args.skip_html:
        generate_html()

    url = None
    if not args.skip_publish and not args.skip_html:
        url = publish_report()

    if url and not args.skip_slack:
        post_to_slack(url)

    print(f"Local: {os.path.join(SCRIPT_DIR, 'flash_report.html')}")


if __name__ == "__main__":
    main()
