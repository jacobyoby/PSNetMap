function Invoke-NetworkDiscovery {
    <#
    .SYNOPSIS
        Discovers a topology for a single CIDR without requiring a repo clone
    .DESCRIPTION
        Enumerates host addresses for the given CIDR. IPv4 uses the same prefix-aware
        math as the wizard (Quick/Medium/Full with a /22 cap). IPv6 does not sweep a
        /64 or any prefix shorter than /120 (256 hosts); those values fail immediately
        with an error pointing at Get-LocalARPTable (ND/ARP) neighbor discovery.
        Small IPv6 prefixes (/120–/128) are enumerated with the same Quick/Medium/Full
        depths, capped at 256 hosts. Returns a Topology with Nodes (Reachable = $null,
        to be probed via Test-DeviceReachability) and a single Subnet entry.
    .PARAMETER Cidr
        IPv4 or IPv6 CIDR to enumerate, e.g. 192.168.1.0/24 or 2001:db8::/120.
        IPv6 prefixes shorter than /120 are rejected.
    .PARAMETER ScanDepth
        Quick (8 sampled), Medium (first 50), Full (all usable IPv4 up to /22 = 1022,
        or all IPv6 hosts in a /120–/128 up to 256)
    .EXAMPLE
        Invoke-NetworkDiscovery -Cidr 192.168.1.0/24 -ScanDepth Quick | Export-DrawIO -OutFile out.drawio
    .EXAMPLE
        Invoke-NetworkDiscovery -Cidr 2001:db8::/120 -ScanDepth Quick
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Cidr,

        [Parameter()]
        [ValidateSet('Quick', 'Medium', 'Full')]
        [string]$ScanDepth = 'Quick'
    )

    if ([string]::IsNullOrWhiteSpace($Cidr)) { throw "Invalid CIDR value '$Cidr': expected IPv4 or IPv6 CIDR notation." }
    $normalizedCidr = ConvertTo-NormalizedCidr -Value $Cidr -Context "Invoke-NetworkDiscovery.Cidr"
    $parts = $normalizedCidr -split '/'
    $networkIp = $parts[0]
    $prefix = [int]$parts[1]
    $parsed = [System.Net.IPAddress]::Parse($networkIp)

    if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        $hosts = @(Get-IPv6CidrScanTarget -NetworkAddress $networkIp -PrefixLength $prefix -ScanDepth $ScanDepth)
        $nodes = foreach ($ip in $hosts) {
            [pscustomobject]@{
                IP        = $ip
                Hostname  = $ip
                Role      = 'unknown'
                Vendor    = 'Unknown'
                OS        = 'Unknown'
                Layer     = Get-LayerFromRole -Role 'unknown'
                Reachable = $null
            }
        }
    }
    else {
        $networkVal = ConvertTo-UInt32Address -IPAddress $networkIp
        $mask = Get-PrefixMask -PrefixLength $prefix
        $broadcastVal = [uint32]($networkVal -bor ((-bnot $mask) -band [uint32]4294967295))

        $hosts = Get-SubnetScanTarget -NetworkValue $networkVal -BroadcastValue $broadcastVal -ScanDepth $ScanDepth

        $nodes = foreach ($h in $hosts) {
            $ip = ConvertFrom-UInt32Address -Value $h
            [pscustomobject]@{
                IP        = $ip
                Hostname  = $ip
                Role      = 'unknown'
                Vendor    = 'Unknown'
                OS        = 'Unknown'
                Layer     = Get-LayerFromRole -Role 'unknown'
                Reachable = $null
            }
        }
    }

    $topo = New-EmptyTopology
    $topo.Nodes = @($nodes)
    $topo.Subnets = @([pscustomobject]@{ CIDR = $normalizedCidr; Label = $normalizedCidr; VLAN = $null })
    $topo.Edges = @()
    return $topo
}
