#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Quick-start wizard to discover and diagram your network
.DESCRIPTION
    This script automatically discovers your network configuration and creates a professional network diagram.
    No configuration files needed - just run it!
.PARAMETER ScanDepth
    How deep to scan: Quick (common IPs only), Medium (first 50 IPs), Full (all 254 IPs)
.PARAMETER OutputPath
    Where to save the diagram (default: .\my-network.drawio)
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

    [string]$OutputPath = '.\my-network.drawio'
)

# Import the module
$modulePath = Join-Path $PSScriptRoot '..\NetDiagram-PS\NetDiagram-PS.psd1'
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
    $interfaces = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown'
    }
    
    if ($interfaces.Count -eq 0) {
        Write-Host "✗ No active network interfaces found!" -ForegroundColor Red
        exit 1
    }
    
    $primaryInterface = $interfaces | Select-Object -First 1
    $myIP = $primaryInterface.IPAddress
    $prefix = $primaryInterface.PrefixLength
    
    # Get gateway
    $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' }
    $gateway = $routes | Select-Object -First 1 -ExpandProperty NextHop
    
    # Get DNS
    $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        Select-Object -ExpandProperty ServerAddresses -Unique |
        Where-Object { $_ -notmatch '^(127\.|::1|fe80:)' } |
        Select-Object -First 3)
} else {
    # macOS/Linux: Parse ifconfig/ip commands
    if ($IsMacOS) {
        # Use ifconfig on macOS
        $ifconfigOutput = & ifconfig -a 2>&1
        $ifconfigText = $ifconfigOutput -join "`n"
        
        # Parse for active IPv4 addresses
        $ipMatches = [regex]::Matches($ifconfigText, 'inet\s+(\d+\.\d+\.\d+\.\d+)\s+netmask\s+0x([0-9a-f]+)')
        $interfaces = @()
        
        foreach ($match in $ipMatches) {
            $ip = $match.Groups[1].Value
            if ($ip -ne '127.0.0.1') {
                # Convert hex netmask to prefix length
                $hexMask = $match.Groups[2].Value
                $binaryMask = [Convert]::ToString([Convert]::ToInt64($hexMask, 16), 2)
                $prefix = ($binaryMask.ToCharArray() | Where-Object { $_ -eq '1' }).Count
                
                $interfaces += [PSCustomObject]@{
                    IPAddress = $ip
                    PrefixLength = $prefix
                }
            }
        }
        
        # Get default gateway using route command
        $routeOutput = & route -n get default 2>&1
        $gatewayMatch = [regex]::Match(($routeOutput -join "`n"), 'gateway:\s+(\d+\.\d+\.\d+\.\d+)')
        if ($gatewayMatch.Success) {
            $gateway = $gatewayMatch.Groups[1].Value
        } else {
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
        $ipText = $ipOutput -join "`n"
        
        # Parse for active IPv4 addresses
        $ipMatches = [regex]::Matches($ipText, 'inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)')
        $interfaces = @()
        
        foreach ($match in $ipMatches) {
            $ip = $match.Groups[1].Value
            if ($ip -ne '127.0.0.1') {
                $interfaces += [PSCustomObject]@{
                    IPAddress = $ip
                    PrefixLength = [int]$match.Groups[2].Value
                }
            }
        }
        
        # Get default gateway
        $routeOutput = & ip route show default 2>&1
        $gatewayMatch = [regex]::Match(($routeOutput -join "`n"), 'default\s+via\s+(\d+\.\d+\.\d+\.\d+)')
        if ($gatewayMatch.Success) {
            $gateway = $gatewayMatch.Groups[1].Value
        } else {
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
    
    if ($interfaces.Count -eq 0) {
        Write-Host "✗ No active network interfaces found!" -ForegroundColor Red
        exit 1
    }
    
    $primaryInterface = $interfaces | Select-Object -First 1
    $myIP = $primaryInterface.IPAddress
    $prefix = $primaryInterface.PrefixLength
}

Write-Host "      Found $($interfaces.Count) active network interface(s)" -ForegroundColor Green

Write-Host "      Your IP: $myIP/$prefix" -ForegroundColor Cyan
Write-Host "      Gateway: $gateway" -ForegroundColor Cyan
Write-Host "      DNS: $($dnsServers -join ', ')" -ForegroundColor Cyan

# Step 2: Build initial topology
Write-Host "`n[2/5] Building network topology..." -ForegroundColor Yellow

$nodes = @()
$edges = @()
$subnets = @()

# Calculate subnet
$ipParts = $myIP.Split('.')
$subnet = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2])"
$cidr = "$subnet.0/$prefix"

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

$scanRanges = switch ($ScanDepth) {
    'Quick'  { @(1, 2, 10, 20, 50, 100, 200, 254) }
    'Medium' { 1..50 }
    'Full'   { 1..254 }
}

Write-Host "      Scan depth: $ScanDepth ($($scanRanges.Count) addresses)" -ForegroundColor Cyan
Write-Host "      This may take 10-60 seconds..." -ForegroundColor Gray

$discovered = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

$scanRanges | ForEach-Object -Parallel {
    $testIP = "$using:subnet.$_"

    # Skip IPs we already have
    if ($testIP -in @($using:myIP, $using:gateway) + $using:dnsServers) {
        return
    }

    $result = Test-Connection -ComputerName $testIP -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue

    if ($result) {
        $hostname = try {
            $resolved = [System.Net.Dns]::GetHostEntry($testIP)
            $resolved.HostName
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

$topology | Export-DrawIO -OutFile $OutputPath

if (Test-Path $OutputPath) {
    $fileSize = (Get-Item $OutputPath).Length
    Write-Host "      ✓ Created: $OutputPath ($fileSize bytes)" -ForegroundColor Green
}

# Save inventory for future use
$inventoryPath = $OutputPath -replace '\.drawio$', '-inventory.json'
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
