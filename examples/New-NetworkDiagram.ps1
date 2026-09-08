#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Quick-start wizard to discover and diagram your network
.DESCRIPTION
    This script automatically discovers your network configuration and creates a professional network diagram.
    No configuration files needed - just run it!
.PARAMETER ScanDepth
    How deep to scan the detected subnet: Quick (up to 8 hosts sampled across the range),
    Medium (first 50 hosts), Full (all usable hosts, capped at a /22 = 1022 hosts for
    larger subnets). Host addresses are derived from the interface's real CIDR prefix.
.PARAMETER OutputPath
    Where to save the diagram (default: .\my-network.drawio)
.PARAMETER InterfaceName
    Interface name or numeric interface index to scan. By default, the interface
    used by the active IPv4 default route is selected.
.PARAMETER DnsTimeoutSeconds
    Maximum time for each reverse DNS lookup during discovery (default: 2 seconds).
.EXAMPLE
    .\New-NetworkDiagram.ps1

    Quick scan and diagram of your network
.EXAMPLE
    .\New-NetworkDiagram.ps1 -ScanDepth Medium -OutputPath .\office-network.drawio

    Medium scan with custom output location
#>

[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Medium', 'Full')]
    [string]$ScanDepth = 'Quick',

    [string]$OutputPath = '.\my-network.drawio',

    [string]$InterfaceName,

    [ValidateRange(1, 30)]
    [int]$DnsTimeoutSeconds = 2
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

function Select-ScanInterface {
    param(
        [Parameter(Mandatory)][object[]]$Interfaces,
        [string]$RequestedInterface,
        [string]$DefaultInterfaceName,
        [Nullable[int]]$DefaultInterfaceIndex
    )

    if ($Interfaces.Count -eq 0) {
        throw 'No active IPv4 network interfaces were found.'
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedInterface)) {
        $matchingInterfaces = @($Interfaces | Where-Object {
            $_.Name -eq $RequestedInterface -or
            ($null -ne $_.Index -and "$($_.Index)" -eq $RequestedInterface)
        })
        if ($matchingInterfaces.Count -eq 0) {
            throw "Network interface '$RequestedInterface' was not found. Available interfaces: $($Interfaces.Name -join ', ')"
        }
        if ($matchingInterfaces.Count -gt 1) {
            throw "Network interface '$RequestedInterface' is ambiguous. Use its numeric interface index."
        }
        return $matchingInterfaces[0]
    }

    $routeMatches = @($Interfaces | Where-Object {
        (-not [string]::IsNullOrWhiteSpace($DefaultInterfaceName) -and $_.Name -eq $DefaultInterfaceName) -or
        ($null -ne $DefaultInterfaceIndex -and $_.Index -eq $DefaultInterfaceIndex)
    })
    if ($routeMatches.Count -eq 1) {
        return $routeMatches[0]
    }
    if ($routeMatches.Count -gt 1) {
        throw 'The default route maps to multiple IPv4 addresses. Select one with -InterfaceName.'
    }
    if ($Interfaces.Count -eq 1) {
        return $Interfaces[0]
    }

    throw 'No IPv4 default-route interface could be selected. Use -InterfaceName with an available interface name or index.'
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

# Cross-platform network discovery
if ($IsWindows -or $PSVersionTable.PSVersion.Major -lt 6 -or $null -eq $IsWindows) {
    # Windows: Use native cmdlets
    $interfaces = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
    } | ForEach-Object {
        [pscustomobject]@{
            Name = $_.InterfaceAlias
            Index = $_.InterfaceIndex
            IPAddress = $_.IPAddress
            PrefixLength = $_.PrefixLength
        }
    })
    
    # Get gateway
    $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' }
    $defaultRoute = $routes | Sort-Object RouteMetric | Select-Object -First 1
    $primaryInterface = Select-ScanInterface -Interfaces $interfaces -RequestedInterface $InterfaceName `
        -DefaultInterfaceIndex $defaultRoute.InterfaceIndex
    $selectedRoute = $routes | Where-Object { $_.InterfaceIndex -eq $primaryInterface.Index } |
        Sort-Object RouteMetric | Select-Object -First 1
    $gateway = $selectedRoute.NextHop
    
    # Get DNS
    $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $primaryInterface.Index -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        Select-Object -ExpandProperty ServerAddresses -Unique |
        Where-Object { $_ -notmatch '^(127\.|::1|fe80:)' } |
        Select-Object -First 3)
} else {
    # macOS/Linux: Parse ifconfig/ip commands
    if ($IsMacOS) {
        # Use ifconfig on macOS
        $ifconfigOutput = & ifconfig -a 2>&1
        $interfaces = @(ConvertFrom-MacOSInterfaceText -Lines $ifconfigOutput)
        
        # Get default gateway using route command
        $routeOutput = & route -n get default 2>&1
        $gatewayMatch = [regex]::Match(($routeOutput -join "`n"), 'gateway:\s+(\d+\.\d+\.\d+\.\d+)')
        $routeInterfaceMatch = [regex]::Match(($routeOutput -join "`n"), 'interface:\s+(\S+)')
        if ($gatewayMatch.Success) {
            $gateway = $gatewayMatch.Groups[1].Value
        } else {
            $gateway = $null
        }
        $defaultInterfaceName = if ($routeInterfaceMatch.Success) { $routeInterfaceMatch.Groups[1].Value } else { $null }
        $primaryInterface = Select-ScanInterface -Interfaces $interfaces -RequestedInterface $InterfaceName `
            -DefaultInterfaceName $defaultInterfaceName
        if ($InterfaceName -and $primaryInterface.Name -ne $defaultInterfaceName) {
            $gateway = $null
        }
        
        # Get DNS servers from /etc/resolv.conf or scutil
        $dnsOutput = & scutil --dns 2>&1
        $dnsText = $dnsOutput -join "`n"
        $dnsMatches = [regex]::Matches($dnsText, 'nameserver\[\d+\]\s*:\s*(\d+\.\d+\.\d+\.\d+)')
        $dnsServers = @($dnsMatches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique -First 3)
        
        if ($dnsServers.Count -eq 0) {
            # Fallback to /etc/resolv.conf
            if (Test-Path '/etc/resolv.conf') {
                $resolvConf = Get-Content '/etc/resolv.conf' -ErrorAction SilentlyContinue
                $dnsServers = @($resolvConf | Where-Object { $_ -match '^nameserver\s+(\d+\.\d+\.\d+\.\d+)' } | 
                    ForEach-Object { $matches[1] } | Select-Object -Unique -First 3)
            }
        }
    } elseif ($IsLinux) {
        # Use ip command on Linux
        $ipOutput = & ip -4 addr show 2>&1
        $interfaces = @(ConvertFrom-LinuxInterfaceText -Lines $ipOutput)
        
        # Get default gateway
        $routeOutput = & ip route show default 2>&1
        $gatewayMatch = [regex]::Match(($routeOutput -join "`n"), 'default\s+via\s+(\d+\.\d+\.\d+\.\d+)')
        $routeInterfaceMatch = [regex]::Match(($routeOutput -join "`n"), '\bdev\s+(\S+)')
        if ($gatewayMatch.Success) {
            $gateway = $gatewayMatch.Groups[1].Value
        } else {
            $gateway = $null
        }
        $defaultInterfaceName = if ($routeInterfaceMatch.Success) { $routeInterfaceMatch.Groups[1].Value } else { $null }
        $primaryInterface = Select-ScanInterface -Interfaces $interfaces -RequestedInterface $InterfaceName `
            -DefaultInterfaceName $defaultInterfaceName
        if ($InterfaceName -and $primaryInterface.Name -ne $defaultInterfaceName) {
            $gateway = $null
        }
        
        # Get DNS servers from /etc/resolv.conf
        $dnsServers = @()
        if (Test-Path '/etc/resolv.conf') {
            $resolvConf = Get-Content '/etc/resolv.conf' -ErrorAction SilentlyContinue
            $dnsServers = @($resolvConf | Where-Object { $_ -match '^nameserver\s+(\d+\.\d+\.\d+\.\d+)' } | 
                ForEach-Object { $matches[1] } | Select-Object -Unique -First 3)
        }
    }
    
}

$myIP = $primaryInterface.IPAddress
$prefix = $primaryInterface.PrefixLength

Write-Host "      Found $($interfaces.Count) active network interface(s)" -ForegroundColor Green

Write-Host "      Interface: $($primaryInterface.Name)" -ForegroundColor Cyan
Write-Host "      Your IP: $myIP/$prefix" -ForegroundColor Cyan
Write-Host "      Gateway: $gateway" -ForegroundColor Cyan
Write-Host "      DNS: $($dnsServers -join ', ')" -ForegroundColor Cyan

# Step 2: Build initial topology
Write-Host "`n[2/5] Building network topology..." -ForegroundColor Yellow

$nodes = @()
$edges = @()
$subnets = @()

# Calculate subnet from the actual IP + prefix (real CIDR math, not a /24 assumption)
$prefixInt = [int]$prefix
if ($prefixInt -lt 0 -or $prefixInt -gt 32) {
    Write-Host "      Prefix /$prefixInt is invalid; defaulting to /24" -ForegroundColor Yellow
    $prefixInt = 24
}

$ipValue        = ConvertTo-UInt32Address $myIP
$mask           = Get-PrefixMask -PrefixLength $prefixInt
$networkValue   = $ipValue -band $mask
$broadcastValue = [uint32](($networkValue -bor ((-bnot $mask) -band [uint32]4294967295)))
$networkAddress = ConvertFrom-UInt32Address $networkValue
$cidr           = "$networkAddress/$prefixInt"

$subnets += [pscustomobject]@{
    CIDR = $cidr
    Label = "Local Network"
    VLAN = $null
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

# Enumerate real host addresses from the actual prefix. Usable hosts are between the
# network and broadcast addresses (for /31 and /32 there is no usable-host range).
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

# Materialize scan targets as IP strings before the parallel block (the CIDR helper
# functions are not available inside ForEach-Object -Parallel runspaces).
$scanTargets = @($hostValues | ForEach-Object { ConvertFrom-UInt32Address $_ })

Write-Host "      Scan depth: $ScanDepth ($($scanTargets.Count) addresses in $cidr)" -ForegroundColor Cyan
Write-Host "      This may take 10-60 seconds..." -ForegroundColor Gray

$discovered = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

$scanTargets | ForEach-Object -Parallel {
    $testIP = $_

    # Skip IPs we already have
    if ($testIP -in @($using:myIP, $using:gateway) + $using:dnsServers) {
        return
    }

    $result = Test-Connection -ComputerName $testIP -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue

    if ($result) {
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
    }
} -ThrottleLimit 20

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

        if ($gateway) {
            $edges += [pscustomobject]@{
                SourceIP = $gateway
                TargetIP = $device.IP
                Label = 'LAN'
                Source = 'Discovery'
                Confidence = 'L3-Inferred'
            }
        }
    }
} else {
    Write-Host "      No additional devices found (ICMP may be blocked)" -ForegroundColor Yellow
}

# Step 4: Test reachability
Write-Host "`n[4/5] Testing connectivity..." -ForegroundColor Yellow

foreach ($node in $nodes) {
    if ($null -eq $node.Reachable) {
        $node.Reachable = Test-Connection -ComputerName $node.IP -Count 1 -TimeoutSeconds 2 -Quiet -ErrorAction SilentlyContinue
    }
}

$reachableCount = @($nodes | Where-Object { $_.Reachable }).Count
Write-Host "      $reachableCount of $($nodes.Count) devices are reachable" -ForegroundColor Green

# Create topology object
$topology = [pscustomobject]@{
    Nodes = $nodes
    Edges = Merge-Edges -Edges $edges
    Subnets = $subnets
}

# Step 5: Generate diagram
Write-Host "`n[5/5] Generating your network diagram..." -ForegroundColor Yellow

$inventoryPath = Get-InventoryOutputPath -DiagramPath $OutputPath
$topology | Export-DrawIO -OutFile $OutputPath

if (Test-Path $OutputPath) {
    $fileSize = (Get-Item $OutputPath).Length
    Write-Host "      ✓ Created: $OutputPath ($fileSize bytes)" -ForegroundColor Green
}

# Save inventory for future use. Every accepted diagram extension produces a
# distinct sibling inventory file.
$inventoryData = @{
    knownDevices = @($nodes | ForEach-Object {
        @{
            ip = $_.IP
            hostname = $_.Hostname
            role = $_.Role
            vendor = $_.Vendor
            os = $_.OS
        }
    })
    subnets = @($subnets | ForEach-Object {
        @{
            cidr = $_.CIDR
            label = $_.Label
            vlan = $_.VLAN
        }
    })
}

$inventoryData | ConvertTo-Json -Depth 10 | Out-File -FilePath $inventoryPath -Encoding utf8 -Force
Write-Host "      ✓ Saved inventory: $inventoryPath" -ForegroundColor Green

# Summary
Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                  Success!                                  ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green

Write-Host "`nYour Network:" -ForegroundColor Cyan
Write-Host "  • Computer: $computerName ($myIP)" -ForegroundColor White
Write-Host "  • Subnet: $cidr" -ForegroundColor White
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
