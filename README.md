# zscaler-scripts

Standalone Zscaler OneAPI automation scripts. Each script is self-contained and
designed to run headlessly via cron, acme.sh deploy hooks, or CI/CD pipelines.

## Scripts

### `zpa-cert-upload.py` — ZPA Certificate Rotation

Uploads a new certificate to ZPA and updates all Browser Access applications and
PRA portals that reference the old certificate for the given domain.

Designed to be called as an [acme.sh](https://github.com/acmesh-official/acme.sh)
`--deploy-hook`, but also supports manual invocation.

**Usage (acme.sh hook):**
```bash
acme.sh --deploy -d '*.example.com' --deploy-hook /path/to/zpa-deploy.sh
```

**Usage (manual):**
```bash
python3 zpa-cert-upload.py <cert.pem> <key.pem> <domain>
```

**Required environment variables:**
```bash
ZIDENTITY_BASE_URL=https://acme.zslogin.net
ZSCALER_CLIENT_ID=your-client-id
ZSCALER_CLIENT_SECRET=your-client-secret
ZPA_CUSTOMER_ID=your-customer-id
```

### `zpa-deploy.sh` — acme.sh Deploy Hook

Thin shell wrapper that calls `zpa-cert-upload.py` from an acme.sh deploy hook.
Edit the script path inside before use.

### `zpa-cert-automation.conf.example` — Config File Template

Example configuration file for server deployments where environment variables
aren't convenient. Copy to `zpa-cert-automation.conf`, fill in your values, and
`chmod 600` it. See the file for field descriptions.

## Requirements

```bash
pip install requests
```

## Setup

1. Copy `zpa-cert-automation.conf.example` to a secure location as `zpa-cert-automation.conf` (e.g. `/etc/zscaler/`)
2. `chmod 600` the conf file
3. Set the environment variables or populate the conf file
4. Test with a manual invocation before wiring up acme.sh
