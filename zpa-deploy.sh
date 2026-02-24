#!/bin/bash
set -e

# Load credentials
source /etc/zpa-cert-automation.conf

PYTHON_SCRIPT="/root/scripts/zpa-cert-upload.py"

echo "==================================="
echo "Deploying certificate for $DOMAIN to ZPA"
echo "Cert: $CERT_FULLCHAIN_PATH"
echo "Key: $CERT_KEY_PATH"
echo "==================================="

# Call the Python script
python3 "$PYTHON_SCRIPT" \
    "$CERT_FULLCHAIN_PATH" \
    "$CERT_KEY_PATH" \
    "$DOMAIN"

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo "✓ ZPA deployment successful for $DOMAIN"
else
    echo "✗ ZPA deployment failed for $DOMAIN with exit code $exit_code"
fi

exit $exit_code
