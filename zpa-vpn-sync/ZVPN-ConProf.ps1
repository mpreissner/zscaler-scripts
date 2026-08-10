# =============================================================================
# ZVPN-ConProf.ps1
#
# Runs on the client when the Zscaler Tunnel adapter comes up. Two independent
# jobs, each separately switchable:
#
#   1. Reclassify the "Zscaler Tunnel" adapter as a Private network so Windows
#      Firewall stops dropping inbound connections over the tunnel.
#   2. Register the adapter's tunnel IP in AD DNS using Windows' own dynamic
#      update mechanism, so the record is owned by the computer account and the
#      machine can update it itself when it returns on-prem.
#
# Deployed via GPO and triggered by Event ID 10000 in the
# Microsoft-Windows-NetworkProfile/Operational log. See ZVPN-SchedTaskConfig.txt.
#
# Runs as SYSTEM — Set-DnsClientServerAddress and Set-NetConnectionProfile both
# require elevation.
# =============================================================================


# =============================================================================
# USER CONFIGURATION
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
# the resolver picks a server by interface metric — off-net that is typically
# the user's home router or their ISP, which will not accept or forward the
# update. This address is set on the adapter only for the duration of the
# registration and removed again afterwards.
#
# It must be reachable through the tunnel: the DNS server has to be published
# as a ZPA application segment, or the update never leaves the machine.
$DnsServerAddress = "10.10.10.10"

# Connection-specific DNS suffix to register the tunnel IP under.
#
#   ""                  Register as <hostname>.<primary domain suffix> — the
#                       machine's normal AD name. The tunnel IP then competes
#                       with the LAN A record in the primary zone.
#   "vpn.corp.local"    Register as <hostname>.vpn.corp.local, keeping VPN
#                       addresses in a dedicated zone. Match this to $DnsZone
#                       in zpa-dns-sync-oneapi.ps1 if you run both.
$DnsSuffix = ""

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
# only — note that a GPO scheduled task running as SYSTEM has nowhere to show
# stdout, so a file is strongly recommended.
$LogFile = "C:\ProgramData\zpa-vpn-sync\zvpn-conprof.log"

# =============================================================================
# SCRIPT INTERNALS — no changes needed below this line
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO"
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $entry
    if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
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
# Job 1 — network category
# ---------------------------------------------------------------------------
function Set-TunnelProfilePrivate {
    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                    Where-Object { $_.InterfaceAlias -eq $TargetAlias }

    if (-not $profiles) {
        Write-Log "No network connection profile found for '$TargetAlias'" "WARN"
        return
    }

    foreach ($connectprofile in $profiles) {
        if ($connectprofile.NetworkCategory -eq "Private") {
            Write-Log "'$TargetAlias' already classified Private — no change"
            continue
        }
        try {
            Write-Log "Reclassifying '$TargetAlias' from $($connectprofile.NetworkCategory) to Private"
            Set-NetConnectionProfile -InterfaceAlias $connectprofile.InterfaceAlias -NetworkCategory Private
        }
        catch {
            Write-Log "Failed to reclassify '$TargetAlias': $_" "ERROR"
        }
    }
}

# ---------------------------------------------------------------------------
# Job 2 — dynamic DNS registration
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
    while ($true) {
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
                    Write-Log "  $Fqdn currently $($ips -join ', ') — waiting for $ExpectedIp"
                }
            }
        }
        catch {
            Write-Log "  Verification lookup failed: $_" "WARN"
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

function Register-TunnelAddress {
    param([Parameter(Mandatory)][string]$IPAddress)

    if ([string]::IsNullOrWhiteSpace($DnsServerAddress)) {
        Write-Log "DnsRegistration enabled but DnsServerAddress is empty — skipping" "ERROR"
        return
    }

    $fqdn = Get-RegistrationFqdn
    if (-not $fqdn) {
        Write-Log "Could not determine a registration FQDN (machine has no primary DNS suffix and DnsSuffix is unset) — skipping" "ERROR"
        return
    }

    Write-Log "Registering $fqdn -> $IPAddress via $DnsServerAddress"

    try {
        # The DNS server address is applied to the tunnel adapter only for the
        # duration of the update, so the resolver sends the SOA lookup and the
        # update itself through the tunnel instead of out the physical NIC.
        Set-DnsClientServerAddress -InterfaceAlias $TargetAlias -ServerAddresses $DnsServerAddress
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

        Register-DnsClient
        Write-Log "  Registration submitted"

        # Verify before the finally block strips the DNS server back off —
        # Register-DnsClient is asynchronous, and pulling the server address
        # too early can cut the update off before it is sent.
        if ($VerifyRegistration) {
            if (-not (Test-RegistrationLanded -Fqdn $fqdn -ExpectedIp $IPAddress)) {
                Write-Log "Registration not visible on $DnsServerAddress after ${VerifyTimeoutSeconds}s. Check that the DNS server is reachable through the tunnel and that the zone accepts secure dynamic updates." "WARN"
            }
        }
        else {
            Start-Sleep -Seconds $PostRegisterDelaySeconds
        }
    }
    catch {
        Write-Log "Dynamic DNS registration failed: $_" "ERROR"
    }
    finally {
        # Always hand the adapter back, even on failure — leaving an internal
        # DNS server pinned to the tunnel adapter would affect all name
        # resolution on the machine once the tunnel drops.
        try {
            Set-DnsClientServerAddress -InterfaceAlias $TargetAlias -ResetServerAddresses
            Write-Log "  Removed DNS server from '$TargetAlias'"
        }
        catch {
            Write-Log "Could not remove DNS server from '$TargetAlias': $_" "ERROR"
        }
    }
}

# =============================================================================
# MAIN
# =============================================================================
Write-Log "=== ZVPN connection profile script starting (adapter: '$TargetAlias') ==="

try {
    $tunnelIp = Wait-ForTunnelAddress
    if (-not $tunnelIp) {
        Write-Log "Adapter '$TargetAlias' had no usable IPv4 address after ${AdapterTimeoutSeconds}s — nothing to do" "WARN"
        exit 0
    }
    Write-Log "Adapter '$TargetAlias' has address $tunnelIp"

    if ($EnableProfileReclassification) { Set-TunnelProfilePrivate }
    else { Write-Log "Profile reclassification disabled — skipping" }

    if ($EnableDnsRegistration) { Register-TunnelAddress -IPAddress $tunnelIp }
    else { Write-Log "Dynamic DNS registration disabled — skipping" }

    Write-Log "=== ZVPN connection profile script finished ==="
}
catch {
    Write-Log "=== ZVPN connection profile script FAILED: $_ ===" "ERROR"
    exit 1
}
