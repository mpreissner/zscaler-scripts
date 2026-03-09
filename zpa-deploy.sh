#!/bin/bash
set -e

# Load credentials
source /etc/zpa-cert-automation.conf

PYTHON_SCRIPT="/root/scripts/zpa-cert-upload.py"

# Resolve cert paths and domain across acme.sh invocation contexts:
#   --reloadcmd:    provides CERT_FULLCHAIN_PATH, CERT_KEY_PATH, Le_Domain
#   --deploy-hook:  provides CERT_FULLCHAIN, CERT_KEY, CERT_DOMAIN
FULLCHAIN="${CERT_FULLCHAIN_PATH:-$CERT_FULLCHAIN}"
KEY="${CERT_KEY_PATH:-$CERT_KEY}"
DOMAIN="${Le_Domain:-${CERT_DOMAIN:-$(basename "$(dirname "$FULLCHAIN")")}}"

if [ -z "$FULLCHAIN" ] || [ -z "$KEY" ] || [ -z "$DOMAIN" ]; then
    echo "ERROR: Could not resolve cert paths or domain from acme.sh environment."
    echo "  CERT_FULLCHAIN_PATH=${CERT_FULLCHAIN_PATH:-}"
    echo "  CERT_FULLCHAIN=${CERT_FULLCHAIN:-}"
    echo "  CERT_KEY_PATH=${CERT_KEY_PATH:-}"
    echo "  CERT_KEY=${CERT_KEY:-}"
    echo "  Le_Domain=${Le_Domain:-}"
    echo "  CERT_DOMAIN=${CERT_DOMAIN:-}"
    exit 1
fi

echo "==================================="
echo "Deploying certificate for $DOMAIN to ZPA"
echo "Cert: $FULLCHAIN"
echo "Key: $KEY"
echo "==================================="

# Call the Python script
python3 "$PYTHON_SCRIPT" \
    "$FULLCHAIN" \
    "$KEY" \
    "$DOMAIN"

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo "✓ ZPA deployment successful for $DOMAIN"
else
    echo "✗ ZPA deployment failed for $DOMAIN with exit code $exit_code"
fi

exit $exit_code
