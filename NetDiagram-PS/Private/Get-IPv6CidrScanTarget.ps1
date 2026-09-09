function Get-IPv6CidrScanTarget {
    <#
    .SYNOPSIS
        Enumerate IPv6 addresses for a small CIDR (prefix /120 or longer).
    .DESCRIPTION
        IPv6 prefixes shorter than /120 — including a typical LAN /64 — are rejected
        with an actionable error. A /64 is 2^64 addresses and must not be swept; use
        Get-LocalARPTable (ND/ARP) for neighbor-assisted discovery instead.
        Quick samples up to 8 addresses, Medium the first 50, Full all hosts up to 256
        (the /120 cap). Host bits must already be cleared on NetworkAddress.
    #>
    param(
        [Parameter(Mandatory)][string]$NetworkAddress,
        [Parameter(Mandatory)][int]$PrefixLength,
        [ValidateSet('Quick', 'Medium', 'Full')][string]$ScanDepth = 'Quick',
        [int]$MinPrefixLength = 120,
        [int]$MaxScanHosts = 256
    )

    if ($PrefixLength -lt $MinPrefixLength -or $PrefixLength -gt 128) {
        $hostBits = 128 - $PrefixLength
        throw "IPv6 CIDR '$NetworkAddress/$PrefixLength' (/$PrefixLength) is too large to sweep (2^$hostBits addresses). Do not sweep a /64 or other large prefix. Use a CIDR of /$MinPrefixLength or longer (at most $MaxScanHosts hosts), or discover IPv6 hosts from the local neighbor table with Get-LocalARPTable (ND/ARP) instead of a CIDR sweep."
    }

    $hostCount = [int][Math]::Pow(2, 128 - $PrefixLength)
    $baseBytes = ([System.Net.IPAddress]::Parse($NetworkAddress)).GetAddressBytes()
    if ($baseBytes.Count -ne 16) {
        throw "Get-IPv6CidrScanTarget expected an IPv6 network address, got '$NetworkAddress'."
    }

    $limit = switch ($ScanDepth) {
        'Quick'  { [int][Math]::Min(8, $hostCount) }
        'Medium' { [int][Math]::Min(50, $hostCount) }
        default  { [int][Math]::Min($MaxScanHosts, $hostCount) }
    }

    $targets = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $limit; $i++) {
        $offset = if ($ScanDepth -eq 'Quick' -and $limit -gt 1) {
            [int][Math]::Round(($i * ($hostCount - 1)) / ($limit - 1))
        }
        else {
            $i
        }

        $bytes = [byte[]]::new(16)
        [Array]::Copy($baseBytes, $bytes, 16)
        $bytes[15] = [byte]($baseBytes[15] + $offset)
        $null = $targets.Add(([System.Net.IPAddress]::new($bytes)).ToString())
    }

    return @($targets)
}
