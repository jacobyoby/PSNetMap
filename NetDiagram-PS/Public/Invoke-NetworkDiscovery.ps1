function Invoke-NetworkDiscovery {
    <#
    .SYNOPSIS
        Discovers a topology for a single CIDR without requiring a repo clone
    .DESCRIPTION
        Enumerates host addresses for the given CIDR using the same prefix-aware math
        as the wizard (Quick/Medium/Full with a /22 cap). Returns a Topology with
        Nodes (Reachable = $null, to be probed via Test-DeviceReachability) and a
        single Subnet entry. This makes discovery work after Install-Module.
    .PARAMETER Cidr
        IPv4 CIDR to enumerate, e.g. 192.168.1.0/24
    .PARAMETER ScanDepth
        Quick (8 sampled), Medium (first 50), Full (all usable up to /22 = 1022)
    .EXAMPLE
        Invoke-NetworkDiscovery -Cidr 192.168.1.0/24 -ScanDepth Quick | Export-DrawIO -OutFile out.drawio
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Cidr,

        [Parameter()]
        [ValidateSet('Quick', 'Medium', 'Full')]
        [string]$ScanDepth = 'Quick'
    )

    if ([string]::IsNullOrWhiteSpace($Cidr)) { throw "Invalid CIDR value '$Cidr': expected IPv4 CIDR notation." }
    $normalizedCidr = ConvertTo-NormalizedIPv4Cidr -Value $Cidr -Context "Invoke-NetworkDiscovery.Cidr"
    $parts = $normalizedCidr -split '/'
    $networkIp = $parts[0]
    $prefix = [int]$parts[1]

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

    $topo = New-EmptyTopology
    $topo.Nodes = @($nodes)
    $topo.Subnets = @([pscustomobject]@{ CIDR = $normalizedCidr; Label = $normalizedCidr; VLAN = $null })
    $topo.Edges = @()
    return $topo
}
