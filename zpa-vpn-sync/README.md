# ZPA VPN DNS Sync

Keeps an Active Directory DNS zone in sync with users currently connected via Zscaler Private Access (ZPA) VPN Legacy Apps. On each run it retrieves the live connected-user list from ZPA via OneAPI and adds or updates A records in the target zone so that on-prem resources can resolve VPN clients by hostname. Optionally (`SyncDeletes`) it also removes records once a host drops off the connected-user list.

## Authors

Tom O'Leary, Mike Preissner

## Files

| File | Purpose |
|------|---------|
| `zpa-dns-sync-oneapi.ps1` | Core sync script. Authenticates to ZPA via OneAPI (OAuth2 client_credentials), fetches all connected VPN users with pagination, and adds or updates A records in the target AD DNS zone. A local state cache avoids redundant DNS operations for entries that haven't changed. |
| `zpa-dns-sync.config.json.example` | Template for the optional external config file — copy to `zpa-dns-sync.config.json` alongside the script and fill in your values. |
| `ZVPN-ConProf.ps1` | Powershell script to reclassify the "Zscaler Tunnel" adapter as a Private network interface for less restrictive host firewall. |
| `ZVPN-SchedTaskConfig.txt` | Instructions for deploying a Scheduled Task via Group Policy Objects to run ZVPN-ConProf.ps1 on detection of Zscaler Tunnel Up in Windows Event Log. |

## Requirements

- PowerShell 5.1 or later
- `DnsServer` module — included on Windows Server with the DNS role, or installable via RSAT on a domain member: `Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0` for Desktops and `Install-WindowsFeature -Name RSAT-DNS-Server` on Server platforms
- A service account with full CRUD delegation on the target DNS zone (not Domain Admin — standard DNS zone permissions are sufficient)
- OneAPI credentials with read access ZPA API resources

## Setup - DNS Sync

1. Copy `zpa-dns-sync.config.json.example` to `zpa-dns-sync.config.json` in the same directory as the script and fill in your values (see [Configuration](#configuration) below). Alternatively, edit the **USER CONFIGURATION** block directly at the top of the script.
2. Create the scheduled task (run once as a local admin — the task itself runs as the service account):

```powershell
$action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                 -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\zpa-dns-sync-oneapi.ps1"
$trigger   = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
$principal = New-ScheduledTaskPrincipal -UserId "CORP\svc-zpavpndns" -LogonType Password -RunLevel Limited
Register-ScheduledTask -TaskName "ZPA VPN DNS Sync" -Action $action -Trigger $trigger -Principal $principal
```

3. Run the task manually once to verify connectivity and inspect the log before relying on the schedule:

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\zpa-dns-sync-oneapi.ps1"
```

## Configuration

Settings can be provided two ways — the config file takes precedence over the in-script defaults:

**Recommended: external config file** — copy `zpa-dns-sync.config.json.example` to `zpa-dns-sync.config.json` alongside the script, and edit to include your values. You won't need to re-enter credentials each time the script is updated.

**Alternative: edit the script directly** — fill in the `USER CONFIGURATION` block at the top of `zpa-dns-sync-oneapi.ps1`. Use single quotes for `$ClientId` and `$ClientSecret` to prevent PowerShell from interpreting any `$` or backtick characters in the values.

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
| `$SyncDeletes` | Remove A records for hosts that are no longer VPN connected (default: `false` — see [Deleting records](#deleting-records)) |
| `$MaxDeletesPerRun` | Refuse to run if a single pass would delete more than this many records (default: `50`, `0` disables the cap) |

## How it works

1. Authenticates to `https://<VanityDomain>.zslogin.net/oauth2/v1/token` using the OAuth2 `client_credentials` flow
2. Pages through `GET /zpa/mgmtconfig/v1/admin/customers/:customerId/vpnConnectedUsers` until all connected users are retrieved
3. Compares the result against the state cache from the previous run — entries whose IP hasn't changed are skipped without touching DNS
4. For new or changed entries, queries the target zone and adds or updates A records accordingly
5. If `$SyncDeletes` is enabled, removes records for hosts present in the previous run but absent from the current connected-user list
6. Writes an updated state cache recording what the script currently owns in the zone

## Deleting records

By default the script only ever adds and updates. That is safe, but it leaves a problem: records written by this script are **static**, and under secure dynamic update a client cannot overwrite a record owned by the script's service account. A machine that disconnects from the VPN and returns on-prem therefore keeps resolving to its stale VPN IP indefinitely — its own dynamic registration is refused. Setting `SyncDeletes` to `true` fixes this by removing the record once the host drops off the ZPA connected-user list, freeing the name for the client to reclaim.

The two directions are deliberately asymmetric:

| Event | Behaviour |
|-------|-----------|
| Host **connects** to the VPN | The A record is overwritten unconditionally, including records the script does not own. A client that dynamically registered its LAN address while on-net is superseded by its VPN address. |
| Host **disconnects** from the VPN | The record is deleted **only if its current IP still matches what the script last wrote** for that host. |

The match test on delete exists because a mismatch means something more current than the script has already taken the name over — most often the client re-registering after the record was scavenged. Deleting in that case would destroy the correct on-prem record, which is the opposite of the intent. Such records are logged as `KEEP … reclaimed elsewhere` and counted as `reclaimed` in the run summary.

`MaxDeletesPerRun` is a blast-radius guard. Because the delete set is derived from the *absence* of hosts in the API response, a transient empty or truncated ZPA reply would otherwise queue every managed record for deletion. If a run exceeds the cap, all deletes are skipped, an `[ERROR]` is logged, and the affected hosts stay in the state cache so a later healthy run can still clean them up.

Enable deletes only once you have run with them off long enough to trust the state cache, and check the log for the first few runs.

## Logs

Activity is written to `$LogFile` and echoed to stdout. Each entry is timestamped and tagged `[INFO]`, `[WARN]`, or `[ERROR]`. The state cache at `$StateFile` is a JSON object mapping hostname labels to their last-synced IP.

## Setup - ZVPN Network Connection Profile Update

1. Host the ZVPN-ConProf.ps1 file on a network share.
2. Use GPO to create a Scheduled Task on all clients per the instructions in ZVPN-SchedTaskConfig.txt.

## How it works

1. Group Policy Object deploys the script to each client machine and creates scheduled task.
2. Scheduled Task triggers on Event ID 10000 in the Microsoft-Windows-NetworkProfile/Operational log, with source NetworkProfile.
3. Script enumerates network interfaces with Alias "Zscaler Tunnel", checks the Network Profile assigned to the interface, and changes it to "Private" if necessary.
