#!/usr/bin/env bash
# Retry ARM instance creation until capacity is available.
# Sends ntfy notification on success.
# Usage: ./retry-arm.sh [interval_seconds]
#
# Run in background: nohup ./retry-arm.sh 300 &

set -euo pipefail

INTERVAL="${1:-300}"  # Default: 5 minutes
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NTFY_TOPIC="${MJOLNIR_NTFY_TOPIC:-mjolnir-harness}"
MAX_ATTEMPTS=500

cd "$SCRIPT_DIR"

echo "Retrying ARM instance every ${INTERVAL}s (max ${MAX_ATTEMPTS} attempts)"
echo "Notifications: https://ntfy.sh/${NTFY_TOPIC}"
echo ""

attempt=0
while [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; do
    attempt=$((attempt + 1))
    echo "[$(date '+%H:%M:%S')] Attempt ${attempt}/${MAX_ATTEMPTS}..."

    if terraform apply -auto-approve 2>&1 | tee /tmp/mjolnir-terraform-last.log | grep -q "Apply complete"; then
        echo ""
        echo "SUCCESS! ARM instance created on attempt ${attempt}!"
        terraform output

        # Send notification
        curl -s -d "Mjolnir ARM instance created! $(terraform output -raw instance_public_ip)" \
            -H "Title: Mjolnir VM Ready" \
            -H "Priority: urgent" \
            -H "Tags: white_check_mark,hammer" \
            "https://ntfy.sh/${NTFY_TOPIC}" || true

        exit 0
    fi

    echo "  Out of capacity. Waiting ${INTERVAL}s..."
    sleep "$INTERVAL"
done

echo "Failed after ${MAX_ATTEMPTS} attempts."
curl -s -d "ARM instance retry exhausted after ${MAX_ATTEMPTS} attempts" \
    -H "Title: Mjolnir VM Failed" \
    -H "Priority: high" \
    -H "Tags: x" \
    "https://ntfy.sh/${NTFY_TOPIC}" || true
exit 1
