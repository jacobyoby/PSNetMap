#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Quick-start wizard to discover and diagram your network
.DESCRIPTION
    This script automatically discovers your network configuration and creates a professional network diagram.
    No configuration files needed - just run it!
.PARAMETER ScanDepth
    How deep to scan a detected IPv4 subnet: Quick (up to 8 hosts sampled across the range),
    Medium (first 50 hosts), Full (all usable hosts, capped at a /22 = 1022 hosts for
    larger subnets). Host addresses are derived from the interface's real CIDR prefix.
    IPv6 is not swept by ScanDepth; neighbors come from the local ND/ARP table unless
    -Cidr names a small IPv6 prefix (/120 or longer).
.PARAMETER OutputPath
    Where to save the diagram (default: .\my-network.drawio)
.PARAMETER InterfaceName
    Interface name or numeric interface index to scan. By default, the interface
    used by the active default route is selected (IPv4 default preferred, else IPv6).
    Dual-stack addresses on that interface are included; this switch still overrides.
.PARAMETER Cidr
    Optional IPv4 or IPv6 CIDR override. IPv4 uses Quick/Medium/Full with the /22 cap.
    IPv6 prefixes shorter than /120 (including a typical LAN /64) are rejected; use
    neighbor discovery instead, or pass a /120–/128. When omitted, IPv6 hosts come
    only from the local neighbor table (Get-LocalARPTable).
.PARAMETER DnsTimeoutSeconds
    Maximum time for each reverse DNS lookup during discovery (default: 2 seconds).
.PARAMETER TcpFallbackPort
    Optional TCP port forwarded to Test-DeviceReachability. When ICMP is silent,
    a successful connect on this port promotes the host to reachable.
.EXAMPLE
    .\New-NetworkDiagram.ps1

    Quick scan and diagram of your network
.EXAMPLE
    .\New-NetworkDiagram.ps1 -ScanDepth Medium -OutputPath .\office-network.drawio

    Medium scan with custom output location
.EXAMPLE
    .\New-NetworkDiagram.ps1 -TcpFallbackPort 443

    Use TCP 443 as a fallback when ICMP is blocked
.EXAMPLE
    .\New-NetworkDiagram.ps1 -Cidr 2001:db8::/120

    Sweep a small IPv6 prefix. Prefixes shorter than /120 (including /64) are rejected.
#>

[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Medium', 'Full')]
    [string]$ScanDepth = 'Quick',

    [string]$OutputPath = '.\my-network.drawio',

    [string]$InterfaceName,

    [string]$Cidr,

    [ValidateRange(1, 30)]
    [int]$DnsTimeoutSeconds = 2,

    [ValidateRange(1, 65535)]
    [int]$TcpFallbackPort
)

function Get-WizardInventoryPath {
    param([Parameter(Mandatory)][string]$OutputPath)
    return Get-InventoryOutputPath -DiagramPath $OutputPath
}

# ── IPv4 CIDR helpers ────────────────────────────────────────────────────────
# Real prefix-aware host enumeration (replaces the old /24-only "first 3 octets"
# assumption). Works for any prefix; the caller caps how many hosts get scanned.
function ConvertTo-UInt32Address {
    param([Parameter(Mandatory)][string]$IPAddress)
    $bytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [System.BitConverter]::ToUInt32($bytes, 0)
}

function ConvertFrom-UInt32Address {
    param([Parameter(Mandatory)][uint32]$Value)
    $bytes = [System.BitConverter]::GetBytes($Value)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-PrefixMask {
    param([Parameter(Mandatory)][int]$PrefixLength)
    if ($PrefixLength -le 0) { return [uint32]0 }
    if ($PrefixLength -ge 32) { return [uint32]4294967295 }
    return [uint32]((([uint64]4294967295) -shl (32 - $PrefixLength)) -band [uint64]4294967295)
}

function Get-SubnetScanTarget {
    <#
    .SYNOPSIS
        Returns the list of host addresses (as UInt32 values) to scan within a subnet,
        derived from the real network/broadcast bounds and bounded by scan depth.
    .DESCRIPTION
        Usable hosts are the addresses strictly between the network and broadcast
        addresses. Quick samples up to 8 hosts spread across the range; Medium takes the
        first 50; Full takes all usable hosts up to MaxScanHosts (a /22 by default).
    #>
    param(
        [Parameter(Mandatory)][uint32]$NetworkValue,
        [Parameter(Mandatory)][uint32]$BroadcastValue,
        [ValidateSet('Quick', 'Medium', 'Full')][string]$ScanDepth = 'Quick',
        [int]$MaxScanHosts = 1022
    )

    [int64]$firstHost   = [int64]$NetworkValue + 1
    [int64]$lastHost    = [int64]$BroadcastValue - 1
    [int64]$usableCount = if ($lastHost -ge $firstHost) { $lastHost - $firstHost + 1 } else { 0 }

    $hostValues = [System.Collections.Generic.List[uint32]]::new()
    if ($usableCount -le 0) {
        # point-to-point (/31) or single host (/32): nothing to sweep
    }
    elseif ($ScanDepth -eq 'Quick') {
        $sampleCount = [int][Math]::Min(8, $usableCount)
        for ($s = 0; $s -lt $sampleCount; $s++) {
            $offset = if ($sampleCount -eq 1) { 0 } else { [int64][Math]::Round(($s * ($usableCount - 1)) / ($sampleCount - 1)) }
            $hostValues.Add([uint32]($firstHost + $offset))
        }
    }
    else {
        $limit = if ($ScanDepth -eq 'Medium') {
            [int64][Math]::Min(50, $usableCount)
        } else {
            [int64][Math]::Min($MaxScanHosts, $usableCount)
        }
        for ($h = 0; $h -lt $limit; $h++) {
            $hostValues.Add([uint32]($firstHost + $h))
        }
    }

    return $hostValues.ToArray()
}

function Get-InventoryOutputPath {
    param([Parameter(Mandatory)][string]$DiagramPath)

    if ([string]::IsNullOrWhiteSpace($DiagramPath)) {
        throw 'Diagram output path cannot be empty.'
    }

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($DiagramPath)
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "Diagram output path must include a file name: $DiagramPath"
    }

    $directory = [System.IO.Path]::GetDirectoryName($DiagramPath)
    $inventoryFileName = "$fileName-inventory.json"
    $inventoryPath = if ([string]::IsNullOrEmpty($directory)) {
        $inventoryFileName
    }
    else {
        [System.IO.Path]::Combine($directory, $inventoryFileName)
    }

    if ([System.IO.Path]::GetFullPath($inventoryPath) -eq [System.IO.Path]::GetFullPath($DiagramPath)) {
        throw 'Diagram and inventory output paths must be different.'
    }

    return $inventoryPath
}

function Get-InterfaceAddressFamily {
    param([Parameter(Mandatory)][object]$Interface)

    if ($Interface.PSObject.Properties['AddressFamily'] -and -not [string]::IsNullOrWhiteSpace([string]$Interface.AddressFamily)) {
        return [string]$Interface.AddressFamily
    }

    $parsed = $null
    if ([System.Net.IPAddress]::TryParse([string]$Interface.IPAddress, [ref]$parsed)) {
        if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
            return 'IPv6'
        }
    }
    return 'IPv4'
}

function Test-IsIPv6LinkLocal {
    param([string]$IPAddress)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) {
        return $false
    }
    return [bool]$parsed.IsIPv6LinkLocal
}

function Test-SameScanInterface {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)

    if ($Candidates.Count -le 1) {
        return $true
    }

    $names = @($Candidates | ForEach-Object { $_.Name } | Select-Object -Unique)
    if ($names.Count -eq 1) {
        return $true
    }

    $indexes = @($Candidates | Where-Object { $null -ne $_.Index } | ForEach-Object { $_.Index } | Select-Object -Unique)
    return ($indexes.Count -eq 1 -and $indexes[0] -ne $null -and $Candidates.Count -eq @($Candidates | Where-Object { $_.Index -eq $indexes[0] }).Count)
}

function Select-PreferredScanAddress {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)

    if ($null -eq $Candidates -or $Candidates.Count -eq 0) {
        return $null
    }
    if ($Candidates.Count -eq 1) {
        return $Candidates[0]
    }

    $v4 = @($Candidates | Where-Object { (Get-InterfaceAddressFamily $_) -eq 'IPv4' })
    if ($v4.Count -ge 1) {
        return $v4[0]
    }

    $v6preferred = @($Candidates | Where-Object {
        (Get-InterfaceAddressFamily $_) -eq 'IPv6' -and -not (Test-IsIPv6LinkLocal $_.IPAddress)
    })
    if ($v6preferred.Count -ge 1) {
        return $v6preferred[0]
    }

    return $Candidates[0]
}

function Get-RelatedInterfaceAddress {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Interfaces,
        [Parameter(Mandatory)][object]$Selected
    )

    return @($Interfaces | Where-Object {
        $_.Name -eq $Selected.Name -or
        ($null -ne $Selected.Index -and $null -ne $_.Index -and $_.Index -eq $Selected.Index)
    })
}

function Select-ScanInterface {
    param(
        [Parameter(Mandatory)][object[]]$Interfaces,
        [string]$RequestedInterface,
        [string]$DefaultInterfaceName,
        [Nullable[int]]$DefaultInterfaceIndex
    )

    if ($Interfaces.Count -eq 0) {
        throw 'No active IPv4 or IPv6 network interfaces were found.'
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedInterface)) {
        $matchingInterfaces = @($Interfaces | Where-Object {
            $_.Name -eq $RequestedInterface -or
            ($null -ne $_.Index -and "$($_.Index)" -eq $RequestedInterface)
        })
        if ($matchingInterfaces.Count -eq 0) {
            throw "Network interface '$RequestedInterface' was not found. Available interfaces: $($Interfaces.Name -join ', ')"
        }
        if (-not (Test-SameScanInterface -Candidates $matchingInterfaces)) {
            throw "Network interface '$RequestedInterface' is ambiguous. Use its numeric interface index."
        }
        return Select-PreferredScanAddress -Candidates $matchingInterfaces
    }

    $routeMatches = @($Interfaces | Where-Object {
        (-not [string]::IsNullOrWhiteSpace($DefaultInterfaceName) -and $_.Name -eq $DefaultInterfaceName) -or
        ($null -ne $DefaultInterfaceIndex -and $_.Index -eq $DefaultInterfaceIndex)
    })
    if ($routeMatches.Count -ge 1) {
        if (-not (Test-SameScanInterface -Candidates $routeMatches)) {
            throw 'The default route maps to multiple interfaces. Select one with -InterfaceName.'
        }
        return Select-PreferredScanAddress -Candidates $routeMatches
    }
    if (Test-SameScanInterface -Candidates $Interfaces) {
        return Select-PreferredScanAddress -Candidates $Interfaces
    }

    throw 'No default-route interface could be selected. Use -InterfaceName with an available interface name or index.'
}

function Get-IPv6CidrSweepFailureMessage {
    param(
        [Parameter(Mandatory)][string]$Cidr,
        [Parameter(Mandatory)][int]$PrefixLength,
        [int]$MinPrefixLength = 120,
        [int]$MaxScanHosts = 256
    )

    $hostBits = 128 - $PrefixLength
    return "IPv6 CIDR '$Cidr' (/$PrefixLength) is too large to sweep (2^$hostBits addresses). Do not sweep a /64 or other large prefix. Use a CIDR of /$MinPrefixLength or longer (at most $MaxScanHosts hosts), or discover IPv6 hosts from the local neighbor table with Get-LocalARPTable (ND/ARP) instead of a CIDR sweep."
}

function ConvertFrom-WizardCidr {
    param([Parameter(Mandatory)][string]$Cidr)

    if ($Cidr -notmatch '^(.+)/(\d{1,3})$') {
        throw "Invalid CIDR value '$Cidr': expected IPv4 or IPv6 CIDR notation."
    }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($matches[1], [ref]$parsed)) {
        throw "Invalid CIDR value '$Cidr': expected an IPv4 or IPv6 address."
    }

    $prefixLength = [int]$matches[2]
    $maxPrefix = if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { 32 } else { 128 }
    if ($prefixLength -lt 0 -or $prefixLength -gt $maxPrefix) {
        throw "Invalid CIDR value '$Cidr': prefix must be between 0 and $maxPrefix."
    }

    $family = if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { 'IPv6' } else { 'IPv4' }
    if ($family -eq 'IPv6' -and $prefixLength -lt 120) {
        throw (Get-IPv6CidrSweepFailureMessage -Cidr $Cidr -PrefixLength $prefixLength)
    }

    [pscustomobject]@{
        Address       = $parsed.ToString()
        PrefixLength  = $prefixLength
        AddressFamily = $family
        Cidr          = "$($parsed.ToString())/$prefixLength"
    }
}

function Select-IPv6NeighborAddress {
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$NeighborEntries = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SkipIPs = @(),

        [Parameter()]
        [string]$InterfaceName
    )

    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in @($SkipIPs)) {
        if ([string]::IsNullOrWhiteSpace($ip)) { continue }
        $parsedSkip = $null
        if ([System.Net.IPAddress]::TryParse($ip, [ref]$parsedSkip)) {
            [void]$skip.Add($parsedSkip.ToString())
        }
        else {
            [void]$skip.Add($ip)
        }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($NeighborEntries)) {
        if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.IPAddress)) { continue }

        $addr = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$entry.IPAddress, [ref]$addr)) { continue }
        if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetworkV6) { continue }
        if ($addr.IsIPv6Multicast) { continue }
        if ([System.Net.IPAddress]::IsLoopback($addr)) { continue }

        $canonical = $addr.ToString()
        if ($skip.Contains($canonical)) { continue }

        if (-not [string]::IsNullOrWhiteSpace($InterfaceName) -and
            $entry.PSObject.Properties['InterfaceAlias'] -and
            -not [string]::IsNullOrWhiteSpace([string]$entry.InterfaceAlias) -and
            $entry.InterfaceAlias -ne $InterfaceName) {
            continue
        }

        $state = [string]$entry.State
        if ($state -match '^(Incomplete|Failed|None|Unreachable)$') { continue }

        if ($seen.Add($canonical)) {
            $canonical
        }
    }
}

function ConvertTo-WizardNeighborNode {
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$NeighborEntries = @(),

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SkipIPs = @(),

        [Parameter()]
        [string]$InterfaceName
    )

    $ips = @(Select-IPv6NeighborAddress -NeighborEntries $NeighborEntries -SkipIPs $SkipIPs -InterfaceName $InterfaceName)
    foreach ($ip in $ips) {
        [pscustomobject]@{
            IP        = $ip
            Hostname  = $ip
            Role      = 'unknown'
            Vendor    = 'Unknown'
            OS        = 'Unknown'
            Layer     = 'Access'
            Reachable = $null
        }
    }
}

function New-WizardInventoryObject {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Nodes,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Subnets = @()
    )

    return @{
        knownDevices = @($Nodes | ForEach-Object {
            @{
                ip       = $_.IP
                hostname = $_.Hostname
                role     = $_.Role
                vendor   = $_.Vendor
                os       = $_.OS
            }
        })
        subnets = @($Subnets | ForEach-Object {
            @{
                cidr  = $_.CIDR
                label = $_.Label
                vlan  = $_.VLAN
            }
        })
    }
}

function Invoke-WizardReachabilityProbe {
    <#
    .SYNOPSIS
        Probe a node list with Test-DeviceReachability (true / false / $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Nodes,

        [Parameter()]
        [int]$TimeoutSeconds = 1,

        [Parameter()]
        [int]$MaxParallel = 32,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int]$TcpFallbackPort,

        [Parameter()]
        [scriptblock]$ProbeScript
    )

    if ($null -eq $Nodes -or $Nodes.Count -eq 0) {
        return
    }

    $topology = [pscustomobject]@{
        Nodes   = $Nodes
        Edges   = @()
        Subnets = @()
    }

    $params = @{
        Topology       = $topology
        TimeoutSeconds = $TimeoutSeconds
        MaxParallel    = $MaxParallel
    }
    if ($PSBoundParameters.ContainsKey('TcpFallbackPort')) {
        $params.TcpFallbackPort = $TcpFallbackPort
    }
    if ($ProbeScript) {
        $params.ProbeScript = $ProbeScript
    }

    $null = Test-DeviceReachability @params
}

function Update-WizardNodeReachability {
    <#
    .SYNOPSIS
        Test previously untested wizard nodes via Test-DeviceReachability.
    .DESCRIPTION
        Leaves already-probed Reachable values untouched. Local send failures stay
        $null (Unknown) instead of collapsing to $false the way Test-Connection
        -Quiet does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Nodes,

        [Parameter()]
        [int]$TimeoutSeconds = 2,

        [Parameter()]
        [int]$MaxParallel = 32,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int]$TcpFallbackPort,

        [Parameter()]
        [scriptblock]$ProbeScript
    )

    $untested = @($Nodes | Where-Object { $null -eq $_.Reachable })
    $probeParams = @{
        Nodes          = $untested
        TimeoutSeconds = $TimeoutSeconds
        MaxParallel    = $MaxParallel
    }
    if ($PSBoundParameters.ContainsKey('TcpFallbackPort')) {
        $probeParams.TcpFallbackPort = $TcpFallbackPort
    }
    if ($ProbeScript) {
        $probeParams.ProbeScript = $ProbeScript
    }

    Invoke-WizardReachabilityProbe @probeParams
    return $Nodes
}

function Find-WizardReachableScanHosts {
    <#
    .SYNOPSIS
        Probe scan targets and return only confirmed-reachable hosts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ScanTargets,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$SkipIPs = @(),

        [Parameter()]
        [int]$TimeoutSeconds = 1,

        [Parameter()]
        [int]$MaxParallel = 20,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int]$TcpFallbackPort,

        [Parameter()]
        [scriptblock]$ProbeScript
    )

    $skip = @{}
    foreach ($ip in @($SkipIPs)) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) {
            $skip[$ip] = $true
        }
    }

    $candidates = @(
        $ScanTargets | Where-Object { $_ -and -not $skip.ContainsKey($_) } | ForEach-Object {
            [pscustomobject]@{
                IP        = $_
                Hostname  = $null
                Role      = 'unknown'
                Vendor    = 'Unknown'
                OS        = 'Unknown'
                Layer     = 'Access'
                Reachable = $null
            }
        }
    )

    $probeParams = @{
        Nodes          = $candidates
        TimeoutSeconds = $TimeoutSeconds
        MaxParallel    = $MaxParallel
    }
    if ($PSBoundParameters.ContainsKey('TcpFallbackPort')) {
        $probeParams.TcpFallbackPort = $TcpFallbackPort
    }
    if ($ProbeScript) {
        $probeParams.ProbeScript = $ProbeScript
    }

    Invoke-WizardReachabilityProbe @probeParams
    return @($candidates | Where-Object { $_.Reachable -eq $true })
}

function Get-WizardReachabilitySummary {
    <#
    .SYNOPSIS
        Count reachable, unreachable, and unknown (indeterminate) nodes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Nodes
    )

    $list = @($Nodes)
    [pscustomobject]@{
        Reachable   = @($list | Where-Object { $_.Reachable -eq $true }).Count
        Unreachable = @($list | Where-Object { $_.Reachable -eq $false }).Count
        Unknown     = @($list | Where-Object { $null -eq $_.Reachable }).Count
        Total       = $list.Count
    }
}

function ConvertFrom-MacOSInterfaceText {
    param([Parameter(Mandatory)][string[]]$Lines)

    $name = $null
    foreach ($line in $Lines) {
        if ($line -match '^([^\s:]+):\s') {
            $name = $matches[1]
            continue
        }
        if ($name -and $line -match '^\s+inet\s+(\d+\.\d+\.\d+\.\d+)(?:\s+-->\s+\d+\.\d+\.\d+\.\d+)?\s+netmask\s+0x([0-9a-fA-F]+)') {
            if ($matches[1] -eq '127.0.0.1') { continue }
            $binaryMask = [Convert]::ToString([Convert]::ToInt64($matches[2], 16), 2)
            [pscustomobject]@{
                Name = $name
                Index = $null
                IPAddress = $matches[1]
                PrefixLength = ($binaryMask.ToCharArray() | Where-Object { $_ -eq '1' }).Count
                AddressFamily = 'IPv4'
            }
        }
        elseif ($name -and $line -match '^\s+inet6\s+([0-9a-fA-F:]+)(?:%\S+)?\s+prefixlen\s+(\d+)') {
            if ($matches[1] -eq '::1') { continue }
            [pscustomobject]@{
                Name = $name
                Index = $null
                IPAddress = $matches[1]
                PrefixLength = [int]$matches[2]
                AddressFamily = 'IPv6'
            }
        }
    }
}

function ConvertFrom-LinuxInterfaceText {
    param([Parameter(Mandatory)][string[]]$Lines)

    $name = $null
    $index = $null
    foreach ($line in $Lines) {
        if ($line -match '^(\d+):\s+([^:@]+)(?:@[^:]+)?:') {
            $index = [int]$matches[1]
            $name = $matches[2]
            continue
        }
        if ($name -and $line -match '^\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)') {
            if ($matches[1] -eq '127.0.0.1') { continue }
            [pscustomobject]@{
                Name = $name
                Index = $index
                IPAddress = $matches[1]
                PrefixLength = [int]$matches[2]
                AddressFamily = 'IPv4'
            }
        }
        elseif ($name -and $line -match '^\s+inet6\s+([0-9a-fA-F:]+)/(\d+)') {
            if ($matches[1] -eq '::1') { continue }
            [pscustomobject]@{
                Name = $name
                Index = $index
                IPAddress = $matches[1]
                PrefixLength = [int]$matches[2]
                AddressFamily = 'IPv6'
            }
        }
    }
}

# Allow the Pester suite to dot-source this script for the pure helper functions above
# without launching the interactive wizard (which performs a live network scan).
if ($MyInvocation.InvocationName -eq '.') { return }

# Import the module
$modulePath = Join-Path $PSScriptRoot '..' 'NetDiagram-PS' 'NetDiagram-PS.psd1'
if (-not (Test-Path $modulePath)) {
    Write-Host "✗ Module not found at: $modulePath" -ForegroundColor Red
    Write-Host "  Please run this script from the examples/ folder or ensure NetDiagram-PS module is installed." -ForegroundColor Yellow
    exit 1
}
Import-Module $modulePath -Force

Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           NetDiagram-PS Quick Start Wizard                 ║" -ForegroundColor Cyan
Write-Host "║         Discover and Diagram YOUR Network                  ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Step 1: Discover your network interfaces
Write-Host "[1/5] Discovering your network configuration..." -ForegroundColor Yellow

# Cross-platform network discovery (IPv4 + IPv6)
$gateway = $null
$gatewayV6 = $null
$dnsServers = @()
$defaultInterfaceName = $null

if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6 -or $null -eq $IsWindows) {
    # Windows: Use native cmdlets
    $interfaces = @(Get-NetIPAddress -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -ne '::1' -and
        -not ($_.AddressFamily -eq 'IPv4' -and $_.PrefixOrigin -eq 'WellKnown')
    } | ForEach-Object {
        $family = if ("$($_.AddressFamily)" -eq 'IPv6') { 'IPv6' } else { 'IPv4' }
        [pscustomobject]@{
            Name = $_.InterfaceAlias
            Index = $_.InterfaceIndex
            IPAddress = $_.IPAddress
            PrefixLength = $_.PrefixLength
            AddressFamily = $family
        }
    })

    $v4Routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' })
    $v6Routes = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '::' })
    $defaultRoute = $v4Routes | Sort-Object RouteMetric | Select-Object -First 1
    if (-not $defaultRoute) {
        $defaultRoute = $v6Routes | Sort-Object RouteMetric | Select-Object -First 1
    }
    $primaryInterface = Select-ScanInterface -Interfaces $interfaces -RequestedInterface $InterfaceName `
        -DefaultInterfaceIndex $defaultRoute.InterfaceIndex
    $selectedV4Route = $v4Routes | Where-Object { $_.InterfaceIndex -eq $primaryInterface.Index } |
        Sort-Object RouteMetric | Select-Object -First 1
    $selectedV6Route = $v6Routes | Where-Object { $_.InterfaceIndex -eq $primaryInterface.Index } |
        Sort-Object RouteMetric | Select-Object -First 1
    $gateway = $selectedV4Route.NextHop
    $gatewayV6 = $selectedV6Route.NextHop

    $dnsServers = @(Get-DnsClientServerAddress -InterfaceIndex $primaryInterface.Index -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        Select-Object -ExpandProperty ServerAddresses -Unique |
        Where-Object { $_ -notmatch '^(127\.|::1)' } |
        Select-Object -First 4)
} else {
    # macOS/Linux: Parse ifconfig/ip commands
    if ($IsMacOS) {
        $ifconfigOutput = & ifconfig -a 2>&1
        $interfaces = @(ConvertFrom-MacOSInterfaceText -Lines $ifconfigOutput)

        $routeOutput = & route -n get default 2>&1
        $v4RouteText = $routeOutput -join "`n"
        $gatewayMatch = [regex]::Match($v4RouteText, 'gateway:\s+(\d+\.\d+\.\d+\.\d+)')
        $routeInterfaceMatch = [regex]::Match($v4RouteText, 'interface:\s+(\S+)')
        if ($gatewayMatch.Success) {
            $gateway = $gatewayMatch.Groups[1].Value
        }
        $defaultInterfaceName = if ($routeInterfaceMatch.Success) { $routeInterfaceMatch.Groups[1].Value } else { $null }

        $v6RouteOutput = & route -n get -inet6 default 2>&1
        $v6RouteText = $v6RouteOutput -join "`n"
        $v6GatewayMatch = [regex]::Match($v6RouteText, 'gateway:\s+(\S+)')
        $v6InterfaceMatch = [regex]::Match($v6RouteText, 'interface:\s+(\S+)')
        if ($v6GatewayMatch.Success) {
            $gatewayV6 = ($v6GatewayMatch.Groups[1].Value -replace '%.*$', '')
        }
        if (-not $defaultInterfaceName -and $v6InterfaceMatch.Success) {
            $defaultInterfaceName = $v6InterfaceMatch.Groups[1].Value
        }

        $primaryInterface = Select-ScanInterface -Interfaces $interfaces -RequestedInterface $InterfaceName `
            -DefaultInterfaceName $defaultInterfaceName
        if ($InterfaceName -and $primaryInterface.Name -ne $defaultInterfaceName) {
            $gateway = $null
            if (-not $v6InterfaceMatch.Success -or $primaryInterface.Name -ne $v6InterfaceMatch.Groups[1].Value) {
                $gatewayV6 = $null
            }
        }

        $dnsOutput = & scutil --dns 2>&1
        $dnsText = $dnsOutput -join "`n"
        $dnsMatches = [regex]::Matches($dnsText, 'nameserver\[\d+\]\s*:\s*(\S+)')
        $dnsServers = @($dnsMatches | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notmatch '^(127\.|::1)' } |
            Select-Object -Unique -First 4)

        if ($dnsServers.Count -eq 0 -and (Test-Path '/etc/resolv.conf')) {
            $resolvConf = Get-Content '/etc/resolv.conf' -ErrorAction SilentlyContinue
            $dnsServers = @($resolvConf | Where-Object { $_ -match '^nameserver\s+(\S+)' } |
                ForEach-Object { $matches[1] } |
                Where-Object { $_ -notmatch '^(127\.|::1)' } |
                Select-Object -Unique -First 4)
        }
    } elseif ($IsLinux) {
        $ipOutput = & ip addr show 2>&1
        $interfaces = @(ConvertFrom-LinuxInterfaceText -Lines $ipOutput)

        $routeOutput = & ip route show default 2>&1
        $v4RouteText = $routeOutput -join "`n"
        $gatewayMatch = [regex]::Match($v4RouteText, 'default\s+via\s+(\d+\.\d+\.\d+\.\d+)')
        $routeInterfaceMatch = [regex]::Match($v4RouteText, '\bdev\s+(\S+)')
        if ($gatewayMatch.Success) {
            $gateway = $gatewayMatch.Groups[1].Value
        }
        $defaultInterfaceName = if ($routeInterfaceMatch.Success) { $routeInterfaceMatch.Groups[1].Value } else { $null }

        $v6RouteOutput = & ip -6 route show default 2>&1
        $v6RouteText = $v6RouteOutput -join "`n"
        $v6GatewayMatch = [regex]::Match($v6RouteText, 'default\s+via\s+([0-9a-fA-F:]+)')
        $v6InterfaceMatch = [regex]::Match($v6RouteText, '\bdev\s+(\S+)')
        if ($v6GatewayMatch.Success) {
            $gatewayV6 = $v6GatewayMatch.Groups[1].Value
        }
        if (-not $defaultInterfaceName -and $v6InterfaceMatch.Success) {
            $defaultInterfaceName = $v6InterfaceMatch.Groups[1].Value
        }

        $primaryInterface = Select-ScanInterface -Interfaces $interfaces -RequestedInterface $InterfaceName `
            -DefaultInterfaceName $defaultInterfaceName
        if ($InterfaceName -and $primaryInterface.Name -ne $defaultInterfaceName) {
            $gateway = $null
            if (-not $v6InterfaceMatch.Success -or $primaryInterface.Name -ne $v6InterfaceMatch.Groups[1].Value) {
                $gatewayV6 = $null
            }
        }

        $dnsServers = @()
        if (Test-Path '/etc/resolv.conf') {
            $resolvConf = Get-Content '/etc/resolv.conf' -ErrorAction SilentlyContinue
            $dnsServers = @($resolvConf | Where-Object { $_ -match '^nameserver\s+(\S+)' } |
                ForEach-Object { $matches[1] } |
                Where-Object { $_ -notmatch '^(127\.|::1)' } |
                Select-Object -Unique -First 4)
        }
    }
}

$selectedAddresses = @(Get-RelatedInterfaceAddress -Interfaces $interfaces -Selected $primaryInterface)
$v4Addresses = @($selectedAddresses | Where-Object { (Get-InterfaceAddressFamily $_) -eq 'IPv4' })
$v6Addresses = @($selectedAddresses | Where-Object { (Get-InterfaceAddressFamily $_) -eq 'IPv6' })
$primaryV4 = if ($v4Addresses.Count -gt 0) { $v4Addresses[0] } else { $null }
$primaryV6 = @(
    $v6Addresses | Where-Object { -not (Test-IsIPv6LinkLocal $_.IPAddress) } |
        Select-Object -First 1
)
if (-not $primaryV6 -and $v6Addresses.Count -gt 0) {
    $primaryV6 = $v6Addresses[0]
}

$myIP = $primaryInterface.IPAddress
$prefix = $primaryInterface.PrefixLength
$myIPv6 = if ($primaryV6) { $primaryV6.IPAddress } else { $null }

Write-Host "      Found $($interfaces.Count) active address(es) on $($selectedAddresses.Count) selected-interface row(s)" -ForegroundColor Green

Write-Host "      Interface: $($primaryInterface.Name)" -ForegroundColor Cyan
Write-Host "      Your IP: $myIP/$prefix" -ForegroundColor Cyan
if ($primaryV4 -and $primaryV6 -and $myIPv6 -ne $myIP) {
    Write-Host "      IPv6: $myIPv6/$($primaryV6.PrefixLength)" -ForegroundColor Cyan
}
Write-Host "      Gateway: $gateway" -ForegroundColor Cyan
if ($gatewayV6) {
    Write-Host "      IPv6 gateway: $gatewayV6" -ForegroundColor Cyan
}
Write-Host "      DNS: $($dnsServers -join ', ')" -ForegroundColor Cyan
if ($v6Addresses.Count -gt 0) {
    Write-Host "      IPv6 scan: neighbor table (ND/ARP); CIDR sweep only for /120 or longer" -ForegroundColor DarkGray
}

# Step 2: Build initial topology
Write-Host "`n[2/5] Building network topology..." -ForegroundColor Yellow

$nodes = @()
$edges = @()
$subnets = @()

$cidrOverride = $null
if (-not [string]::IsNullOrWhiteSpace($Cidr)) {
    $cidrOverride = ConvertFrom-WizardCidr -Cidr $Cidr
}

# IPv4 subnet from the interface (or -Cidr override). IPv6 interface prefixes are
# recorded for inventory parenting but never swept unless -Cidr is a /120 or longer.
$cidr = $null
$networkValue = $null
$broadcastValue = $null
$prefixInt = $null

if ($cidrOverride -and $cidrOverride.AddressFamily -eq 'IPv4') {
    $prefixInt = [int]$cidrOverride.PrefixLength
    $ipValue = ConvertTo-UInt32Address $cidrOverride.Address
    $mask = Get-PrefixMask -PrefixLength $prefixInt
    $networkValue = $ipValue -band $mask
    $broadcastValue = [uint32](($networkValue -bor ((-bnot $mask) -band [uint32]4294967295)))
    $networkAddress = ConvertFrom-UInt32Address $networkValue
    $cidr = "$networkAddress/$prefixInt"
}
elseif ($primaryV4) {
    $prefixInt = [int]$primaryV4.PrefixLength
    if ($prefixInt -lt 0 -or $prefixInt -gt 32) {
        Write-Host "      Prefix /$prefixInt is invalid; defaulting to /24" -ForegroundColor Yellow
        $prefixInt = 24
    }

    $ipValue        = ConvertTo-UInt32Address $primaryV4.IPAddress
    $mask           = Get-PrefixMask -PrefixLength $prefixInt
    $networkValue   = $ipValue -band $mask
    $broadcastValue = [uint32](($networkValue -bor ((-bnot $mask) -band [uint32]4294967295)))
    $networkAddress = ConvertFrom-UInt32Address $networkValue
    $cidr           = "$networkAddress/$prefixInt"
}

if ($cidr) {
    $subnets += [pscustomobject]@{
        CIDR = $cidr
        Label = "Local Network"
        VLAN = $null
    }
}

if ($primaryV6 -and -not (Test-IsIPv6LinkLocal $primaryV6.IPAddress)) {
    $subnets += [pscustomobject]@{
        CIDR = "$($primaryV6.IPAddress)/$($primaryV6.PrefixLength)"
        Label = "IPv6 Local Network"
        VLAN = $null
    }
}

if ($cidrOverride -and $cidrOverride.AddressFamily -eq 'IPv6') {
    $already = @($subnets | Where-Object { $_.CIDR -eq $cidrOverride.Cidr })
    if ($already.Count -eq 0) {
        $subnets += [pscustomobject]@{
            CIDR = $cidrOverride.Cidr
            Label = "IPv6 Scan"
            VLAN = $null
        }
    }
}

# Add your computer - cross-platform
if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6 -or $null -eq $IsWindows) {
    $computerName = $env:COMPUTERNAME
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $osCaption = if ($osInfo) { $osInfo.Caption } else { "Windows" }
} else {
    # macOS/Linux
    $computerName = & hostname 2>&1 | Select-Object -First 1
    if ($IsMacOS) {
        $osVersion = & sw_vers -productVersion 2>&1
        $osCaption = "macOS $osVersion"
    } elseif ($IsLinux) {
        # Try to get Linux distribution info
        if (Test-Path '/etc/os-release') {
            $osRelease = Get-Content '/etc/os-release' -ErrorAction SilentlyContinue
            $prettyName = $osRelease | Where-Object { $_ -match '^PRETTY_NAME="(.+)"' } | ForEach-Object { $matches[1] }
            $osCaption = if ($prettyName) { $prettyName } else { "Linux" }
        } else {
            $osCaption = "Linux"
        }
    } else {
        $osCaption = "Unix-like"
    }
}

$nodes += [pscustomobject]@{
    IP = $myIP
    Hostname = $computerName
    Role = 'workstation'
    Vendor = 'Local'
    OS = $osCaption
    Layer = 'Access'
    Reachable = $true
}

if ($myIPv6 -and $myIPv6 -ne $myIP -and -not (Test-IsIPv6LinkLocal $myIPv6)) {
    $nodes += [pscustomobject]@{
        IP = $myIPv6
        Hostname = $computerName
        Role = 'workstation'
        Vendor = 'Local'
        OS = $osCaption
        Layer = 'Access'
        Reachable = $true
    }
}

# Add gateway
if ($gateway) {
    $gwHostname = try {
        $resolved = [System.Net.Dns]::GetHostEntry($gateway)
        $resolved.HostName
    } catch {
        "Gateway"
    }

    $nodes += [pscustomobject]@{
        IP = $gateway
        Hostname = $gwHostname
        Role = 'router'
        Vendor = 'Unknown'
        OS = 'Unknown'
        Layer = 'Core'
        Reachable = $null
    }

    $edges += [pscustomobject]@{
        SourceIP = $myIP
        TargetIP = $gateway
        Label = 'Default Route'
        Source = 'Local Config'
        Confidence = 'L3-Inferred'
    }
}

if ($gatewayV6 -and $gatewayV6 -ne $gateway) {
    $gw6Hostname = try {
        $resolved = [System.Net.Dns]::GetHostEntry($gatewayV6)
        $resolved.HostName
    } catch {
        "Gateway"
    }

    $nodes += [pscustomobject]@{
        IP = $gatewayV6
        Hostname = $gw6Hostname
        Role = 'router'
        Vendor = 'Unknown'
        OS = 'Unknown'
        Layer = 'Core'
        Reachable = $null
    }

    $v6EdgeSource = if ($myIPv6) { $myIPv6 } else { $myIP }
    $edges += [pscustomobject]@{
        SourceIP = $v6EdgeSource
        TargetIP = $gatewayV6
        Label = 'IPv6 Default Route'
        Source = 'Local Config'
        Confidence = 'L3-Inferred'
    }
}

# Add DNS servers
foreach ($dns in $dnsServers) {
    if ($dns -ne $gateway) {
        $dnsHostname = try {
            $resolved = [System.Net.Dns]::GetHostEntry($dns)
            $resolved.HostName
        } catch {
            "DNS Server"
        }

        $nodes += [pscustomobject]@{
            IP = $dns
            Hostname = $dnsHostname
            Role = 'server'
            Vendor = 'DNS'
            OS = 'Unknown'
            Layer = 'Servers'
            Reachable = $null
        }

        if ($gateway) {
            $edges += [pscustomobject]@{
                SourceIP = $gateway
                TargetIP = $dns
                Label = 'DNS Query'
                Source = 'Local Config'
                Confidence = 'L3-Inferred'
            }
        }
    }
}

Write-Host "      Created base topology with $($nodes.Count) nodes" -ForegroundColor Green

# Step 3: Scan for additional devices
Write-Host "`n[3/5] Scanning for other devices on your network..." -ForegroundColor Yellow

$scanTargets = @()

# IPv4: enumerate real host addresses from the actual prefix. Usable hosts are
# between the network and broadcast addresses (/31 and /32 have no sweep range).
if ($null -ne $networkValue -and $null -ne $broadcastValue) {
    $maxScanHosts = 1022  # a /22 worth of hosts - the scan cap for large subnets
    [int64]$usableCount = [int64]$broadcastValue - [int64]$networkValue - 1
    if ($usableCount -lt 0) { $usableCount = 0 }

    if ($usableCount -le 0) {
        Write-Host "      Subnet $cidr has no scannable host range (point-to-point or /32)" -ForegroundColor Yellow
    }
    elseif ($ScanDepth -eq 'Full' -and $usableCount -gt $maxScanHosts) {
        Write-Host "      ⚠ Subnet /$prefixInt has $usableCount usable hosts; capping scan to the first $maxScanHosts (a /22)." -ForegroundColor Yellow
        Write-Host "        Use a smaller subnet or an inventory file for a full sweep." -ForegroundColor Yellow
    }

    $hostValues = Get-SubnetScanTarget -NetworkValue $networkValue -BroadcastValue $broadcastValue -ScanDepth $ScanDepth -MaxScanHosts $maxScanHosts
    $scanTargets += @($hostValues | ForEach-Object { ConvertFrom-UInt32Address $_ })
    Write-Host "      IPv4 scan depth: $ScanDepth ($($scanTargets.Count) addresses in $cidr)" -ForegroundColor Cyan
}

# IPv6: never sweep the interface /64. Optional -Cidr of /120 or longer is enumerated
# via Invoke-NetworkDiscovery (same cap as the module cmdlet).
if ($cidrOverride -and $cidrOverride.AddressFamily -eq 'IPv6') {
    $v6Sweep = Invoke-NetworkDiscovery -Cidr $cidrOverride.Cidr -ScanDepth $ScanDepth
    $scanTargets += @($v6Sweep.Nodes | ForEach-Object { $_.IP })
    Write-Host "      IPv6 CIDR scan: $ScanDepth ($($v6Sweep.Nodes.Count) addresses in $($cidrOverride.Cidr))" -ForegroundColor Cyan
}

$skipIPs = @($myIP, $myIPv6, $gateway, $gatewayV6) + @($dnsServers)

# Neighbor discovery (ND/ARP) for IPv6 — used instead of a /64 sweep.
$neighborEntries = @()
try {
    $arpParams = @{}
    if ($primaryInterface.Name) {
        $arpParams.InterfaceAlias = $primaryInterface.Name
    }
    $neighborEntries = @(Get-LocalARPTable @arpParams)
}
catch {
    Write-Host "      IPv6 neighbor table unavailable: $($_.Exception.Message)" -ForegroundColor DarkGray
}

$neighborNodes = @(ConvertTo-WizardNeighborNode -NeighborEntries $neighborEntries -SkipIPs $skipIPs -InterfaceName $primaryInterface.Name)
if ($neighborNodes.Count -gt 0) {
    Write-Host "      IPv6 neighbors from local ND/ARP table: $($neighborNodes.Count)" -ForegroundColor Cyan
}

if ($scanTargets.Count -gt 0) {
    Write-Host "      This may take 10-60 seconds..." -ForegroundColor Gray
}

$discoverParams = @{
    ScanTargets    = $scanTargets
    SkipIPs        = $skipIPs
    TimeoutSeconds = 1
    MaxParallel    = 20
}
if ($PSBoundParameters.ContainsKey('TcpFallbackPort')) {
    $discoverParams.TcpFallbackPort = $TcpFallbackPort
}
$reachableScanHosts = @(Find-WizardReachableScanHosts @discoverParams)

$discovered = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

if ($reachableScanHosts.Count -gt 0) {
    $reachableScanHosts | ForEach-Object -Parallel {
        $testIP = $_.IP

        $hostname = try {
            if (-not (Get-Command Resolve-IPHostname -ErrorAction SilentlyContinue)) {
                Import-Module $using:modulePath -Force
            }
            $resolved = Resolve-IPHostname -IPAddress $testIP -TimeoutSeconds $using:DnsTimeoutSeconds
            if ($resolved.Success -and -not [string]::IsNullOrWhiteSpace($resolved.Hostname)) {
                $resolved.Hostname
            }
            else {
                "Device-$testIP"
            }
        } catch {
            "Device-$testIP"
        }

        ($using:discovered).Add([pscustomobject]@{
            IP = $testIP
            Hostname = $hostname
            Reachable = $true
        })
    } -ThrottleLimit 20
}

$discoveredDevices = @($discovered)

if ($discoveredDevices.Count -gt 0) {
    Write-Host "      ✓ Found $($discoveredDevices.Count) additional device(s)!" -ForegroundColor Green

    foreach ($device in $discoveredDevices) {
        Write-Host "        • $($device.IP) - $($device.Hostname)" -ForegroundColor DarkGray

        $nodes += [pscustomobject]@{
            IP = $device.IP
            Hostname = $device.Hostname
            Role = 'unknown'
            Vendor = 'Unknown'
            OS = 'Unknown'
            Layer = 'Access'
            Reachable = $true
        }

        $deviceFamily = $null
        $parsedDevice = $null
        if ([System.Net.IPAddress]::TryParse($device.IP, [ref]$parsedDevice)) {
            $deviceFamily = if ($parsedDevice.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { 'IPv6' } else { 'IPv4' }
        }
        $lanGateway = if ($deviceFamily -eq 'IPv6' -and $gatewayV6) { $gatewayV6 } else { $gateway }
        if ($lanGateway) {
            $edges += [pscustomobject]@{
                SourceIP = $lanGateway
                TargetIP = $device.IP
                Label = 'LAN'
                Source = 'Discovery'
                Confidence = 'L3-Inferred'
            }
        }
    }
}

$knownIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($existing in $nodes) {
    $parsedExisting = $null
    if ([System.Net.IPAddress]::TryParse([string]$existing.IP, [ref]$parsedExisting)) {
        [void]$knownIPs.Add($parsedExisting.ToString())
    }
    else {
        [void]$knownIPs.Add([string]$existing.IP)
    }
}

$addedNeighbors = 0
foreach ($neighbor in $neighborNodes) {
    if (-not $knownIPs.Add($neighbor.IP)) { continue }
    $addedNeighbors++
    Write-Host "        • $($neighbor.IP) (ND/ARP)" -ForegroundColor DarkGray
    $nodes += $neighbor
    $lanGateway = if ($gatewayV6) { $gatewayV6 } elseif ($gateway) { $gateway } else { $null }
    if ($lanGateway) {
        $edges += [pscustomobject]@{
            SourceIP = $lanGateway
            TargetIP = $neighbor.IP
            Label = 'ND'
            Source = 'Discovery'
            Confidence = 'L3-Inferred'
        }
    }
}

if ($discoveredDevices.Count -eq 0 -and $addedNeighbors -eq 0) {
    Write-Host "      No additional devices found (ICMP may be blocked; IPv6 uses ND/ARP, not a /64 sweep)" -ForegroundColor Yellow
} elseif ($addedNeighbors -gt 0) {
    Write-Host "      ✓ Added $addedNeighbors IPv6 neighbor(s) from the local ND/ARP table" -ForegroundColor Green
}

# Step 4: Test reachability (tri-state: true / false / $null)
Write-Host "`n[4/5] Testing connectivity..." -ForegroundColor Yellow

$reachParams = @{
    Nodes          = $nodes
    TimeoutSeconds = 2
}
if ($PSBoundParameters.ContainsKey('TcpFallbackPort')) {
    $reachParams.TcpFallbackPort = $TcpFallbackPort
}
$null = Update-WizardNodeReachability @reachParams

$reachSummary = Get-WizardReachabilitySummary -Nodes $nodes
Write-Host "      $($reachSummary.Reachable) reachable, $($reachSummary.Unreachable) unreachable, $($reachSummary.Unknown) unknown of $($reachSummary.Total) devices" -ForegroundColor Green

# Create topology object
$topology = [pscustomobject]@{
    Nodes = $nodes
    Edges = Merge-Edges -Edges $edges
    Subnets = $subnets
}

# Step 5: Generate diagram
Write-Host "`n[5/5] Generating your network diagram..." -ForegroundColor Yellow

$inventoryPath = Get-InventoryOutputPath -DiagramPath $OutputPath
$topology | Export-DrawIO -OutFile $OutputPath -Force

if (Test-Path $OutputPath) {
    $fileSize = (Get-Item $OutputPath).Length
    Write-Host "      ✓ Created: $OutputPath ($fileSize bytes)" -ForegroundColor Green
}

# Save inventory for future use. Every accepted diagram extension produces a
# distinct sibling inventory file (Import-Inventory dual-stack contract).
$inventoryData = New-WizardInventoryObject -Nodes $nodes -Subnets $subnets

$inventoryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $inventoryPath -Encoding utf8 -Force
Write-Host "      ✓ Saved inventory: $inventoryPath" -ForegroundColor Green

# Summary
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                  Success!                                  ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`nYour Network:" -ForegroundColor Cyan
Write-Host "  • Computer: $computerName ($myIP)" -ForegroundColor White
if ($myIPv6 -and $myIPv6 -ne $myIP) {
    Write-Host "  • IPv6: $myIPv6" -ForegroundColor White
}
if ($cidr) {
    Write-Host "  • Subnet: $cidr" -ForegroundColor White
}
$v6SubnetLabels = @($subnets | Where-Object { $_.CIDR -match ':' } | ForEach-Object { $_.CIDR })
if ($v6SubnetLabels.Count -gt 0) {
    Write-Host "  • IPv6 subnet(s): $($v6SubnetLabels -join ', ') (not swept; ND/ARP + optional /120+ -Cidr)" -ForegroundColor White
}
Write-Host "  • Total Devices: $($nodes.Count)" -ForegroundColor White
Write-Host "  • Connections: $($topology.Edges.Count)" -ForegroundColor White

Write-Host "`nGenerated Files:" -ForegroundColor Cyan
Write-Host "  1. $OutputPath" -ForegroundColor White
Write-Host "     → Open in draw.io: https://app.diagrams.net/" -ForegroundColor Gray
Write-Host "  2. $inventoryPath" -ForegroundColor White
Write-Host "     → Edit this file to add device details" -ForegroundColor Gray

Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "  • Open the diagram in draw.io (web or desktop)" -ForegroundColor White
Write-Host "  • Customize device roles in $inventoryPath" -ForegroundColor White
Write-Host "  • Re-run: Import-Inventory '$inventoryPath' | Export-DrawIO -OutFile '$OutputPath'" -ForegroundColor White
Write-Host ""
