# ZPA VPN DNS Sync

Keeps an Active Directory DNS zone in sync with users currently connected via Zscaler Private Access (ZPA) VPN Legacy Apps. On each run it retrieves the live connected-user list from ZPA via OneAPI and adds or updates A records in the target zone so that on-prem resources can resolve VPN clients by hostname. Records are never deleted — when a client disconnects or returns on-net, normal AD DNS registration overwrites the VPN IP naturally.

## Authors

Tom O'Leary, Mike Preissner

## Files

| File | Purpose |
|------|---------|
| `zpa-dns-sync-oneapi.ps1` | Core sync script. Authenticates to ZPA via OneAPI (OAuth2 client_credentials), fetches all connected VPN users with pagination, and adds or updates A records in the target AD DNS zone. A local state cache avoids redundant DNS operations for entries that haven't changed. |

## Requirements

- PowerShell 5.1 or later
- `DnsServer` module — included on Windows Server with the DNS role, or installable via RSAT on a domain member: `Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0`
- A service account with full CRUD delegation on the target DNS zone (not Domain Admin — standard DNS zone permissions are sufficient)
- ZPA OneAPI credentials with read access to `vpnConnectedUsers` (ZPA > Administration > API Key Management)

## Setup

1. Open `zpa-dns-sync-oneapi.ps1` and fill in the **USER CONFIGURATION** section at the top
2. Create the scheduled task (run once as a local admin — the task itself runs as the service account):

```powershell
$action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                 -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\zpa-dns-sync-oneapi.ps1"
$trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
$principal = New-ScheduledTaskPrincipal -UserId "CORP\svc-zpavpndns" -LogonType Password -RunLevel Limited
Register-ScheduledTask -TaskName "ZPA VPN DNS Sync" -Action $action -Trigger $trigger -Principal $principal
```

3. Run the task manually once to verify connectivity and inspect the log before relying on the schedule

## Configuration

All settings live in the `USER CONFIGURATION` block at the top of the script — no external config file is required.

| Variable | Description |
|----------|-------------|
| `$ClientId` | ZPA OneAPI client ID |
| `$ClientSecret` | ZPA OneAPI client secret |
| `$VanityDomain` | The subdomain part of your ZIdentity URL (e.g. `acme` for `acme.zslogin.net`) |
| `$CustomerId` | ZPA Customer ID (visible in the Admin Portal URL) |
| `$DnsZone` | AD DNS zone to manage A records in (e.g. `vpn.corp.local`) |
| `$DnsServer` | Hostname or IP of the AD DNS server to update |
| `$RecordTtl` | TTL in seconds for records written by this script (default: `300`) |
| `$LogFile` | Path for the activity log (default: `C:\Logs\zpa-vpn-sync\zpa-vpn-sync.log`) |
| `$StateFile` | Path for the hostname→IP state cache (default: `C:\ProgramData\zpa-vpn-sync\managed-hosts.json`) |
| `$PageSize` | ZPA API page size, 1–500 (default: `500`) |

## How it works

1. Authenticates to `https://<VanityDomain>.zslogin.net/oauth2/v1/token` using the OAuth2 `client_credentials` flow
2. Pages through `GET /zpa/mgmtconfig/v1/admin/customers/:customerId/vpnConnectedUsers` until all connected users are retrieved
3. Compares the result against the state cache from the previous run — entries whose IP hasn't changed are skipped without touching DNS
4. For new or changed entries, queries the target zone and adds or updates A records accordingly
5. Writes an updated state cache containing only currently-connected users (disconnected users are pruned from the cache, not from DNS)

## Logs

Activity is written to `$LogFile` and echoed to stdout. Each entry is timestamped and tagged `[INFO]`, `[WARN]`, or `[ERROR]`. The state cache at `$StateFile` is a JSON object mapping hostname labels to their last-synced IP.
