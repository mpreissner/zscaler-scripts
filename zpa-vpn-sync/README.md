# ZPA VPN DNS Sync

Gets the tunnel address of a Zscaler Private Access (ZPA) VPN client into an Active Directory DNS zone, so on-prem resources can resolve VPN clients by hostname.

Two independent mechanisms are provided, and you should pick one as your primary:

- **`ZVPN-ConProf.ps1`** — client-side, GPO-deployed. Each machine registers its own tunnel address using Windows' built-in dynamic update when the tunnel comes up. **Recommended for large deployments.**
- **`zpa-dns-sync-oneapi.ps1`** — server-side. A scheduled task retrieves the live connected-user list from ZPA via OneAPI and adds or updates A records in the target zone. Optionally (`SyncDeletes`) it also removes records once a host drops off the list. Simpler to deploy and far easier to troubleshoot, and a good fit for smaller environments.

See [Choosing an approach](#choosing-an-approach) for how to decide.

## Authors

Tom O'Leary, Mike Preissner

## Files

| File | Purpose |
|------|---------|
| `zpa-dns-sync-oneapi.ps1` | Core sync script. Authenticates to ZPA via OneAPI (OAuth2 client_credentials), fetches all connected VPN users with pagination, and adds or updates A records in the target AD DNS zone. A local state cache avoids redundant DNS operations for entries that haven't changed. |
| `zpa-dns-sync.config.json.example` | Template for the optional external config file — copy to `zpa-dns-sync.config.json` alongside the script and fill in your values. |
| `ZVPN-ConProf.ps1` | Client-side script, GPO-deployed. Reclassifies the "Zscaler Tunnel" adapter as a Private network interface for a less restrictive host firewall (leaving it alone if Windows already classified it `DomainAuthenticated`), and optionally registers the tunnel IP in AD DNS using Windows' built-in dynamic update. A local state file limits registrations to runs where the address actually changed, and the activity log is size-capped and rotated. |
| `zvpn-conprof.config.json.example` | Template for the optional external config file used by `ZVPN-ConProf.ps1` — copy to `zvpn-conprof.config.json` alongside the script and fill in your values. |
| `ZVPN-SchedTaskConfig.txt` | Instructions for deploying a Scheduled Task via Group Policy Objects to run ZVPN-ConProf.ps1 on detection of Zscaler Tunnel Up in Windows Event Log. |

## Choosing an approach

Both mechanisms solve the same problem from opposite ends.

| | Client-side (`ZVPN-ConProf.ps1`) | Server-side (`zpa-dns-sync-oneapi.ps1`) |
|---|---|---|
| Trigger | Each client, on tunnel up | Scheduled task, polling the ZPA API |
| Record owner | The computer account | The script's service account |
| Record type | Dynamic, timestamped | Static |
| Write load | One update per client, spread across the day | Batched into each run |
| Stale records | Cleaned up by scavenging | Need `SyncDeletes` |
| Deployment | GPO to every endpoint | One server |
| Troubleshooting | Per-machine logs | One central log |
| Needs client→DC path | Yes (DNS + Kerberos) | No |

### Prefer client-side at scale

Two reasons, and the first matters more than the load argument.

**Record ownership.** A record the client registers itself is owned by the computer account, so the machine can update it on its own when it returns on-net. Records written by the server-side script are static and owned by its service account, which is precisely what blocks an on-prem client from reclaiming its own name (see [Deleting records](#deleting-records)). Client-side, that problem never arises — and because the records are dynamic and timestamped, ordinary scavenging cleans up anything stale. No delete logic is needed at all.

**Load shape.** The server-side script batches its work. A morning ramp in which several hundred hosts connect within one interval becomes that many DNS operations issued back-to-back against a single server — and each *changed* record costs two, since an update is a remove followed by an add. Any run with at least one change also enumerates every A record in the zone, a cost that scales with zone size rather than with how much actually changed. The client-side script does one update per machine at the moment that machine connects, which is the same load pattern a traditional VPN client already produces.

**`MaxDeletesPerRun` does not scale.** The cap is all-or-nothing: if a single run queues more deletes than the cap, *every* delete is skipped and the hosts are carried forward in the state cache. Because those hosts remain absent from the ZPA response, the next run queues the same set and trips again — it does not self-heal. End-of-day disconnects in a large environment will routinely exceed any cap low enough to still be a useful guard against a truncated API reply. **If your peak disconnects per interval will regularly exceed `MaxDeletesPerRun`, the server-side delete path is not viable for you** — and without deletes you are back to the ownership problem above. That threshold is the clearest signal that you have outgrown the server-side approach.

Before rolling out client-side, confirm that clients can reach a domain controller through the tunnel for **both** DNS (53) and Kerberos (88) — secure dynamic update uses GSS-TSIG, so name resolution alone is not enough. Publish the DC as a ZPA application segment. Also accept that observability becomes distributed: one log per endpoint instead of one overall, with failures that are correspondingly quieter.

### Prefer server-side in smaller environments

Everything that makes the client-side approach scale well also makes it harder to reason about. The server-side script has one log, one config file, and one place to look when something is wrong. You can run it by hand on demand, watch the whole reconciliation happen, and see exactly what it decided and why. It requires no endpoint footprint, no GPO, and no client→DC path, and the ZPA API remains an authoritative central view of what should be registered.

At a few hundred concurrent users the batching costs above are not worth worrying about, and the delete cap comfortably covers realistic disconnect volumes. That is a good trade.

### Running both

Not recommended. The server-side script overwrites records unconditionally, including ones it does not own, and the records it writes are static. Pointing both mechanisms at the same zone means the server-side run converts each client's dynamic, self-owned record into a static one — reintroducing exactly the ownership problem the client-side script exists to avoid. If you must run both during a migration, have them write to different zones, and cut over rather than overlapping.

## Requirements

PowerShell 5.1 or later, for either approach.

**Server-side (`zpa-dns-sync-oneapi.ps1`) additionally needs:**

- `DnsServer` module — included on Windows Server with the DNS role, or installable via RSAT on a domain member: `Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0` for Desktops and `Install-WindowsFeature -Name RSAT-DNS-Server` on Server platforms
- A service account with full CRUD delegation on the target DNS zone (not Domain Admin — standard DNS zone permissions are sufficient)
- OneAPI credentials with read access ZPA API resources

**Client-side (`ZVPN-ConProf.ps1`) additionally needs:**

- A zone that accepts secure dynamic updates
- A domain controller reachable through the tunnel on both DNS (53) and Kerberos (88), published as a ZPA application segment
- GPO to deploy the script and its scheduled task to clients

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

## How it works - server-side sync

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

> **Scale limit.** "A later healthy run" assumes the overage was transient. It is not, if the cause is simply how many people disconnected — those hosts stay absent from the API response, so the next run queues the same set and trips the cap again. Size `MaxDeletesPerRun` above your realistic peak disconnects per interval, and if that number is too large to still function as a guard, use the client-side script instead. See [Choosing an approach](#choosing-an-approach).

## Logs

Activity is written to `$LogFile` and echoed to stdout. Each entry is timestamped and tagged `[INFO]`, `[WARN]`, or `[ERROR]`. The state cache at `$StateFile` is a JSON object mapping hostname labels to their last-synced IP.

## Setup - ZVPN Network Connection Profile Update

`ZVPN-ConProf.ps1` runs on the client when the Zscaler Tunnel adapter comes up and performs two independent jobs, each separately switchable via the config file or the top of the script:

| Job | Setting | Default |
|-----|---------|---------|
| Reclassify the tunnel adapter as a Private network, if it is currently Public | `$EnableProfileReclassification` | `$true` |
| Register the tunnel IP in AD DNS via Windows dynamic update | `$EnableDnsRegistration` | `$false` |

1. Copy `zvpn-conprof.config.json.example` to `zvpn-conprof.config.json` and set your values (see [Client configuration](#client-configuration) below) — at minimum `DnsServerAddress` and `DnsSuffix` if you are enabling DNS registration. Alternatively, edit the **USER CONFIGURATION** block at the top of `ZVPN-ConProf.ps1`.
2. Host the file on a network share, with the config file alongside it.
3. Use GPO to create a Scheduled Task on all clients per the instructions in `ZVPN-SchedTaskConfig.txt`.

### Client configuration

As with the DNS sync script, settings can come from an external config file or from the script itself — **the config file wins**. Keeping your settings in the config file means upgrading `ZVPN-ConProf.ps1` is a straight file replacement, with no need to re-apply your edits to each new version.

The script looks for `zvpn-conprof.config.json` in two places and uses the first one it finds:

1. Alongside the script (`$PSScriptRoot`) — the usual choice, and the one to use when the script runs from a network share.
2. `C:\ProgramData\zpa-vpn-sync\zvpn-conprof.config.json` — for a per-machine override when the script directory is read-only or shared across sites.

Any key the file omits keeps its in-script default, so a config file only needs the settings you actually want to change. If the file is present but unparseable it is reported as a `[WARN]` in the log and the in-script defaults are used — the script does not silently fall through to the other location. Each run logs which config file it loaded, or that it found none.

Config keys and the script variables they override are named identically, minus the `$`:

| Variable / JSON key | Description |
|----------|-------------|
| `$TargetAlias` | Interface alias of the VPN adapter (default: `Zscaler Tunnel`) |
| `$EnableProfileReclassification` | Flip the adapter's network category to Private when it is Public (default: `true`). `Private` and `DomainAuthenticated` are both left as they are |
| `$EnableDnsRegistration` | Register the tunnel IP in AD DNS (default: `false`) |
| `$DnsServerAddress` | Internal DNS server that will accept the dynamic update — **required** when DNS registration is enabled |
| `$DnsSuffix` | Connection-specific suffix to register under. Empty = the machine's primary domain suffix |
| `$StateFile` | Records the last successful registration so unchanged addresses are skipped (default: `C:\ProgramData\zpa-vpn-sync\zvpn-conprof.state.json`). Empty = register on every run |
| `$ForceRegisterAfterHours` | Re-register an unchanged address once the last registration is this old (default: `24`). `0` = only ever register on change |
| `$AdapterTimeoutSeconds` | How long to wait for the adapter to obtain a usable IPv4 address (default: `60`) |
| `$PollIntervalSeconds` | Poll interval while waiting (default: `2`, minimum `1`) |
| `$VerifyRegistration` | Confirm the record landed before releasing the adapter (default: `true`) |
| `$VerifyTimeoutSeconds` | How long to wait for the record to appear (default: `30`) |
| `$PostRegisterDelaySeconds` | Settle delay used instead of verification when `$VerifyRegistration` is `false` |
| `$LogFile` | Activity log (default: `C:\ProgramData\zpa-vpn-sync\zvpn-conprof.log`) |
| `$MaxLogSizeBytes` | Rotate the log once it reaches this size (default: `1048576`, i.e. 1 MB). `0` disables rotation |
| `$LogRetainedFiles` | Rotated copies to keep (default: `1`). `0` discards the old log instead of keeping a copy |
| `$DebugLogging` | Add `[DEBUG]` entries with the detail behind a failed run (default: `false`) — see [Debug logging](#debug-logging) |

In JSON, write booleans unquoted (`true`, not `"true"`) and escape backslashes in Windows paths (`"C:\\ProgramData\\..."`).

### Running it by hand

Both jobs are CIM calls that require administrator rights. The GPO scheduled task runs as SYSTEM, which satisfies this, but a manual test run from an ordinary console does not — the script checks up front and stops with:

```
[ERROR] Not running elevated - both jobs need administrator rights and would fail with
'Access to a CIM resource was not available to the client'. ...
```

Start PowerShell with **Run as administrator** to test manually. If you see the raw `Access to a CIM resource was not available to the client` error from `Set-NetConnectionProfile` or `Set-DnsClientServerAddress` instead, that is the same cause.

Note that a non-elevated run can still *look* like it partly worked: when the adapter is already in an acceptable category the reclassification job logs `is classified Private - no change needed` without attempting a write, so it never hits the permission error.

## How it works - client-side registration

1. Group Policy Object deploys the script to each client machine and creates the scheduled task.
2. Scheduled Task triggers on Event ID 10000 in the Microsoft-Windows-NetworkProfile/Operational log, with source NetworkProfile.
3. The script waits for the "Zscaler Tunnel" adapter to hold a usable IPv4 address. Event 10000 fires when the network profile is evaluated, which can beat the adapter actually being addressable, so it polls rather than assumes. APIPA (`169.254.x.x`) and non-`Preferred` addresses do not count.
4. It checks the network category assigned to the interface and changes it to Private only if it is `Public` (see [Network category](#network-category)).
5. If DNS registration is enabled, it registers the tunnel address — but only if that address (or the name it registers under) has changed since the last run (see below).

### Network category

The point of this job is the host firewall: an adapter Windows has categorised as `Public` gets the Public firewall profile, which drops the inbound connections the tunnel exists to carry. Two of the three categories are already fine:

| Category | Firewall profile | Action |
|----------|------------------|--------|
| `Public` | Public — restrictive | Reclassified to `Private` |
| `Private` | Private | Left alone |
| `DomainAuthenticated` | Domain | Left alone |

`DomainAuthenticated` is assigned by the Network Location Awareness service when it can authenticate a domain controller over the adapter, which does happen on the tunnel. It is equally permissive for our purposes, and it cannot be changed by script in any case — `Set-NetConnectionProfile -NetworkCategory` accepts `Public` and `Private` only. Treating it as a problem would mean an error in the log on every run that nothing could ever clear, so the script reports the category and moves on:

```
[INFO] 'Zscaler Tunnel' is classified DomainAuthenticated - no change needed
```

### Dynamic DNS registration

The tunnel adapter comes up with no DNS servers and no connection-specific suffix of its own. `Register-DnsClient` has no way to be pointed at a particular server — the resolver chooses one by interface metric, which off-net is typically the user's home router or their ISP. Neither will accept or forward the update. The script therefore:

1. Applies `$DnsServerAddress` to the tunnel adapter, so the SOA lookup and the update itself go through the tunnel.
2. Sets `RegisterThisConnectionsAddress` (and the connection-specific suffix, if `$DnsSuffix` is set).
3. Calls `Register-DnsClient`.
4. Polls the DNS server until the record resolves to the tunnel IP.
5. Removes the DNS server from the adapter again.

**Only when something changed.** The scheduled task fires on every network profile evaluation, so on a machine that reconnects through the day this job would otherwise send a secure dynamic update to a domain controller several times an hour, almost all of them writing the address that is already there. The script records each successful registration in `$StateFile` and does the work again only when:

- the tunnel address differs from the recorded one, or
- the name being registered differs (you changed `$DnsSuffix`, or the machine's primary domain suffix changed), or
- the recorded registration is older than `$ForceRegisterAfterHours`, or
- there is no usable state file — missing, unreadable, or written by a clock that has since moved backwards.

The refresh interval matters: AD DNS scavenging deletes records that stop being refreshed (with the usual 7-day no-refresh / 7-day refresh intervals, a record goes after 14 days), so an address that never changes still needs an occasional touch. The 24-hour default matches what the Windows DNS client does with its own registrations and is well inside any sane scavenging window. Set it to `0` only if scavenging is disabled on the zone.

The state file is only written after the registration is confirmed, so a failed or unverified update is retried on the next trigger rather than being skipped as already done. With `$VerifyRegistration` set to `false` there is nothing to confirm it, so a submission that was accepted locally but never landed will be treated as done until the refresh interval comes round — another reason to leave verification on. Deleting the state file forces a registration on the next run.

Step 5 always runs, including when an earlier step throws — leaving an internal DNS server pinned to the tunnel adapter would affect all name resolution on the machine once the tunnel drops. Step 4 deliberately runs *before* step 5: `Register-DnsClient` hands the update to the DNS Client service and returns immediately, so releasing the adapter too early can cut the update off before it is sent.

`$DnsServerAddress` must be reachable through the tunnel — publish it as a ZPA application segment, or the update never leaves the machine.

**Why register client-side at all.** Records written by `zpa-dns-sync-oneapi.ps1` are static and owned by its service account, which is what blocks an on-prem client from updating them (see [Deleting records](#deleting-records)). A record the client registers itself is owned by the computer account, so the machine can update it on its own when it returns on-net. That, plus a write pattern that spreads naturally across the day, is why this is the recommended approach at scale — see [Choosing an approach](#choosing-an-approach), including why running both mechanisms against one zone defeats the purpose.

**Known limitations.**

- `Register-DnsClient` is machine-wide. It triggers registration for every adapter with registration enabled, not just the tunnel. There is no per-adapter variant.
- Because the DNS server is removed from the adapter afterwards, Windows' periodic background re-registration (roughly every 24h) again has no route to the internal DNS server. A long-lived tunnel session could therefore see the record scavenged before the script next runs.

### Debug logging

Set `DebugLogging` to `true` in the config file (or `$DebugLogging = $true` in the script) to add `[DEBUG]` entries to the same log. It is aimed at a registration that fails or silently does nothing, and it collects, per run:

- **Host** — computer name, the identity the run is under, PowerShell and OS version, primary DNS suffix.
- **Adapter state**, captured at each stage (`adapter ready`, `before registration`, `DNS server applied`) — link status, all IPv4 addresses with their address state, interface metric, the DNS servers currently on the adapter, and the connection-specific suffix plus the `RegisterThisConnectionsAddress` / `UseSuffixWhenRegistering` flags.
- **DNS servers on every interface** — `Register-DnsClient` is machine-wide and the resolver picks a server by interface metric, so what is on the *other* adapters matters.
- **Route to `$DnsServerAddress`** — which interface and source address traffic to the DNS server would actually use. If that is the home NIC rather than the tunnel, the update never entered the tunnel and nothing on the DNS side is at fault.
- **TCP 53 and TCP 88 reachability** — secure dynamic update is GSS-TSIG, so it needs Kerberos to the domain controller as well as DNS. A machine that resolves names perfectly but cannot reach 88 fails the update with nothing obviously wrong on the DNS side.
- **The zone's SOA and the name's current A records**, as seen from `$DnsServerAddress` — the client looks the SOA up to find the zone's primary before it sends anything, so a failure there fails the whole registration.
- **Every verification lookup**, including the attempts that came back empty and the exception behind any lookup error.
- **DNS Client events from the System log**, filtered to the window after the update was submitted. `Register-DnsClient` returns as soon as the DNS Client service accepts the request and never reports what happened next — the service does, under event 8018 and its neighbours, with the actual reason (server refused the update, no domain controller, timeout).
- **The state file's contents**, so a run that skipped registration shows what it compared against.

Diagnostics are never load-bearing: each probe runs inside its own error handler, so a cmdlet missing on the host or an adapter that disappears mid-run is reported as `could not be collected` rather than failing the run.

Leave it off in steady state. A debug run writes several times as many lines as a normal one and spends a few extra seconds on the reachability probes, and the trigger fires on every network profile evaluation — `$MaxLogSizeBytes` and `$LogRetainedFiles` still cap the file, but the rotation window gets correspondingly shorter.
