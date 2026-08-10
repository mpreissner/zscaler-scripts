# ZPA VPN DNS Sync

Keeps an Active Directory DNS zone in sync with users currently connected via Zscaler Private Access (ZPA) VPN Legacy Apps. On each run it retrieves the live connected-user list from ZPA via OneAPI and adds or updates A records in the target zone so that on-prem resources can resolve VPN clients by hostname. Optionally (`SyncDeletes`) it also removes records once a host drops off the connected-user list.

## Authors

Tom O'Leary, Mike Preissner

## Files

| File | Purpose |
|------|---------|
| `zpa-dns-sync-oneapi.ps1` | Core sync script. Authenticates to ZPA via OneAPI (OAuth2 client_credentials), fetches all connected VPN users with pagination, and adds or updates A records in the target AD DNS zone. A local state cache avoids redundant DNS operations for entries that haven't changed. |
| `zpa-dns-sync.config.json.example` | Template for the optional external config file — copy to `zpa-dns-sync.config.json` alongside the script and fill in your values. |
| `ZVPN-ConProf.ps1` | Client-side script, GPO-deployed. Reclassifies the "Zscaler Tunnel" adapter as a Private network interface for a less restrictive host firewall, and optionally registers the tunnel IP in AD DNS using Windows' built-in dynamic update. |
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

`ZVPN-ConProf.ps1` runs on the client when the Zscaler Tunnel adapter comes up and performs two independent jobs, each separately switchable at the top of the script:

| Job | Setting | Default |
|-----|---------|---------|
| Reclassify the tunnel adapter as a Private network | `$EnableProfileReclassification` | `$true` |
| Register the tunnel IP in AD DNS via Windows dynamic update | `$EnableDnsRegistration` | `$false` |

1. Edit the **USER CONFIGURATION** block at the top of `ZVPN-ConProf.ps1` — at minimum set `$DnsServerAddress` and `$DnsSuffix` if you are enabling DNS registration.
2. Host the file on a network share.
3. Use GPO to create a Scheduled Task on all clients per the instructions in `ZVPN-SchedTaskConfig.txt`.

### Client configuration

| Variable | Description |
|----------|-------------|
| `$TargetAlias` | Interface alias of the VPN adapter (default: `Zscaler Tunnel`) |
| `$EnableProfileReclassification` | Flip the adapter's network category to Private |
| `$EnableDnsRegistration` | Register the tunnel IP in AD DNS |
| `$DnsServerAddress` | Internal DNS server that will accept the dynamic update — **required** when DNS registration is enabled |
| `$DnsSuffix` | Connection-specific suffix to register under. Empty = the machine's primary domain suffix |
| `$AdapterTimeoutSeconds` | How long to wait for the adapter to obtain a usable IPv4 address (default: `60`) |
| `$PollIntervalSeconds` | Poll interval while waiting (default: `2`) |
| `$VerifyRegistration` | Confirm the record landed before releasing the adapter (default: `$true`) |
| `$VerifyTimeoutSeconds` | How long to wait for the record to appear (default: `30`) |
| `$PostRegisterDelaySeconds` | Settle delay used instead of verification when `$VerifyRegistration` is `$false` |
| `$LogFile` | Activity log (default: `C:\ProgramData\zpa-vpn-sync\zvpn-conprof.log`) |

## How it works

1. Group Policy Object deploys the script to each client machine and creates the scheduled task.
2. Scheduled Task triggers on Event ID 10000 in the Microsoft-Windows-NetworkProfile/Operational log, with source NetworkProfile.
3. The script waits for the "Zscaler Tunnel" adapter to hold a usable IPv4 address. Event 10000 fires when the network profile is evaluated, which can beat the adapter actually being addressable, so it polls rather than assumes. APIPA (`169.254.x.x`) and non-`Preferred` addresses do not count.
4. It checks the network profile assigned to the interface and changes it to Private if necessary.
5. If DNS registration is enabled, it registers the tunnel address (see below).

### Dynamic DNS registration

The tunnel adapter comes up with no DNS servers and no connection-specific suffix of its own. `Register-DnsClient` has no way to be pointed at a particular server — the resolver chooses one by interface metric, which off-net is typically the user's home router or their ISP. Neither will accept or forward the update. The script therefore:

1. Applies `$DnsServerAddress` to the tunnel adapter, so the SOA lookup and the update itself go through the tunnel.
2. Sets `RegisterThisConnectionsAddress` (and the connection-specific suffix, if `$DnsSuffix` is set).
3. Calls `Register-DnsClient`.
4. Polls the DNS server until the record resolves to the tunnel IP.
5. Removes the DNS server from the adapter again.

Step 5 always runs, including when an earlier step throws — leaving an internal DNS server pinned to the tunnel adapter would affect all name resolution on the machine once the tunnel drops. Step 4 deliberately runs *before* step 5: `Register-DnsClient` hands the update to the DNS Client service and returns immediately, so releasing the adapter too early can cut the update off before it is sent.

`$DnsServerAddress` must be reachable through the tunnel — publish it as a ZPA application segment, or the update never leaves the machine.

**Why register client-side at all.** Records written by `zpa-dns-sync-oneapi.ps1` are static and owned by its service account, which is what blocks an on-prem client from updating them (see [Deleting records](#deleting-records)). A record the client registers itself is owned by the computer account, so the machine can update it on its own when it returns on-net. If you run both mechanisms, point `$DnsSuffix` at the same zone as the server script's `$DnsZone`.

**Known limitations.**

- `Register-DnsClient` is machine-wide. It triggers registration for every adapter with registration enabled, not just the tunnel. There is no per-adapter variant.
- Because the DNS server is removed from the adapter afterwards, Windows' periodic background re-registration (roughly every 24h) again has no route to the internal DNS server. A long-lived tunnel session could therefore see the record scavenged before the script next runs.
