#Requires -Modules DnsServer

# =============================================================================
# zpa-dns-sync-oneapi.ps1
#
# Retrieves VPN Legacy App connected users from Zscaler ZPA via OneAPI and
# syncs their hostname-to-IP mappings as A records in an Active Directory DNS
# zone. Records are added and updated unconditionally - a client connecting to
# the VPN overwrites whatever A record it previously registered on-net. When
# $SyncDeletes is enabled, records are also removed once a host drops off the
# ZPA connected-user list, so the name is free for the client to reclaim via
# normal AD dynamic registration.
#
# Intended to run as a Windows Scheduled Task under a service account that
# holds full CRUD delegation for the target DNS zone (DNS Zone permissions,
# NOT Domain Admin). No local administrator rights are required.
#
# SCHEDULED TASK SETUP (run once as an admin):
#   $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
#                  -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\Sync-ZPAVpnDns.ps1"
#   $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
#   $principal = New-ScheduledTaskPrincipal -UserId "CORP\svc-zpavpndns" -LogonType Password -RunLevel Limited
#   Register-ScheduledTask -TaskName "ZPA VPN DNS Sync" -Action $action -Trigger $trigger -Principal $principal
# =============================================================================


# =============================================================================
# USER CONFIGURATION - fill in all values before first run
# =============================================================================

# Zscaler OneAPI credentials (ZPA > Administration > API Key Management)
$ClientId     = "YOUR_CLIENT_ID_HERE"
$ClientSecret = "YOUR_CLIENT_SECRET_HERE"

# Your ZIdentity vanity domain - the part before .zslogin.net
# e.g. if your ZIdentity URL is https://acme.zslogin.net, enter "acme"
$VanityDomain = "yourcompany"

# ZPA Customer ID (visible in Admin Portal URL or ZPA > Administration > Company Profile)
$CustomerId   = "YOUR_CUSTOMER_ID_HERE"

# Active Directory DNS zone to manage A records in
$DnsZone      = "vpn.corp.local"

# Hostname or IP of the AD-integrated DNS server to update
$DnsServer    = "dc01.corp.local"

# TTL (seconds) applied to records created by this script
$RecordTtl    = 300

# Where to write the activity log (directory is created automatically)
$LogFile      = "C:\Logs\zpa-vpn-sync\zpa-vpn-sync.log"

# State file - caches the hostname-to-IP map from the last successful run.
# Entries whose IP hasn't changed are skipped so DNS is only touched when
# something actually changed. Format: { "hostname": "last-synced-ip" }
$StateFile    = "C:\ProgramData\zpa-vpn-sync\managed-hosts.json"

# ZPA API page size (1-500). 500 minimises round-trips.
$PageSize     = 500

# Remove A records for hosts that have dropped off the ZPA connected-user list.
#
# Records written by this script are static, and under secure dynamic update a
# client cannot overwrite a record owned by this script's service account. A
# host that returns on-prem therefore keeps resolving to its stale VPN IP
# indefinitely. Deleting the record frees the name so the client's own dynamic
# registration can reclaim it.
#
# A record is only deleted when its current IP still matches what this script
# last wrote for that host (per $StateFile). If the IP has changed, something
# else has already taken the name over - most likely the client re-registering
# after scavenging, or a manual fix - and that value is more current than ours,
# so the record is left alone. This check applies ONLY to the delete path;
# adds and updates for a connecting client always overwrite whatever is there.
$SyncDeletes  = $false

# Safety valve: if a single run would delete more than this many records, all
# deletes are skipped and logged as an error. Guards against a transient empty
# or partial ZPA response wiping every managed record in the zone. Set to 0 to
# remove the cap.
$MaxDeletesPerRun = 50

# =============================================================================
# CONFIG FILE (optional) - overrides the defaults above
# Copy zpa-dns-sync.config.json.example -> zpa-dns-sync.config.json alongside
# this script on the target machine and fill in your values. The config file
# is gitignored so secrets stay off the repo.
# =============================================================================
$_cfgPath = Join-Path $PSScriptRoot "zpa-dns-sync.config.json"
if (Test-Path $_cfgPath) {
    $cfg = Get-Content $_cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.ClientId)     { $ClientId     = [string]$cfg.ClientId }
    if ($cfg.ClientSecret) { $ClientSecret = [string]$cfg.ClientSecret }
    if ($cfg.VanityDomain) { $VanityDomain = [string]$cfg.VanityDomain }
    if ($cfg.CustomerId)   { $CustomerId   = [string]$cfg.CustomerId }
    if ($cfg.DnsZone)      { $DnsZone      = [string]$cfg.DnsZone }
    if ($cfg.DnsServer)    { $DnsServer    = [string]$cfg.DnsServer }
    if ($cfg.RecordTtl)    { $RecordTtl    = [int]$cfg.RecordTtl }
    if ($cfg.LogFile)      { $LogFile      = [string]$cfg.LogFile }
    if ($cfg.StateFile)    { $StateFile    = [string]$cfg.StateFile }
    if ($cfg.PageSize)     { $PageSize     = [int]$cfg.PageSize }
    # Presence tests, not truthiness - a config value of false or 0 is a
    # meaningful setting here and must still override the default above.
    if ($cfg.PSObject.Properties['SyncDeletes'])      { $SyncDeletes      = [bool]$cfg.SyncDeletes }
    if ($cfg.PSObject.Properties['MaxDeletesPerRun']) { $MaxDeletesPerRun = [int]$cfg.MaxDeletesPerRun }
    Remove-Variable cfg, _cfgPath
}

# =============================================================================
# SCRIPT INTERNALS - no changes needed below this line
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OneApiBase = "https://api.zsapi.net/zpa"
$TokenUrl   = "https://${VanityDomain}.zslogin.net/oauth2/v1/token"
$UsersUrl   = "${OneApiBase}/mgmtconfig/v1/admin/customers/${CustomerId}/vpnConnectedUsers"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    try {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path $LogFile -Value $entry -Encoding UTF8
    }
    catch {
        Write-Host "[WARN] Could not write to log file: $_"
    }
}

# ---------------------------------------------------------------------------
# ZPA Authentication (OAuth2 client_credentials, cached within the run)
# ---------------------------------------------------------------------------
$script:AccessToken  = $null
$script:TokenExpiry  = [DateTime]::MinValue

function Get-ZPAToken {
    if ($script:AccessToken -and ([DateTime]::UtcNow -lt $script:TokenExpiry)) {
        return $script:AccessToken
    }
    Write-Log "Requesting access token from ZIdentity (${VanityDomain}.zslogin.net)..."
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        audience      = "https://api.zscaler.com"
    }
    try {
        $resp = Invoke-RestMethod -Uri $TokenUrl -Method Post `
            -Body $body -ContentType "application/x-www-form-urlencoded"
    }
    catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'N/A' }
        $body       = if ($_.ErrorDetails)        { $_.ErrorDetails.Message }               else { $_.Exception.Message }
        Write-Log "Token request failed (HTTP $statusCode): $body" "ERROR"
        throw
    }
    $script:AccessToken = $resp.access_token
    $expiresIn          = if ($resp.expires_in) { [int]$resp.expires_in } else { 3600 }
    $script:TokenExpiry = [DateTime]::UtcNow.AddSeconds($expiresIn * 0.9)
    Write-Log "Access token obtained (expires in ${expiresIn}s)"
    return $script:AccessToken
}

function Get-AuthHeaders {
    return @{
        "Authorization" = "Bearer $(Get-ZPAToken)"
        "Content-Type"  = "application/json"
    }
}

# ---------------------------------------------------------------------------
# ZPA API - fetch all VPN connected users (handles pagination)
# ---------------------------------------------------------------------------
function Get-VPNConnectedUsers {
    Write-Log "Fetching VPN connected users from ZPA..."
    $allUsers  = [System.Collections.Generic.List[object]]::new()
    $page      = 1
    $totalPages = 1

    do {
        $url = "${UsersUrl}?pagesize=${PageSize}&page=${page}"
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Get -Headers (Get-AuthHeaders)
        }
        catch {
            Write-Log "API request failed (page ${page}): $_" "ERROR"
            throw
        }

        $batch = $resp.list
        if ($batch) {
            foreach ($u in $batch) { $allUsers.Add($u) }
        }

        if ($resp.PSObject.Properties['totalPages']) {
            $totalPages = [int]$resp.totalPages
        }
        Write-Log "  Page ${page}/${totalPages} - $($batch.Count) users"
        $page++
    } while ($page -le $totalPages)

    Write-Log "Total VPN connected users: $($allUsers.Count)"
    return ,$allUsers.ToArray()
}

# ---------------------------------------------------------------------------
# State file - hostname -> last-synced-IP cache
# ---------------------------------------------------------------------------
function Read-StateFile {
    if (Test-Path $StateFile) {
        try {
            $raw    = Get-Content $StateFile -Raw -Encoding UTF8
            $parsed = $raw | ConvertFrom-Json
            if ($null -eq $parsed) { return @{} }
            $ht = @{}
            $parsed.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        }
        catch {
            Write-Log "Could not parse state file - treating as empty: $_" "WARN"
        }
    }
    return @{}
}

function Write-StateFile {
    param([hashtable]$State)
    $stateDir = Split-Path $StateFile -Parent
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $State | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

# ---------------------------------------------------------------------------
# DNS sync
# ---------------------------------------------------------------------------
function Sync-DNSRecords {
    param([object[]]$VpnUsers)

    # Build hostname -> IP map from API response.
    # Hostnames that are FQDNs (e.g. HOST.corp.local) are trimmed to their
    # first label so they register correctly within $DnsZone.
    $vpnMap = @{}
    foreach ($user in $VpnUsers) {
        $hostname = $user.hostname
        $ip       = $user.clientIpAddress
        if ([string]::IsNullOrWhiteSpace($hostname) -or [string]::IsNullOrWhiteSpace($ip)) {
            Write-Log "Skipping entry with missing hostname or IP (user: $($user.userName))" "WARN"
            continue
        }
        $dnsLabel = $hostname.Split('.')[0].ToLower()
        if ($vpnMap.ContainsKey($dnsLabel)) {
            Write-Log "Duplicate DNS label '$dnsLabel' in API response - keeping first entry ($($vpnMap[$dnsLabel]))" "WARN"
            continue
        }
        $vpnMap[$dnsLabel] = $ip
    }

    # Load last-run IP cache - entries whose IP matches are skipped entirely.
    # $newState is built here: seeded with unchanged entries, updated on success
    # below, and written at the end. It contains only current VPN users, so
    # disconnected users are automatically pruned from the cache each run.
    $prevState = Read-StateFile
    $toSync    = @{}
    $newState  = @{}
    $skipped   = 0
    foreach ($label in $vpnMap.Keys) {
        if ($prevState.ContainsKey($label) -and $prevState[$label] -eq $vpnMap[$label]) {
            $skipped++
            $newState[$label] = $prevState[$label]  # carry forward, no DNS op needed
        }
        else {
            $toSync[$label] = $vpnMap[$label]
        }
    }
    # Hosts present in the previous run but absent from the current connected-user
    # list have disconnected from the VPN. Their records are the stale static
    # entries that block on-prem dynamic registration.
    $toDelete = @{}
    if ($SyncDeletes) {
        foreach ($label in $prevState.Keys) {
            if (-not $vpnMap.ContainsKey($label)) { $toDelete[$label] = $prevState[$label] }
        }
        if ($MaxDeletesPerRun -gt 0 -and $toDelete.Count -gt $MaxDeletesPerRun) {
            Write-Log ("$($toDelete.Count) records queued for deletion exceeds MaxDeletesPerRun " +
                       "($MaxDeletesPerRun) - skipping ALL deletes this run. If the ZPA response " +
                       "was genuinely this much smaller, raise the cap or clear the state file.") "ERROR"
            # Carry the entries forward so a later run can still delete them.
            foreach ($label in $toDelete.Keys) { $newState[$label] = $toDelete[$label] }
            $toDelete = @{}
        }
    }

    Write-Log "$($vpnMap.Count) connected users - $($toSync.Count) to sync, $($toDelete.Count) to delete, $skipped unchanged"

    if ($toSync.Count -eq 0 -and $toDelete.Count -eq 0) {
        Write-Log "No DNS changes required."
        if ($newState.Count -ne $prevState.Count) { Write-StateFile -State $newState }
        return
    }

    # Snapshot existing A records only for the labels we need to act on
    Write-Log "Querying zone '${DnsZone}' on ${DnsServer}..."

    # Pre-flight: verify WinRM is reachable before attempting DNS cmdlet
    try {
        Test-WSMan -ComputerName $DnsServer -ErrorAction Stop | Out-Null
        Write-Log "WinRM reachable on ${DnsServer}"
    }
    catch {
        Write-Log "WinRM pre-flight failed for ${DnsServer}: $_" "WARN"
    }

    try {
        $existing = Get-DnsServerResourceRecord `
            -ZoneName $DnsZone -RRType A -ComputerName $DnsServer -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Failed to query DNS zone: $_" "ERROR"
        Write-Log "  Exception type : $($_.Exception.GetType().FullName)" "ERROR"
        if ($_.Exception.InnerException) {
            Write-Log "  Inner exception: $($_.Exception.InnerException.Message)" "ERROR"
            if ($_.Exception.InnerException.InnerException) {
                Write-Log "  Root cause     : $($_.Exception.InnerException.InnerException.Message)" "ERROR"
            }
        }
        throw
    }
    # A name can legitimately hold several A records, so map each label to the
    # full list. The delete path needs this to target one specific record data
    # rather than wiping every A record sharing the name.
    $existingMap = @{}
    foreach ($rec in $existing) {
        $label = $rec.HostName.ToLower()
        if (-not $existingMap.ContainsKey($label)) {
            $existingMap[$label] = [System.Collections.Generic.List[string]]::new()
        }
        $existingMap[$label].Add($rec.RecordData.IPv4Address.ToString())
    }

    $ttlSpan = [TimeSpan]::FromSeconds($RecordTtl)
    $added = 0; $updated = 0; $deleted = 0; $reclaimed = 0; $errors = 0

    foreach ($label in $toSync.Keys) {
        $ip = $toSync[$label]
        try {
            if ($existingMap.ContainsKey($label)) {
                $currentIps = $existingMap[$label]
                # Only a single record already holding the right IP is a no-op.
                # Anything else - a different IP, or several records for the name -
                # is replaced. This deliberately overwrites records the script does
                # not own: a client connecting to the VPN must supersede whatever
                # address it dynamically registered while it was on-net.
                if ($currentIps.Count -eq 1 -and $currentIps[0] -eq $ip) {
                    Write-Log "VERIFY  $label.$DnsZone already $ip - no update needed"
                }
                else {
                    Write-Log "UPDATE  $label.$DnsZone : $($currentIps -join ', ') -> $ip"
                    Remove-DnsServerResourceRecord `
                        -ZoneName $DnsZone -Name $label -RRType A `
                        -ComputerName $DnsServer -Force
                    Add-DnsServerResourceRecordA `
                        -Name $label -ZoneName $DnsZone -IPv4Address $ip `
                        -TimeToLive $ttlSpan -ComputerName $DnsServer
                    $updated++
                }
            }
            else {
                Write-Log "ADD     $label.$DnsZone -> $ip"
                Add-DnsServerResourceRecordA `
                    -Name $label -ZoneName $DnsZone -IPv4Address $ip `
                    -TimeToLive $ttlSpan -ComputerName $DnsServer
                $added++
            }
            # Add to pruned state on success (regardless of add/update/verify)
            $newState[$label] = $ip
        }
        catch {
            Write-Log "Failed to sync '$label': $_" "ERROR"
            $errors++
        }
    }

    # Remove the stale static records left behind by hosts that have disconnected.
    # Successfully deleted (and already-absent, and reclaimed) labels are simply
    # not written back into $newState, so the script stops tracking them.
    foreach ($label in $toDelete.Keys) {
        $lastIp = $toDelete[$label]
        try {
            if (-not $existingMap.ContainsKey($label)) {
                Write-Log "GONE    $label.$DnsZone already absent - nothing to delete"
                continue
            }
            if ($existingMap[$label] -notcontains $lastIp) {
                Write-Log ("KEEP    $label.$DnsZone is now $($existingMap[$label] -join ', '), " +
                           "not the $lastIp this script wrote - reclaimed elsewhere, leaving it alone")
                $reclaimed++
                continue
            }
            Write-Log "DELETE  $label.$DnsZone : $lastIp (no longer VPN connected)"
            Remove-DnsServerResourceRecord `
                -ZoneName $DnsZone -Name $label -RRType A -RecordData $lastIp `
                -ComputerName $DnsServer -Force
            $deleted++
        }
        catch {
            Write-Log "Failed to delete '$label': $_" "ERROR"
            $errors++
            # Keep it in state so the next run retries the delete.
            $newState[$label] = $lastIp
        }
    }

    Write-StateFile -State $newState

    Write-Log "Sync complete - added: $added  updated: $updated  deleted: $deleted  reclaimed: $reclaimed  errors: $errors"
    if ($errors -gt 0) {
        Write-Log "$errors DNS operation(s) failed - review log for details" "WARN"
    }
}

# =============================================================================
# MAIN
# =============================================================================
Write-Log "=== ZPA VPN DNS Sync starting ==="
Write-Log "Customer ID : $CustomerId"
Write-Log "DNS Zone    : $DnsZone  |  Server: $DnsServer"
Write-Log ("Deletes     : " + $(if ($SyncDeletes) { "enabled (cap: $(if ($MaxDeletesPerRun -gt 0) { $MaxDeletesPerRun } else { 'none' }) per run)" } else { "disabled" }))

try {
    $vpnUsers = Get-VPNConnectedUsers
    Sync-DNSRecords -VpnUsers $vpnUsers
    Write-Log "=== ZPA VPN DNS Sync finished successfully ==="
}
catch {
    Write-Log "=== ZPA VPN DNS Sync FAILED: $_ ===" "ERROR"
    exit 1
}
