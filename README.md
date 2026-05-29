# zscaler-scripts

Standalone Zscaler automation scripts. Each project is self-contained and designed to run headlessly via cron, acme.sh hooks, or CI/CD pipelines.

## Projects

| Project | Description |
|---------|-------------|
| [`zpa-cert-rotation/`](zpa-cert-rotation/) | Rotates TLS certificates in ZPA via OneAPI — triggered by acme.sh on cert renewal |
| [`zpa-vpn-sync/`](zpa-vpn-sync/) | Syncs ZPA VPN for Legacy Apps connected users to Active Directory DNS as A records — runs as a Windows Scheduled Task |
