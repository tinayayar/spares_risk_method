#!/usr/bin/env python3
"""
Rebuild default.rspl_apn_mapping (CTAS) from query_mapping_datasource.sql, then
run flash_report_all_queries.sql and download the result to
flash_report_datasource_live.csv.

Mirrors generate_flash_report_auto.refresh_mapping_table so the local pull
matches the live pipeline. Run with refreshed AthenaFullAccess-alpha creds.
"""
import time
import boto3
from urllib.parse import urlparse

DB = "default"
OUT_S3 = "s3://tinayay-athena-results-use1/spares/"
MAPPING_TABLE = "default.rspl_apn_mapping"
MAPPING_TABLE_S3 = "s3://tinayay-athena-results-use1/spares/rspl_apn_mapping/"
MAPPING_SQL = "query_mapping_datasource.sql"
MAIN_SQL = "flash_report_all_queries.sql"
OUT_CSV = "flash_report_datasource_live.csv"

athena = boto3.client("athena", region_name="us-east-1")
s3 = boto3.client("s3", region_name="us-east-1")


def run(sql, label, timeout=600):
    qid = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": DB},
        ResultConfiguration={"OutputLocation": OUT_S3},
    )["QueryExecutionId"]
    print(f"[{label}] {qid}")
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        state = st["State"]
        if state == "SUCCEEDED":
            print(f"[{label}] SUCCEEDED ({int(time.time()-t0)}s)")
            return qid
        if state in ("FAILED", "CANCELLED"):
            raise RuntimeError(f"[{label}] {state}: {st.get('StateChangeReason')}")
        time.sleep(5)
    raise TimeoutError(f"[{label}] timeout")


def main():
    mapping_select = open(MAPPING_SQL).read().rstrip().rstrip(";")
    main_sql = open(MAIN_SQL).read().rstrip().rstrip(";")

    # 1. Drop existing table
    run(f"DROP TABLE IF EXISTS {MAPPING_TABLE}", "drop")

    # 2. Clear old S3 CTAS data
    p = urlparse(MAPPING_TABLE_S3)
    bucket, prefix = p.netloc, p.path.lstrip("/")
    paginator = s3.get_paginator("list_objects_v2")
    to_del = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            to_del.append({"Key": obj["Key"]})
    for i in range(0, len(to_del), 1000):
        s3.delete_objects(Bucket=bucket, Delete={"Objects": to_del[i:i+1000]})
    print(f"  cleared {len(to_del)} S3 objects")

    # 3. CTAS recreate
    ctas = (
        f"CREATE TABLE {MAPPING_TABLE}\n"
        f"WITH (\n  format = 'PARQUET',\n  parquet_compression = 'SNAPPY',\n"
        f"  external_location = '{MAPPING_TABLE_S3}'\n) AS\n{mapping_select}"
    )
    run(ctas, "ctas-mapping", timeout=900)

    # 4. Main query
    qid = run(main_sql, "main-query", timeout=900)

    # 5. Download CSV
    s3.download_file(bucket, f"spares/{qid}.csv", OUT_CSV)
    print(f"Saved {OUT_CSV}")


if __name__ == "__main__":
    main()
