# Flash Report — EC2 Runner Infrastructure

The daily flash report runs on an always-on EC2 instance in account
`727615359903` (us-east-1), scheduled by a systemd timer at 05:00 America/Los_Angeles.
It replaced the previous MacBook launchd job, which failed whenever the Midway/AEA
session was older than ~2 hours at run time.

## Live resources

| Resource | Value |
|---|---|
| EC2 instance | `i-093628c467e23dc60` (t3.micro, Amazon Linux 2023) |
| Instance role | `flash-report-runner` (+ instance profile of same name) |
| Working role assumed for queries | `AthenaFullAccess-alpha` |
| S3 report bucket (private) | `tinayay-flash-report-2026` (key `flash_report.html`) |
| Athena results bucket | `tinayay-athena-results-use1` |
| CloudFront distribution | `ELG9AX6DKEU8D` (OAC `EJRLYZRY7HKTT`) |
| **Permanent report URL** | https://d8et2kyudtix3.cloudfront.net/ |
| Security group | `sg-01dc07f57ca5a5653` (no inbound; egress all) |
| Access | SSM Session Manager only (no SSH) |

## How it works

1. `flash-report.timer` fires `flash-report.service` at 05:00 Pacific.
2. The service runs `/opt/flashreport/run_flash_report_ec2.sh`.
3. That runs `generate_flash_report_auto.py --refresh-mapping --skip-slack` under
   `/opt/flashreport/venv/bin/python`.
4. Credentials: `/root/.aws/config` sets the `[default]` profile to assume
   `AthenaFullAccess-alpha` via `credential_source = Ec2InstanceMetadata`. That role
   has the cross-account Lake Formation access the `andes` federated tables require.
5. Publish uploads `flash_report.html` to S3 and invalidates the CloudFront cache.
   The bucket stays private; CloudFront reads it via OAC.

## Files in this directory

| File | Purpose |
|---|---|
| `flash-report-runner-policy.json` | Managed policy `FlashReportRunnerPolicy` (Athena/Glue/S3/KMS/Logs/CloudFront/LakeFormation + sts:AssumeRole on the working role) |
| `ec2-trust-policy.json` | Trust policy for the `flash-report-runner` role (EC2 service) |
| `athena-role-trust-updated.json` | Updated trust policy of `AthenaFullAccess-alpha` (adds `flash-report-runner` to allowed principals) |
| `cf-invalidation-inline.json` | Inline policy added to `AthenaFullAccess-alpha` for CloudFront invalidation |
| `cloudfront-dist-config.json` | CloudFront distribution config (OAC + private S3 origin) |
| `bucket-policy-oac.json` | S3 bucket policy allowing CloudFront (scoped by SourceArn) |
| `aws_config` | Deployed to `/root/.aws/config` on the instance (assume-role default profile) |
| `run_flash_report_ec2.sh` | Cron/timer wrapper (no ada/Midway) — deployed to `/opt/flashreport/` |
| `flash-report.service` / `flash-report.timer` | systemd units — deployed to `/etc/systemd/system/` |
| `ssm_run.sh` | Helper to run a shell command on the instance via SSM |
| `probe.py` | Diagnostic: assume the working role and test a federated read |

## Operational notes

- **Instance reboot/replacement:** `/etc/resolv.conf` was pointed at public DNS
  (1.1.1.1 / 8.8.8.8) and made immutable, because the VPC resolver (172.31.0.2) was
  unreliable from this instance. This is applied to the running instance only — a
  rebuilt instance must re-apply it. Do NOT `pip install` into the system python on
  AL2023 (it breaks the bundled awscli-2); use `/opt/flashreport/venv`.
- **Check the last run:** `sudo cat /opt/flashreport/logs/flash_report_<date>.log`
  (via SSM). `systemctl list-timers flash-report.timer` shows the next run.
- **Run manually:** `sudo systemctl start flash-report.service` (oneshot; ~4 min).
- **Cost:** t3.micro on 24/7 ≈ $7.50/mo.
