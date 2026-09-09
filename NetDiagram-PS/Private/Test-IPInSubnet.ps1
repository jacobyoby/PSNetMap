function Test-IPInSubnet {
    <#
    .SYNOPSIS
        Simple CIDR matching helper
    #>
    param([string]$IP, [string]$CIDR)

    if ([string]::IsNullOrWhiteSpace($IP) -or [string]::IsNullOrWhiteSpace($CIDR)) {
        return $false
    }

    if ($CIDR -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})$') {
        return $false
    }

    $networkAddressString = $matches[1]
    $prefixLength = [int]$matches[2]

    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        return $false
    }

    try {
        $ipAddress = [System.Net.IPAddress]::Parse($IP)
        $networkAddress = [System.Net.IPAddress]::Parse($networkAddressString)
    }
    catch {
        return $false
    }

    if ($ipAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $networkAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $ipBytes = $ipAddress.GetAddressBytes()
    $networkBytes = $networkAddress.GetAddressBytes()

    if ([System.BitConverter]::IsLittleEndian) {
        [Array]::Reverse($ipBytes)
        [Array]::Reverse($networkBytes)
    }

    $ipValue = [System.BitConverter]::ToUInt32($ipBytes, 0)
    $networkValue = [System.BitConverter]::ToUInt32($networkBytes, 0)

    # Build the prefix mask. Compute in UInt64 to avoid the int overflow that
    # '[uint32]0xFFFFFFFF -shl n' triggers (0xFFFFFFFF parses as int -1), then
    # truncate back to 32 bits.
    $mask = if ($prefixLength -eq 0) {
        [uint32]0
    }
    else {
        [uint32]((([uint64]4294967295) -shl (32 - $prefixLength)) -band [uint64]4294967295)
    }

    return (($ipValue -band $mask) -eq ($networkValue -band $mask))
}
