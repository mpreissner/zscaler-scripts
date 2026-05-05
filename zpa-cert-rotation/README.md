# ZPA Certificate Rotation

Automatically rotates TLS certificates in Zscaler Private Access (ZPA) when certs renew via acme.sh. Uploads the new cert via OneAPI and updates all Browser Access app segments, PRA Portals, and User Portals that reference the old cert for the given domain. Old certs are cleaned up after rotation.

## Files

| File | Purpose |
|------|---------|
| `zpa-cert-upload.py` | Core rotation script. Uploads cert, finds all matching ZPA resources, swaps cert IDs, deletes old cert. |
| `zpa-deploy.sh` | Thin shell wrapper for use as an acme.sh `--reloadcmd` or `--deploy-hook`. Resolves paths/domain from acme.sh env vars, then calls the Python script. |
| `zpa-cert-automation.conf.example` | Config file template for server deployments. Copy, fill in, `chmod 600`. |

## Requirements

```bash
pip install requests
```

## Setup

1. Copy `zpa-cert-automation.conf.example` to a secure location as `zpa-cert-automation.conf` (e.g. `/etc/zpa-cert-automation.conf`)
2. `chmod 600` the conf file and fill in your credentials
3. Edit `zpa-deploy.sh` to point `PYTHON_SCRIPT` at the deployed location of `zpa-cert-upload.py`
4. Test with a manual invocation before wiring up acme.sh

## Environment Variables

```bash
ZIDENTITY_BASE_URL=https://<vanity-url>.zslogin.net
ONEAPI_BASE_URL=https://api.zsapi.net         # default if omitted
ZPA_CLIENT_ID=your-client-id
ZPA_CLIENT_SECRET=your-client-secret
ZPA_CUSTOMER_ID=your-customer-id
```

Set these in the conf file or export them directly. The conf file is `source`d by `zpa-deploy.sh` at `/etc/zpa-cert-automation.conf`.

## Usage

**As an acme.sh reloadcmd (recommended):**
```bash
acme.sh --install-cert -d '*.example.com' \
  --reloadcmd '/usr/local/bin/zpa-deploy.sh'
```

**As an acme.sh deploy-hook:**
```bash
acme.sh --deploy -d '*.example.com' --deploy-hook /usr/local/bin/zpa-deploy.sh
```

**Manual invocation:**
```bash
python3 zpa-cert-upload.py <cert_fullchain.pem> <key.pem> <domain>
```

## Logs

The Python script appends to `/var/log/zpa-cert-upload.log` (falls back to stdout-only if the path isn't writable).
