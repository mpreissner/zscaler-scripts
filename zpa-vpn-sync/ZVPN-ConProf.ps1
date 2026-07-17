$targetAlias = "Zscaler Tunnel"

$profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object {
    $_.InterfaceAlias -eq $targetAlias
}

foreach ($connectprofile in $profiles) {
    if ($connectprofile.NetworkCategory -ne "Private") {
        Set-NetConnectionProfile -InterfaceAlias $profile.InterfaceAlias -NetworkCategory Private
    }
}