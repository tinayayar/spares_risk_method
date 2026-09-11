import boto3, time

# Assume the working AthenaFullAccess-alpha role (which has the cross-account
# LF access the andes federated tables need), then run a probe query.
base = boto3.client("sts", region_name="us-east-1")
print("base caller:", base.get_caller_identity()["Arn"])
c = base.assume_role(
    RoleArn="arn:aws:iam::727615359903:role/AthenaFullAccess-alpha",
    RoleSessionName="flash-report-probe",
)["Credentials"]
sess = boto3.Session(
    aws_access_key_id=c["AccessKeyId"],
    aws_secret_access_key=c["SecretAccessKey"],
    aws_session_token=c["SessionToken"],
    region_name="us-east-1",
)
print("assumed caller:", sess.client("sts").get_caller_identity()["Arn"])
ath = sess.client("athena")


def run(sql, db="default"):
    q = ath.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": db},
        ResultConfiguration={"OutputLocation": "s3://tinayay-athena-results-use1/spares/_probe/"},
        WorkGroup="primary",
    )["QueryExecutionId"]
    while True:
        i = ath.get_query_execution(QueryExecutionId=q)["QueryExecution"]["Status"]
        if i["State"] not in ("QUEUED", "RUNNING"):
            break
        time.sleep(3)
    return i["State"], i.get("StateChangeReason", "")[:180]


print("SELECT :", run('SELECT sto_part FROM "andes"."rme-gdl.r5stock_apm_na" LIMIT 3'))
