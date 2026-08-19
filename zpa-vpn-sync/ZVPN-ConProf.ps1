# =============================================================================
# ZVPN-ConProf.ps1
#
# Runs on the client when the Zscaler Tunnel adapter comes up. Two independent
# jobs, each separately switchable:
#
#   1. Reclassify the "Zscaler Tunnel" adapter as a Private network so Windows
#      Firewall stops dropping inbound connections over the tunnel. An adapter
#      Windows already classified DomainAuthenticated is left alone - it is
#      equally permissive, and it cannot be changed by script anyway.
#   2. Register the adapter's tunnel IP in AD DNS using Windows' own dynamic
#      update mechanism, so the record is owned by the computer account and the
#      machine can update it itself when it returns on-prem. The last
#      registration is recorded in $StateFile and the update is skipped while
#      the address is unchanged.
#
# Deployed via GPO and triggered by Event ID 10000 in the
# Microsoft-Windows-NetworkProfile/Operational log. See ZVPN-SchedTaskConfig.txt.
#
# Runs as SYSTEM - Set-DnsClientServerAddress and Set-NetConnectionProfile both
# require elevation.
# =============================================================================


# =============================================================================
# USER CONFIGURATION
#
# These are the fallback defaults. An optional zvpn-conprof.config.json placed
# alongside this script (or in C:\ProgramData\zpa-vpn-sync\) overrides any of
# them - see the CONFIG FILE section below. Using the config file is preferred:
# upgrading the script is then a file replacement rather than a re-edit.
# =============================================================================

# Interface alias of the ZPA VPN for Legacy Apps adapter
$TargetAlias = "Zscaler Tunnel"

# --- Job 1: network category ---------------------------------------------
$EnableProfileReclassification = $true

# --- Job 2: dynamic DNS registration -------------------------------------
$EnableDnsRegistration = $false

# Internal DNS server that will accept the dynamic update. Required when
# $EnableDnsRegistration is $true.
#
# The tunnel adapter comes up with no DNS servers of its own, so without this
# the resolver picks a server by interface metric - off-net that is typically
# the user's home router or their ISP, which will not accept or forward the
# update. This address is set on the adapter only for the duration of the
# registration and removed again afterwards.
#
# It must be reachable through the tunnel: the DNS server has to be published
# as a ZPA application segment, or the update never leaves the machine.
$DnsServerAddress = "10.10.10.10"

# Connection-specific DNS suffix to register the tunnel IP under.
#
#   ""                  Register as <hostname>.<primary domain suffix> - the
#                       machine's normal AD name. The tunnel IP then competes
#                       with the LAN A record in the primary zone.
#   "vpn.corp.local"    Register as <hostname>.vpn.corp.local, keeping VPN
#                       addresses in a dedicated zone. Match this to $DnsZone
#                       in zpa-dns-sync-oneapi.ps1 if you run both.
$DnsSuffix = ""

# Where the last successful registration is recorded, so a run that finds the
# same address under the same name can skip the update entirely. The trigger
# fires on every network profile evaluation - without this, a laptop that
# reconnects all day sends a secure dynamic update to a domain controller every
# time, none of which change anything. Set to "" to disable the tracking and
# register on every run.
$StateFile = "C:\ProgramData\zpa-vpn-sync\zvpn-conprof.state.json"

# Re-register even when nothing changed, once the last registration is this old.
# AD DNS scavenging deletes records that stop being refreshed - with the usual
# 7-day no-refresh / 7-day refresh intervals a record goes after 14 days - so an
# unchanging address still needs an occasional touch. 24 hours matches what the
# Windows DNS client does with its own registrations. Set to 0 to refresh only
# when the address changes.
$ForceRegisterAfterHours = 24

# --- Adapter readiness ----------------------------------------------------
# Event 10000 fires when the network profile is evaluated, which can beat the
# adapter actually holding a usable IPv4 address. Poll rather than assume.
$AdapterTimeoutSeconds = 60
$PollIntervalSeconds   = 2

# --- Registration verification -------------------------------------------
# Register-DnsClient hands the update to the DNS Client service and returns
# immediately, so confirm the record landed before tearing the DNS server back
# off the adapter. Disabling this leaves only a fixed settle delay.
$VerifyRegistration    = $true
$VerifyTimeoutSeconds  = 30
$PostRegisterDelaySeconds = 5

# Activity log (directory is created automatically). Set to "" to log to stdout
# only - note that a GPO scheduled task running as SYSTEM has nowhere to show
# stdout, so a file is strongly recommended.
$LogFile = "C:\ProgramData\zpa-vpn-sync\zvpn-conprof.log"

# --- Log rotation ---------------------------------------------------------
# Size at which the log is rotated, in bytes. A single run writes well under a
# kilobyte, but the trigger fires on every profile evaluation, so on a laptop
# that reconnects all day the file does need a ceiling. Set to 0 to disable
# rotation and let the log grow without limit.
$MaxLogSizeBytes = 1MB

# How many rotated copies to keep alongside the live log (zvpn-conprof.log.1,
# .log.2, ...). Worst case on disk is ($LogRetainedFiles + 1) * $MaxLogSizeBytes,
# so the default keeps the whole thing under about 2 MB. 0 discards the old log
# instead of keeping a copy.
$LogRetainedFiles = 1

# --- Debug logging --------------------------------------------------------
# Adds [DEBUG] entries describing what the machine actually looked like at each
# step: adapter and DNS client state, which interface traffic to the DNS server
# would leave by, whether 53 and 88 are reachable, the zone's SOA, every
# verification lookup, and any DNS Client events Windows itself logged during
# the run. That is most of what is needed to explain a failed registration
# without going back to the endpoint.
#
# Off by default - it multiplies a run's output several times over, which the
# rotation settings above then have to absorb. Turn it on while investigating,
# turn it off afterwards.
$DebugLogging = $false

# =============================================================================
# CONFIG FILE (optional) - overrides the defaults above
#
# Copy zvpn-conprof.config.json.example -> zvpn-conprof.config.json and put it
# either alongside this script or in C:\ProgramData\zpa-vpn-sync\. The first of
# those found wins; any setting the file omits keeps its value from above.
#
# Keeping settings in the config file makes a script upgrade a straight file
# replacement - no re-editing the block above on every version.
#
# This runs before Set-StrictMode deliberately: under StrictMode, reading a
# property the JSON does not define throws instead of returning nothing.
# =============================================================================

# JSON booleans arrive as [bool] already, but a hand-edited file may quote them,
# and [bool]"false" is $true - which would silently enable a disabled job.
function ConvertTo-ConfigBool {
    param($Value)
    if ($Value -is [string]) { return $Value -match '^\s*(?i:true|yes|on|1)\s*$' }
    return [bool]$Value
}

$ConfigLoadedFrom = $null
$ConfigLoadError  = $null

$_cfgCandidates = @()
if ($PSScriptRoot) { $_cfgCandidates += (Join-Path $PSScriptRoot "zvpn-conprof.config.json") }
$_cfgCandidates += "C:\ProgramData\zpa-vpn-sync\zvpn-conprof.config.json"

foreach ($_cfgPath in $_cfgCandidates) {
    if (-not (Test-Path $_cfgPath)) { continue }

    # First existing candidate is the config, valid or not - fall through to a
    # different file on a parse error and the machine runs settings nobody
    # intended. Report the failure and carry on with whatever is in effect.
    try {
        $cfg = Get-Content $_cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $_p  = $cfg.PSObject.Properties

        # Presence tests, not truthiness - $false, 0 and "" are all meaningful
        # settings here and must still override the defaults above. $DnsSuffix
        # in particular uses "" to mean "the primary domain suffix".
        if ($_p['TargetAlias'] -and $cfg.TargetAlias) { $TargetAlias = [string]$cfg.TargetAlias }
        if ($_p['EnableProfileReclassification']) { $EnableProfileReclassification = ConvertTo-ConfigBool $cfg.EnableProfileReclassification }
        if ($_p['EnableDnsRegistration'])         { $EnableDnsRegistration         = ConvertTo-ConfigBool $cfg.EnableDnsRegistration }
        if ($_p['DnsServerAddress'])              { $DnsServerAddress              = [string]$cfg.DnsServerAddress }
        if ($_p['DnsSuffix'])                     { $DnsSuffix                     = [string]$cfg.DnsSuffix }
        if ($_p['StateFile'])                     { $StateFile                     = [string]$cfg.StateFile }
        if ($_p['ForceRegisterAfterHours'])       { $ForceRegisterAfterHours       = [int]$cfg.ForceRegisterAfterHours }
        if ($_p['AdapterTimeoutSeconds'])         { $AdapterTimeoutSeconds         = [int]$cfg.AdapterTimeoutSeconds }
        if ($_p['PollIntervalSeconds'])           { $PollIntervalSeconds           = [int]$cfg.PollIntervalSeconds }
        if ($_p['VerifyRegistration'])            { $VerifyRegistration            = ConvertTo-ConfigBool $cfg.VerifyRegistration }
        if ($_p['VerifyTimeoutSeconds'])          { $VerifyTimeoutSeconds          = [int]$cfg.VerifyTimeoutSeconds }
        if ($_p['PostRegisterDelaySeconds'])      { $PostRegisterDelaySeconds      = [int]$cfg.PostRegisterDelaySeconds }
        if ($_p['LogFile'])                       { $LogFile                       = [string]$cfg.LogFile }
        if ($_p['MaxLogSizeBytes'])               { $MaxLogSizeBytes               = [long]$cfg.MaxLogSizeBytes }
        if ($_p['LogRetainedFiles'])              { $LogRetainedFiles              = [int]$cfg.LogRetainedFiles }
        if ($_p['DebugLogging'])                  { $DebugLogging                  = ConvertTo-ConfigBool $cfg.DebugLogging }

        $ConfigLoadedFrom = $_cfgPath
    }
    catch {
        # A bad value part-way down the list leaves the keys above it applied
        # and everything below it at its default, so log the settings actually
        # in effect rather than implying one or the other.
        $ConfigLoadError = "Config file '$_cfgPath' was not fully applied - fix the file, or check the settings below: $_"
    }
    break
}

Remove-Variable cfg, _p, _cfgPath, _cfgCandidates -ErrorAction SilentlyContinue

# A zero or negative poll interval turns every wait loop into a spin, so floor
# it here rather than trusting the file.
if ($PollIntervalSeconds -lt 1) { $PollIntervalSeconds = 1 }

# A negative retention count would run the rotation loop backwards; 0 is a valid
# setting and means "keep no copies".
if ($LogRetainedFiles -lt 0) { $LogRetainedFiles = 0 }

# Negative would make every stored registration look overdue, turning the
# refresh interval into "register every run".
if ($ForceRegisterAfterHours -lt 0) { $ForceRegisterAfterHours = 0 }

# =============================================================================
# SCRIPT INTERNALS - no changes needed below this line
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-LogEntry {
    param([string]$Message, [string]$Level)
    return "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
}

# Rotation is checked once per run rather than on every line: a run writes a
# couple of dozen entries, and stat-ing the file for each of them buys nothing.
# The consequence is that the file can overshoot $MaxLogSizeBytes by one run's
# worth of output before the next run trims it, which is a few hundred bytes.
$LogRotationChecked = $false

# Ages the log files off the end - the oldest copy is deleted, each remaining
# one moves up a number, and the live log becomes .1. Returns $null normally, or
# a formatted entry for the caller to log. Rotation failing is not fatal: the
# existing file is still there to append to and the next run tries again, so the
# failure is reported rather than thrown.
function Invoke-LogRotation {
    if ($MaxLogSizeBytes -le 0) { return $null }

    $current = Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue
    if (-not $current -or $current.Length -lt $MaxLogSizeBytes) { return $null }

    try {
        # A retention count lowered since the last rotation leaves copies above
        # it that nothing would ever move or delete again. Numbering is
        # contiguous, so stopping at the first gap clears all of them.
        $orphan = $LogRetainedFiles + 1
        while (Test-Path -LiteralPath "$LogFile.$orphan") {
            Remove-Item -LiteralPath "$LogFile.$orphan" -Force
            $orphan++
        }

        # Highest number first, so each slot is free before the file below it
        # moves into it.
        for ($i = $LogRetainedFiles; $i -ge 1; $i--) {
            $archive = "$LogFile.$i"
            if (-not (Test-Path -LiteralPath $archive)) { continue }
            if ($i -eq $LogRetainedFiles) { Remove-Item -LiteralPath $archive -Force }
            else { Move-Item -LiteralPath $archive -Destination "$LogFile.$($i + 1)" -Force }
        }

        if ($LogRetainedFiles -ge 1) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
            return (New-LogEntry "Rotated previous log ($($current.Length) bytes) to '$LogFile.1'" "INFO")
        }

        Remove-Item -LiteralPath $LogFile -Force
        return (New-LogEntry "Discarded previous log ($($current.Length) bytes) - LogRetainedFiles is 0" "INFO")
    }
    catch {
        # Usually a second instance of this script holding the file open - the
        # trigger event can fire twice in quick succession - or the log open in
        # a viewer.
        return (New-LogEntry "Could not rotate log file: $_" "WARN")
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","DEBUG")][string]$Level = "INFO"
    )
    $entry = New-LogEntry $Message $Level
    Write-Host $entry
    if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
    try {
        $logDir = Split-Path $LogFile -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Flag first, so a rotation that throws unexpectedly is not retried on
        # every subsequent line.
        $rotationNote = $null
        if (-not $script:LogRotationChecked) {
            $script:LogRotationChecked = $true
            $rotationNote = Invoke-LogRotation
        }

        Add-Content -Path $LogFile -Value $entry -Encoding UTF8

        # After the entry, so the rotated file's last line and the new file's
        # first line are both real script output rather than bookkeeping.
        if ($rotationNote) {
            Write-Host $rotationNote
            Add-Content -Path $LogFile -Value $rotationNote -Encoding UTF8
        }
    }
    catch {
        Write-Host "[WARN] Could not write to log file: $_"
    }
}

# ---------------------------------------------------------------------------
# Debug logging
# ---------------------------------------------------------------------------
# Every run stamps its own start time so the DNS Client event probe below can
# ask for "events from this run" rather than trawling the whole System log.
$ScriptStartTime = Get-Date

function Write-DebugLog {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $DebugLogging) { return }
    Write-Log $Message "DEBUG"
}

# Runs one diagnostic and logs whatever it produced, one indented line per
# result. Diagnostics are never load-bearing - a cmdlet missing on this host, an
# adapter that disappeared mid-run, or a probe that simply times out must not
# take the run down with it - so the failure is contained here and reported as
# part of the debug output.
function Write-DebugProbe {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Probe
    )
    if (-not $DebugLogging) { return }

    try {
        $lines = @(& $Probe | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        if ($lines.Count -eq 0) {
            Write-DebugLog "${Label}: (no data)"
            return
        }
        Write-DebugLog "${Label}:"
        foreach ($line in $lines) { Write-DebugLog "    $line" }
    }
    catch {
        # Flattened: a multi-line cmdlet error would otherwise put untimestamped
        # continuation lines in the middle of the log.
        Write-DebugLog "${Label}: could not be collected: $(([string]$_ -replace '\s+', ' ').Trim())"
    }
}

# Who and what is running - the first thing to check when a run behaves
# differently on one machine than on the bench.
function Write-EnvironmentDebug {
    if (-not $DebugLogging) { return }

    Write-DebugProbe "Host" {
        $os     = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $osText = if ($os) { "$($os.Caption) build $($os.BuildNumber)" } else { "unknown" }
        $ipProps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()

        "Computer=$env:COMPUTERNAME RunningAs=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        "PowerShell=$($PSVersionTable.PSVersion) OS=$osText"
        "PrimaryDnsSuffix='$($ipProps.DomainName)'"
    }
}

# State of the tunnel adapter itself. $Stage names the point in the run, so a
# log read after the fact shows what each step actually changed.
function Write-AdapterDebug {
    param([Parameter(Mandatory)][string]$Stage)
    if (-not $DebugLogging) { return }

    Write-DebugProbe "Adapter '$TargetAlias' [$Stage]" {
        Get-NetAdapter -Name $TargetAlias -ErrorAction SilentlyContinue | ForEach-Object {
            "Status=$($_.Status) ifIndex=$($_.InterfaceIndex) Description='$($_.InterfaceDescription)'"
        }
        Get-NetIPAddress -InterfaceAlias $TargetAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
            "IPv4 $($_.IPAddress)/$($_.PrefixLength) State=$($_.AddressState) Origin=$($_.PrefixOrigin)/$($_.SuffixOrigin)"
        }
        Get-NetIPInterface -InterfaceAlias $TargetAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
            "InterfaceMetric=$($_.InterfaceMetric) AutomaticMetric=$($_.AutomaticMetric) Dhcp=$($_.Dhcp) ConnectionState=$($_.ConnectionState)"
        }
        Get-DnsClientServerAddress -InterfaceAlias $TargetAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.ServerAddresses) { "DnsServers=$($_.ServerAddresses -join ', ')" } else { "DnsServers=(none)" }
        }
        Get-DnsClient -InterfaceAlias $TargetAlias -ErrorAction SilentlyContinue | ForEach-Object {
            "ConnectionSpecificSuffix='$($_.ConnectionSpecificSuffix)' " +
            "RegisterThisConnectionsAddress=$($_.RegisterThisConnectionsAddress) " +
            "UseSuffixWhenRegistering=$($_.UseSuffixWhenRegistering)"
        }
    }
}

# Why an update might not be reaching the DNS server. Register-DnsClient is
# machine-wide and the resolver picks a server by interface metric, so the
# question is never just "is the DNS server up" - it is which interface the
# traffic leaves by, and whether the machine can do Kerberos to it as well.
function Write-DnsPathDebug {
    param([string]$Fqdn)
    if (-not $DebugLogging) { return }

    Write-DebugProbe "DNS servers on all interfaces" {
        Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses } |
            ForEach-Object { "$($_.InterfaceAlias) (metric-ordered by the resolver): $($_.ServerAddresses -join ', ')" }
    }

    if ([string]::IsNullOrWhiteSpace($DnsServerAddress)) { return }

    # The single most useful line in a failed run: if the source address is the
    # home NIC rather than the tunnel, the update never entered the tunnel and
    # nothing on the DNS side is at fault.
    Write-DebugProbe "Route to $DnsServerAddress" {
        Find-NetRoute -RemoteIPAddress $DnsServerAddress -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties['IPAddress'] } |
            ForEach-Object { "source $($_.IPAddress) via '$($_.InterfaceAlias)' (ifIndex $($_.InterfaceIndex))" }
    }

    # Secure dynamic update is GSS-TSIG, so the update needs Kerberos to the
    # domain controller as well as DNS itself. A machine that resolves names
    # perfectly but cannot reach 88 fails the update with nothing obviously
    # wrong on the DNS side.
    foreach ($port in 53, 88) {
        Write-DebugProbe "TCP $port to $DnsServerAddress" {
            $reachable = Test-NetConnection -ComputerName $DnsServerAddress -Port $port `
                             -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($reachable) { "reachable" } else { "NOT reachable - the update cannot complete" }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Fqdn)) { return }

    # The client looks up the SOA to find the zone's primary before it sends the
    # update, so a failure here is a failure of the whole registration.
    $zone = $Fqdn.Substring($Fqdn.IndexOf('.') + 1)
    Write-DebugProbe "SOA for '$zone' from $DnsServerAddress" {
        Resolve-DnsName -Name $zone -Type SOA -Server $DnsServerAddress -DnsOnly -NoHostsFile -ErrorAction Stop |
            ForEach-Object {
                $primary = if ($_.PSObject.Properties['PrimaryServer']) { $_.PrimaryServer } else { "" }
                "$($_.Name) $($_.Type) $primary"
            }
    }

    Write-DebugProbe "Current A records for $Fqdn on $DnsServerAddress" {
        Resolve-DnsName -Name $Fqdn -Type A -Server $DnsServerAddress -DnsOnly -NoHostsFile -ErrorAction Stop |
            Where-Object { $_.Type -eq 'A' } |
            ForEach-Object { "$($_.Name) -> $($_.IPAddress) (TTL $($_.TTL))" }
    }
}

# Register-DnsClient returns success as soon as the DNS Client service accepts
# the request and never reports what happened next. The service does, in the
# System log - event 8018 and its neighbours carry the actual reason (server
# refused the update, no domain controller, timeout).
function Write-DnsClientEventDebug {
    param([Parameter(Mandatory)][datetime]$Since)
    if (-not $DebugLogging) { return }

    Write-DebugProbe "DNS Client events since $($Since.ToString('HH:mm:ss'))" {
        # Queried one provider at a time on purpose. The registration events
        # moved provider across Windows versions, and naming one that does not
        # write to the System log on this host fails the whole query rather than
        # being ignored - which would cost the events from the one that does.
        $events = @()
        foreach ($provider in 'Microsoft-Windows-DNS-Client', 'DnsApi') {
            try {
                $events += Get-WinEvent -FilterHashtable @{
                                LogName      = 'System'
                                ProviderName = $provider
                                StartTime    = $Since
                            } -MaxEvents 20 -ErrorAction SilentlyContinue
            }
            catch { }
        }

        $events | Sort-Object TimeCreated | ForEach-Object {
            $text = ([string]$_.Message -replace '\s+', ' ').Trim()
            if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + "..." }
            "[$($_.TimeCreated.ToString('HH:mm:ss'))] $($_.LevelDisplayName) id=$($_.Id) $text"
        }
    }
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
# Set-NetConnectionProfile and Set-DnsClientServerAddress are both CIM calls
# that require administrator rights. Without them they fail with "Access to a
# CIM resource was not available to the client", which says nothing about the
# actual cause, so check up front and name it. SYSTEM - how the scheduled task
# runs this - is a member of Administrators, so this passes in normal use and
# only trips when someone runs the script by hand from an ordinary console.
function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Adapter readiness
# ---------------------------------------------------------------------------
# Returns the adapter's usable IPv4 address, or $null if it never appears
# within the timeout. APIPA and unspecified addresses do not count as usable,
# and the address must be Preferred rather than Tentative or Deprecated.
function Wait-ForTunnelAddress {
    $deadline = (Get-Date).AddSeconds($AdapterTimeoutSeconds)
    $waited   = 0
    while ($true) {
        $addr = Get-NetIPAddress -InterfaceAlias $TargetAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.AddressState -eq 'Preferred' -and
                        $_.IPAddress -notlike '169.254.*' -and
                        $_.IPAddress -ne '0.0.0.0'
                    } |
                    Select-Object -First 1

        if ($addr) {
            if ($waited -gt 0) { Write-Log "Adapter '$TargetAlias' ready after ${waited}s" }
            return $addr.IPAddress
        }

        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
    }
}

# ---------------------------------------------------------------------------
# Job 1 - network category
# ---------------------------------------------------------------------------
# Windows has three categories and two of them already give this job what it
# exists to achieve: Private and DomainAuthenticated both put the adapter on a
# firewall profile permissive enough for the inbound traffic the tunnel carries.
# Only Public needs fixing.
#
# DomainAuthenticated in particular must be left alone rather than treated as
# wrong. It is assigned by NLA when it can authenticate a domain controller over
# the adapter - which does happen on the tunnel - and it cannot be set back by
# script in any case: Set-NetConnectionProfile -NetworkCategory accepts Public
# and Private only. Trying would log an error on every single run that nothing
# could ever clear.
$AcceptableNetworkCategories = @("Private", "DomainAuthenticated")

function Set-TunnelProfileCategory {
    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceAlias -eq $TargetAlias }

    if (-not $profiles) {
        Write-Log "No network connection profile found for '$TargetAlias'" "WARN"
        return
    }

    foreach ($connectprofile in $profiles) {
        # Compared as a string: NetworkCategory is an enum, and the acceptable
        # list has to stay readable in the log line below either way.
        $category = [string]$connectprofile.NetworkCategory

        Write-DebugLog ("Profile '$($connectprofile.Name)' on '$($connectprofile.InterfaceAlias)': " +
                        "NetworkCategory=$category IPv4Connectivity=$($connectprofile.IPv4Connectivity) " +
                        "IPv6Connectivity=$($connectprofile.IPv6Connectivity)")

        if ($AcceptableNetworkCategories -contains $category) {
            Write-Log "'$TargetAlias' is classified $category - no change needed"
            continue
        }

        try {
            Write-Log "Reclassifying '$TargetAlias' from $category to Private"
            Set-NetConnectionProfile -InterfaceAlias $connectprofile.InterfaceAlias -NetworkCategory Private
        }
        catch {
            Write-Log "Failed to reclassify '$TargetAlias': $_" "ERROR"
        }
    }
}

# ---------------------------------------------------------------------------
# Job 2 - dynamic DNS registration
# ---------------------------------------------------------------------------
# Name the record will be registered under, used only for verification.
function Get-RegistrationFqdn {
    if ($DnsSuffix) { return "$env:COMPUTERNAME.$DnsSuffix" }
    $domain = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
    if ([string]::IsNullOrWhiteSpace($domain)) { return $null }
    return "$env:COMPUTERNAME.$domain"
}

function Test-RegistrationLanded {
    param([string]$Fqdn, [string]$ExpectedIp)
    $deadline = (Get-Date).AddSeconds($VerifyTimeoutSeconds)
    $attempt  = 0
    while ($true) {
        $attempt++
        try {
            $answers = Resolve-DnsName -Name $Fqdn -Type A -Server $DnsServerAddress `
                           -DnsOnly -NoHostsFile -ErrorAction SilentlyContinue
            if ($answers) {
                $ips = @($answers | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
                if ($ips -contains $ExpectedIp) {
                    Write-Log "Verified: $Fqdn resolves to $ExpectedIp on $DnsServerAddress"
                    return $true
                }
                if ($ips.Count -gt 0) {
                    Write-Log "  $Fqdn currently $($ips -join ', ') - waiting for $ExpectedIp"
                }
                else {
                    # An answer with no A record in it - usually a CNAME or the
                    # SOA of a zone that exists but holds no such name.
                    Write-DebugLog ("  Attempt ${attempt}: answer carried no A record " +
                                    "(types: $(($answers | ForEach-Object { $_.Type }) -join ', '))")
                }
            }
            else {
                Write-DebugLog "  Attempt ${attempt}: no answer for $Fqdn from $DnsServerAddress yet"
            }
        }
        catch {
            Write-Log "  Verification lookup failed: $_" "WARN"
            Write-DebugLog "  Attempt ${attempt}: $($_.Exception.GetType().Name) - $($_.Exception.Message)"
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

# ---------------------------------------------------------------------------
# Registration state
# ---------------------------------------------------------------------------
# What was last registered, or $null when there is nothing usable on disk. Any
# problem reading the file resolves to $null - re-registering costs one update,
# whereas trusting a half-read file could suppress a needed one.
function Get-RegistrationState {
    if ([string]::IsNullOrWhiteSpace($StateFile)) { return $null }
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }

    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $props = $raw.PSObject.Properties
        if (-not ($props['IPAddress'] -and $props['Fqdn'] -and $props['LastRegistered'])) {
            Write-Log "State file '$StateFile' is missing fields - treating as no previous registration" "WARN"
            return $null
        }
        # ConvertFrom-Json turns an ISO 8601 string into a [datetime] on its own,
        # so the stamp arrives already converted on some hosts and as a string on
        # others. Re-parsing a [datetime] would stringify it in the current
        # culture first, dropping the UTC marker and shifting the value by the
        # local offset - which reads as a registration in the future.
        $stamp = $raw.LastRegistered
        if ($stamp -is [datetime]) {
            $lastRegistered = $stamp.ToUniversalTime()
        }
        else {
            $lastRegistered = [datetime]::Parse([string]$stamp, [cultureinfo]::InvariantCulture,
                                  [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }

        Write-DebugLog ("State file '$StateFile': Fqdn=$($raw.Fqdn) IPAddress=$($raw.IPAddress) " +
                        "LastRegistered=$($lastRegistered.ToString('o'))")

        return [pscustomobject]@{
            IPAddress      = [string]$raw.IPAddress
            Fqdn           = [string]$raw.Fqdn
            LastRegistered = $lastRegistered
        }
    }
    catch {
        Write-Log "Could not read state file '$StateFile' - treating as no previous registration: $_" "WARN"
        return $null
    }
}

# Only ever called after a registration the script is confident in, so a stored
# entry means "this name really did resolve to this address".
function Save-RegistrationState {
    param([string]$Fqdn, [string]$IPAddress)
    if ([string]::IsNullOrWhiteSpace($StateFile)) { return }

    try {
        $stateDir = Split-Path $StateFile -Parent
        if ($stateDir -and -not (Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        [pscustomobject]@{
            IPAddress      = $IPAddress
            Fqdn           = $Fqdn
            LastRegistered = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    }
    catch {
        # Not worth failing the run over - the cost of a lost state file is one
        # redundant registration on the next trigger.
        Write-Log "Could not write state file '$StateFile': $_" "WARN"
    }
}

function Test-RegistrationRequired {
    param([string]$Fqdn, [string]$IPAddress)

    $state = Get-RegistrationState
    if (-not $state) {
        Write-Log "No previous registration recorded - registering"
        return $true
    }

    if ($state.Fqdn -ne $Fqdn) {
        Write-Log "Registration name changed ('$($state.Fqdn)' -> '$Fqdn') - registering"
        return $true
    }

    if ($state.IPAddress -ne $IPAddress) {
        Write-Log "Tunnel address changed ($($state.IPAddress) -> $IPAddress) - registering"
        return $true
    }

    $age = (Get-Date).ToUniversalTime() - $state.LastRegistered

    # A state file stamped in the future means the clock moved backwards since
    # it was written. Left alone the record would never look due again.
    if ($age.TotalHours -lt 0) {
        Write-Log "State file is stamped in the future (clock change?) - registering" "WARN"
        return $true
    }

    if ($ForceRegisterAfterHours -gt 0 -and $age.TotalHours -ge $ForceRegisterAfterHours) {
        Write-Log ("Address unchanged but last registered {0:N1}h ago (refresh interval {1}h) - re-registering" -f `
                   $age.TotalHours, $ForceRegisterAfterHours)
        return $true
    }

    Write-Log ("$Fqdn already registered as $IPAddress {0:N1}h ago - skipping DNS registration" -f $age.TotalHours)
    return $false
}

function Register-TunnelAddress {
    param([Parameter(Mandatory)][string]$IPAddress)

    if ([string]::IsNullOrWhiteSpace($DnsServerAddress)) {
        Write-Log "DnsRegistration enabled but DnsServerAddress is empty - skipping" "ERROR"
        return
    }

    $fqdn = Get-RegistrationFqdn
    if (-not $fqdn) {
        Write-Log "Could not determine a registration FQDN (machine has no primary DNS suffix and DnsSuffix is unset) - skipping" "ERROR"
        return
    }

    # Decided before anything touches the adapter: an unchanged address needs no
    # update, and the DNS server juggling below is not free either.
    if (-not (Test-RegistrationRequired -Fqdn $fqdn -IPAddress $IPAddress)) { return }

    Write-Log "Registering $fqdn -> $IPAddress via $DnsServerAddress"

    # Collected before anything is changed, so a failed run shows the state the
    # registration was attempted from rather than the state it was left in.
    Write-AdapterDebug "before registration"
    Write-DnsPathDebug -Fqdn $fqdn

    # Only reset an address that was actually applied. If the apply itself
    # failed there is nothing pinned to the adapter, and resetting anyway just
    # fails a second time and buries the real error under a follow-on one.
    $dnsServerApplied = $false

    # Recorded only on success, so a failed run is retried on the next trigger
    # instead of being skipped as "already registered".
    $registered = $false

    try {
        # The DNS server address is applied to the tunnel adapter only for the
        # duration of the update, so the resolver sends the SOA lookup and the
        # update itself through the tunnel instead of out the physical NIC.
        Set-DnsClientServerAddress -InterfaceAlias $TargetAlias -ServerAddresses $DnsServerAddress
        $dnsServerApplied = $true
        Write-Log "  Applied DNS server $DnsServerAddress to '$TargetAlias'"

        if ($DnsSuffix) {
            Set-DnsClient -InterfaceAlias $TargetAlias `
                -ConnectionSpecificSuffix $DnsSuffix `
                -UseSuffixWhenRegistering $true `
                -RegisterThisConnectionsAddress $true
            Write-Log "  Connection-specific suffix set to '$DnsSuffix'"
        }
        else {
            Set-DnsClient -InterfaceAlias $TargetAlias -RegisterThisConnectionsAddress $true
        }

        Write-AdapterDebug "DNS server applied"

        # Only events from here on describe this registration attempt - anything
        # earlier belongs to whatever the DNS Client service was doing before.
        $submittedAt = Get-Date

        Register-DnsClient
        Write-Log "  Registration submitted"

        # Verify before the finally block strips the DNS server back off -
        # Register-DnsClient is asynchronous, and pulling the server address
        # too early can cut the update off before it is sent.
        if ($VerifyRegistration) {
            if (Test-RegistrationLanded -Fqdn $fqdn -ExpectedIp $IPAddress) {
                $registered = $true
            }
            else {
                Write-Log "Registration not visible on $DnsServerAddress after ${VerifyTimeoutSeconds}s. Check that the DNS server is reachable through the tunnel and that the zone accepts secure dynamic updates." "WARN"
                if (-not $DebugLogging) {
                    Write-Log "  Set DebugLogging to true in the config file and reproduce for the detail behind this." "WARN"
                }
            }
        }
        else {
            Start-Sleep -Seconds $PostRegisterDelaySeconds
            # Nothing confirmed it landed - with verification off, "submitted
            # without error" is the strongest signal available.
            $registered = $true
        }

        # After verification either way: the service writes its result some time
        # after Register-DnsClient returns, so asking earlier finds nothing.
        Write-DnsClientEventDebug -Since $submittedAt
    }
    catch {
        Write-Log "Dynamic DNS registration failed: $_" "ERROR"
        Write-DebugLog "  $($_.Exception.GetType().Name) at $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
        Write-DnsClientEventDebug -Since $ScriptStartTime
    }
    finally {
        # Always hand the adapter back once it was taken, even on failure -
        # leaving an internal DNS server pinned to the tunnel adapter would
        # affect all name resolution on the machine once the tunnel drops.
        if ($dnsServerApplied) {
            try {
                Set-DnsClientServerAddress -InterfaceAlias $TargetAlias -ResetServerAddresses
                Write-Log "  Removed DNS server from '$TargetAlias'"
            }
            catch {
                Write-Log "Could not remove DNS server from '$TargetAlias': $_" "ERROR"
            }
        }
    }

    # After the finally block, so the adapter is always handed back first.
    if ($registered) { Save-RegistrationState -Fqdn $fqdn -IPAddress $IPAddress }
}

# =============================================================================
# MAIN
# =============================================================================
Write-Log "=== ZVPN connection profile script starting (adapter: '$TargetAlias') ==="

# Deferred from the config block above, which runs before Write-Log exists.
if ($ConfigLoadError)       { Write-Log $ConfigLoadError "WARN" }
elseif ($ConfigLoadedFrom)  { Write-Log "Configuration loaded from '$ConfigLoadedFrom'" }
else                        { Write-Log "No config file found - using in-script defaults" }

# Nothing about this runs interactively, so state what is actually in effect.
Write-Log ("Settings: Reclassify=$EnableProfileReclassification DnsRegistration=$EnableDnsRegistration " +
           "DnsServer='$DnsServerAddress' DnsSuffix='$DnsSuffix' AdapterTimeout=${AdapterTimeoutSeconds}s " +
           "Poll=${PollIntervalSeconds}s Verify=$VerifyRegistration Timeout=${VerifyTimeoutSeconds}s " +
           "MaxLogSize=${MaxLogSizeBytes}B LogRetained=$LogRetainedFiles Debug=$DebugLogging " +
           "StateFile='$StateFile' ForceRegisterAfter=${ForceRegisterAfterHours}h")

Write-EnvironmentDebug

try {
    # Inside the try so an unexpected failure in the check itself still gets
    # logged rather than ending the run silently.
    if (-not (Test-Elevated)) {
        Write-Log ("Not running elevated - both jobs need administrator rights and would fail with " +
                   "'Access to a CIM resource was not available to the client'. The GPO scheduled task " +
                   "runs as SYSTEM; to run this by hand, start PowerShell with 'Run as administrator'.") "ERROR"
        exit 1
    }

    $tunnelIp = Wait-ForTunnelAddress
    if (-not $tunnelIp) {
        Write-Log "Adapter '$TargetAlias' had no usable IPv4 address after ${AdapterTimeoutSeconds}s - nothing to do" "WARN"
        exit 0
    }
    Write-Log "Adapter '$TargetAlias' has address $tunnelIp"
    Write-AdapterDebug "adapter ready"

    if ($EnableProfileReclassification) { Set-TunnelProfileCategory }
    else { Write-Log "Profile reclassification disabled - skipping" }

    if ($EnableDnsRegistration) { Register-TunnelAddress -IPAddress $tunnelIp }
    else { Write-Log "Dynamic DNS registration disabled - skipping" }

    Write-Log "=== ZVPN connection profile script finished ==="
}
catch {
    Write-Log "=== ZVPN connection profile script FAILED: $_ ===" "ERROR"
    exit 1
}
