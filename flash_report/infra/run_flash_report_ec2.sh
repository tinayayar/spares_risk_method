#!/bin/bash
# Daily flash-report runner for the EC2 instance.
# No ada/Midway — credentials come from the attached IAM instance role.
# Invoked by cron at 05:00 America/Los_Angeles.
set -uo pipefail

APP_DIR="/opt/flashreport/app"
VENV_PY="/opt/flashreport/venv/bin/python"
LOG_DIR="/opt/flashreport/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/flash_report_$(date +%F).log"

{
  echo "==============================================================="
  echo "Flash Report Daily Run (EC2) — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "==============================================================="

  cd "$APP_DIR" || { echo "ERROR: cannot cd to $APP_DIR"; exit 1; }

  # Full pipeline: rebuild mapping table, run main query, regenerate HTML,
  # publish to S3 + invalidate CloudFront. Slack skipped (no webhook here).
  "$VENV_PY" generate_flash_report_auto.py --refresh-mapping --skip-slack
  rc=$?

  echo "exit code: $rc"
  echo "finished: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  exit $rc
} >> "$LOG" 2>&1
