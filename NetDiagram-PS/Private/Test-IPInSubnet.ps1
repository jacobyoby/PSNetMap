function Test-IPInSubnet {
    <#
    .SYNOPSIS
        CIDR matching helper for both IPv4 and IPv6
    .DESCRIPTION
        Returns true when Address falls within the network defined by CIDR.
        Mixed address families (v4 address against v6 CIDR or vice versa)
        return false without throwing.
    #>
    param([string]$IP, [string]$CIDR)

    if ([string]::IsNullOrWhiteSpace($IP) -or [string]::IsNullOrWhiteSpace($CIDR)) {
        return $false
    }

    # Split CIDR into network address and prefix length. Accept both IPv4 and
    # IPv6 CIDR notation (e.g. '10.0.0.0/8' or '2001:db8::/32').
    $cidrParts = $CIDR -split '/'
    if ($cidrParts.Count -ne 2) {
        return $false
    }

    $networkAddressString = $cidrParts[0]
    $prefixLength = 0
    if (-not [int]::TryParse($cidrParts[1], [ref]$prefixLength)) {
        return $false
    }

    try {
        $ipAddress = [System.Net.IPAddress]::Parse($IP)
        $networkAddress = [System.Net.IPAddress]::Parse($networkAddressString)
    }
    catch {
        return $false
    }

    # Mixed families never match — return false, never throw.
    if ($ipAddress.AddressFamily -ne $networkAddress.AddressFamily) {
        return $false
    }

    # Validate prefix length for the address family.
    $maxPrefix = if ($ipAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
    if ($prefixLength -lt 0 -or $prefixLength -gt $maxPrefix) {
        return $false
    }

    # Compare bytes up to prefix length.
    $ipBytes = $ipAddress.GetAddressBytes()
    $networkBytes = $networkAddress.GetAddressBytes()

    $fullBytes = [math]::Floor($prefixLength / 8)
    $remainBits = $prefixLength % 8

    for ($i = 0; $i -lt $fullBytes; $i++) {
        if ($ipBytes[$i] -ne $networkBytes[$i]) { return $false }
    }
    if ($remainBits -gt 0) {
        $mask = 0xFF -shl (8 - $remainBits)
        if (($ipBytes[$fullBytes] -band $mask) -ne ($networkBytes[$fullBytes] -band $mask)) { return $false }
    }
    return $true
}
