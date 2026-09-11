#!/bin/bash
# Helper: run a shell command on the flash-report EC2 instance via SSM and print output.
# Usage: infra/ssm_run.sh 'command string'   (or reads from stdin if no arg)
set -euo pipefail
INSTANCE="i-093628c467e23dc60"
REGION="us-east-1"

if [ $# -ge 1 ]; then
  CMD="$1"
else
  CMD="$(cat)"
fi

CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE" \
  --document-name "AWS-RunShellScript" \
  --comment "flash-report setup" \
  --parameters "commands=[$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$CMD")]" \
  --query 'Command.CommandId' --output text)

# Wait for completion
while true; do
  st=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")
  case "$st" in
    Success|Failed|Cancelled|TimedOut) break ;;
  esac
  sleep 4
done

echo "=== STATUS: $st ==="
echo "--- STDOUT ---"
aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE" --query 'StandardOutputContent' --output text
echo "--- STDERR ---"
aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE" --query 'StandardErrorContent' --output text
