#Requires -Version 7.4

<#
.SYNOPSIS
    NetDiagram-PS - Network discovery and diagram generation module
.DESCRIPTION
    Discovers network nodes/links and emits valid .drawio files with SNMP support
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-level variables
$script:ModuleVersion = '1.3.0'

#region Helper Functions

function Get-LayerFromRole {
    <#
    .SYNOPSIS
        Maps device role to network layer for diagram placement
    #>
    param([string]$Role)

    switch ($Role) {
        'core-router' { return 'Core' }
        'router'      { return 'Core' }
        'distribution'{ return 'Dist' }
        'switch'      { return 'Access' }
        'server'      { return 'Servers' }
        default       { return 'Access' }
    }
}

function New-EmptyTopology {
    <#
    .SYNOPSIS
        Creates an empty topology object
    #>
    [pscustomobject]@{
        Nodes   = @()
        Edges   = @()
        Subnets = @()
    }
}

# ── IPv4 CIDR helpers (moved from examples/New-NetworkDiagram.ps1 for #35)
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
    }
    elseif ($ScanDepth -eq 'Quick') {
        $sampleCount = [int][Math]::Min(8, $usableCount)
        for ($s = 0; $s -lt $sampleCount; $s++) {
            $idx = [int][Math]::Floor($s * $usableCount / $sampleCount)
            $null = $hostValues.Add([uint32]($firstHost + $idx))
        }
    }
    elseif ($ScanDepth -eq 'Medium') {
        $take = [int][Math]::Min(50, $usableCount)
        for ($i = 0; $i -lt $take; $i++) { $null = $hostValues.Add([uint32]($firstHost + $i)) }
    }
    else {
        $take = [int][Math]::Min($usableCount, $MaxScanHosts)
        for ($i = 0; $i -lt $take; $i++) { $null = $hostValues.Add([uint32]($firstHost + $i)) }
    }
    return @($hostValues)
}

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

function ConvertTo-NormalizedIPv4Address {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Invalid inventory $Context '$Value': expected an IPv4 address. IPv6 is not supported."
    }
    return $address.ToString()
}

function ConvertTo-NormalizedIPv4Cidr {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Value -notmatch '^(.+)\/(\d{1,2})$') {
        throw "Invalid inventory $Context '$Value': expected IPv4 CIDR notation."
    }

    $address = ConvertTo-NormalizedIPv4Address -Value $matches[1] -Context $Context
    $prefixLength = [int]$matches[2]
    if ($prefixLength -gt 32) {
        throw "Invalid inventory $Context '$Value': IPv4 prefix must be between 0 and 32."
    }

    $bytes = ([System.Net.IPAddress]::Parse($address)).GetAddressBytes()
    $bitsRemaining = $prefixLength
    for ($index = 0; $index -lt $bytes.Count; $index++) {
        $mask = if ($bitsRemaining -ge 8) {
            255
        }
        elseif ($bitsRemaining -le 0) {
            0
        }
        else {
            256 - [Math]::Pow(2, 8 - $bitsRemaining)
        }
        $bytes[$index] = [byte]($bytes[$index] -band [int]$mask)
        $bitsRemaining -= 8
    }

    return "$([System.Net.IPAddress]::new($bytes))/$prefixLength"
}

#endregion

#region Import-Inventory

function Import-Inventory {
    <#
    .SYNOPSIS
        Imports network inventory from JSON file
    .DESCRIPTION
        Reads a JSON inventory file and creates a Topology object with Nodes and Subnets.
        The stable inventory contract is IPv4-only. Device addresses and subnet CIDRs
        are validated and normalized; subnet host bits are cleared. Duplicate device
        addresses are rejected. Unknown or omitted roles are retained and placed in the
        Access layer.
    .PARAMETER Path
        Path to the inventory JSON file
    .EXAMPLE
        $topo = Import-Inventory -Path '.\examples\inventory-template.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Path
    )

    process {
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            throw "Inventory file not found: $Path"
        }

        try {
            $inventory = Get-Content -Path $Path -Raw | ConvertFrom-Json
        }
        catch {
            throw "Failed to parse inventory JSON: $_"
        }

        if (-not $inventory.PSObject.Properties['knownDevices']) {
            throw "Invalid inventory: missing 'knownDevices' property"
        }
        if ($null -eq $inventory.knownDevices -or
            $inventory.knownDevices -is [string] -or
            $inventory.knownDevices -isnot [System.Collections.IEnumerable]) {
            throw "Invalid inventory: 'knownDevices' must be an array"
        }
        if ($inventory.PSObject.Properties['subnets'] -and
            ($null -eq $inventory.subnets -or $inventory.subnets -is [string] -or
             $inventory.subnets -isnot [System.Collections.IEnumerable])) {
            throw "Invalid inventory: 'subnets' must be an array when present"
        }

        $topology = New-EmptyTopology
        $deviceAddresses = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        # Process known devices
        $deviceIndex = 0
        $nodes = foreach ($device in @($inventory.knownDevices)) {
            if ($null -eq $device -or -not $device.PSObject.Properties['ip'] -or
                $device.ip -isnot [string] -or [string]::IsNullOrWhiteSpace($device.ip)) {
                throw "Invalid inventory knownDevices[$deviceIndex]: missing string 'ip'"
            }

            $normalizedIP = ConvertTo-NormalizedIPv4Address -Value $device.ip -Context "knownDevices[$deviceIndex].ip"
            if (-not $deviceAddresses.Add($normalizedIP)) {
                throw "Invalid inventory knownDevices[$deviceIndex].ip '$normalizedIP': duplicate device address"
            }

            $role = if ($device.PSObject.Properties['role']) { $device.role } else { 'unknown' }
            $layer = Get-LayerFromRole -Role $role

            [pscustomobject]@{
                IP        = $normalizedIP
                Hostname  = if ($device.PSObject.Properties['hostname'] -and -not [string]::IsNullOrWhiteSpace($device.hostname)) { $device.hostname } else { $normalizedIP }
                Role      = $role
                Vendor    = if ($device.PSObject.Properties['vendor']) { $device.vendor } else { 'Unknown' }
                OS        = if ($device.PSObject.Properties['os']) { $device.os } else { 'Unknown' }
                Layer     = $layer
                Reachable = $null
            }
            $deviceIndex++
        }

        $topology.Nodes = @($nodes)

        # Process subnets if present
        if ($inventory.PSObject.Properties['subnets'] -and $inventory.subnets) {
            $subnetIndex = 0
            $subnetCidrs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $subnets = foreach ($subnet in @($inventory.subnets)) {
                if ($null -eq $subnet -or -not $subnet.PSObject.Properties['cidr'] -or
                    $subnet.cidr -isnot [string] -or [string]::IsNullOrWhiteSpace($subnet.cidr)) {
                    throw "Invalid inventory subnets[$subnetIndex]: missing string 'cidr'"
                }

                $normalizedCidr = ConvertTo-NormalizedIPv4Cidr -Value $subnet.cidr -Context "subnets[$subnetIndex].cidr"
                if (-not $subnetCidrs.Add($normalizedCidr)) {
                    throw "Invalid inventory subnets[$subnetIndex].cidr '$normalizedCidr': duplicate subnet"
                }

                [pscustomobject]@{
                    CIDR  = $normalizedCidr
                    Label = if ($subnet.PSObject.Properties['label'] -and -not [string]::IsNullOrWhiteSpace($subnet.label)) { $subnet.label } else { $normalizedCidr }
                    VLAN  = if ($subnet.PSObject.Properties['vlan']) { $subnet.vlan } else { $null }
                }
                $subnetIndex++
            }
            $topology.Subnets = @($subnets)
        }

        Write-Verbose "Imported $($topology.Nodes.Count) nodes and $($topology.Subnets.Count) subnets"

        return $topology
    }
}

function Import-NmapScan {
    <#
    .SYNOPSIS
        Imports topology from nmap XML output
    .DESCRIPTION
        Parses nmap -oX XML and returns a Topology with Nodes derived from hosts
        whose status is up. Maps address/hostname/vendor/OS/ports. Role stays
        unknown unless nmap data clearly indicates otherwise.
    .PARAMETER Path
        Path to nmap XML file
    .EXAMPLE
        Import-NmapScan -Path scan.xml | Export-DrawIO -OutFile net.drawio
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "nmap file not found: '$Path'"
    }
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw
    }
    catch {
        throw "Failed to parse nmap XML file '$Path': $_"
    }
    if (-not $xml.PSObject.Properties['nmaprun'] -or $null -eq $xml.nmaprun) {
        throw "Invalid nmap XML file '$Path': missing required element 'nmaprun'."
    }

    $topo = New-EmptyTopology
    $nodes = @()
    foreach ($hostNode in @($xml.nmaprun.host)) {
        $state = $hostNode.status.state
        if ($state -and $state -ne 'up') { continue }

        $ipv4 = $null
        foreach ($addr in @($hostNode.address)) {
            if ($addr.addrtype -eq 'ipv4' -and $addr.addr) { $ipv4 = $addr.addr; break }
        }
        if (-not $ipv4) { continue }

        try { $null = [System.Net.IPAddress]::Parse($ipv4) } catch { continue }

        $hostname = $ipv4
        if ($hostNode.PSObject.Properties['hostnames'] -and $hostNode.hostnames -and $hostNode.hostnames.PSObject.Properties['hostname'] -and $hostNode.hostnames.hostname) {
            $hn = @($hostNode.hostnames.hostname)[0]
            if ($hn.PSObject.Properties['name'] -and $hn.name) { $hostname = $hn.name }
        }

        $vendor = 'Unknown'
        foreach ($addr in @($hostNode.address)) {
            if ($addr.addrtype -eq 'mac' -and $addr.PSObject.Properties['vendor'] -and $addr.vendor) { $vendor = $addr.vendor; break }
        }

        $os = 'Unknown'
        if ($hostNode.PSObject.Properties['os'] -and $hostNode.os -and $hostNode.os.PSObject.Properties['osmatch'] -and $hostNode.os.osmatch -and @($hostNode.os.osmatch)[0].PSObject.Properties['name'] -and @($hostNode.os.osmatch)[0].name) {
            $os = @($hostNode.os.osmatch)[0].name
        }

        $ports = @()
        if ($hostNode.PSObject.Properties['ports'] -and $hostNode.ports -and $hostNode.ports.PSObject.Properties['port'] -and $hostNode.ports.port) {
            foreach ($p in @($hostNode.ports.port)) {
                if ($p.PSObject.Properties['state'] -and $p.state -and $p.state.PSObject.Properties['state'] -and $p.state.state -eq 'open' -and $p.PSObject.Properties['portid'] -and $p.portid) { $ports += $p.portid }
            }
        }

        $mac = ''
        foreach ($addr in @($hostNode.address)) {
            if ($addr.addrtype -eq 'mac' -and $addr.addr) { $mac = $addr.addr; break }
        }

        $nodes += [pscustomobject]@{
            IP         = $ipv4
            Hostname   = $hostname
            Role       = 'unknown'
            Vendor     = $vendor
            OS         = $os
            Layer      = Get-LayerFromRole -Role 'unknown'
            Reachable  = $null
            MACAddress = $mac
            OpenPorts  = $ports
        }
    }

    $topo.Nodes = @($nodes)
    return $topo
}

#endregion

#region Test-DeviceReachability

function Test-DeviceReachability {
    <#
    .SYNOPSIS
        Tests network reachability for all nodes in a topology
    .DESCRIPTION
        Uses Test-Connection with parallel processing to quickly test device reachability.
        Updates the Reachable property on each node.
    .PARAMETER Topology
        Topology object from Import-Inventory
    .PARAMETER MaxParallel
        Maximum number of parallel ping tests (default: 32)
    .PARAMETER TimeoutSeconds
        Timeout for each ping test (default: 1)
    .PARAMETER TcpFallbackPort
        If ICMP fails, try TCP connect to this port to promote an ICMP-silent host to reachable
    .EXAMPLE
        $topo = Import-Inventory -Path '.\my-inventory.json' | Test-DeviceReachability -MaxParallel 64
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter()]
        [int]$MaxParallel = 32,

        [Parameter()]
        [int]$TimeoutSeconds = 1,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int]$TcpFallbackPort,

        [Parameter(DontShow)]
        [scriptblock]$ProbeScript
    )

    process {
        if ($null -eq $Topology -or $null -eq $Topology.Nodes) {
            throw "Invalid topology object"
        }

        if ($Topology.Nodes.Count -eq 0) {
            Write-Warning "No nodes to test"
            return $Topology
        }

        Write-Verbose "Testing reachability for $($Topology.Nodes.Count) nodes with $MaxParallel parallel threads"

        # Create a synchronized hashtable for results (tri-state: $true/$false/$null)
        $results = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
        $tcpPort = $TcpFallbackPort
        $probe = $ProbeScript

        if ($probe) {
            # Test seam: ProbeScript returns $true/$false/$null directly per IP
            foreach ($node in $Topology.Nodes) {
                try {
                    $r = & $probe $node.IP
                    $null = $results.TryAdd($node.IP, $r)
                }
                catch { $null = $results.TryAdd($node.IP, $null) }
            }
        }
        else {
            # Test reachability in parallel
            $Topology.Nodes | ForEach-Object -Parallel {
                $node = $_
                $timeout = $using:TimeoutSeconds
                $resultsDict = $using:results
                $fallbackPort = $using:tcpPort

                try {
                    $pingResult = Test-Connection -ComputerName $node.IP -Count 1 -TimeoutSeconds $timeout -ErrorAction Stop -Quiet
                    if ($pingResult -eq $true) {
                        $null = $resultsDict.TryAdd($node.IP, $true)
                        continue
                    }
                    if ($fallbackPort) {
                        try {
                            $tcp = [System.Net.Sockets.TcpClient]::new()
                            $task = $tcp.ConnectAsync($node.IP, $fallbackPort)
                            if ($task.Wait([TimeSpan]::FromSeconds($timeout))) {
                                $ok = $task.IsCompletedSuccessfully -and $tcp.Connected
                                $tcp.Dispose()
                                if ($ok) { $null = $resultsDict.TryAdd($node.IP, $true); continue }
                            } else { $tcp.Dispose() }
                        } catch {}
                    }
                    $null = $resultsDict.TryAdd($node.IP, $false)
                }
                catch {
                    $null = $resultsDict.TryAdd($node.IP, $null)
                }
            } -ThrottleLimit $MaxParallel
        }

        # Update nodes with results
        $indeterminateCount = 0
        foreach ($node in $Topology.Nodes) {
            $val = $null
            $found = $results.TryGetValue($node.IP, [ref]$val)
            if ($found) {
                if ($null -eq $val) { $indeterminateCount++ }
                $node.Reachable = $val
            }
            else {
                $node.Reachable = $null
                $indeterminateCount++
            }
        }
        if ($indeterminateCount -gt 0) {
            Write-Warning "Reachability indeterminate for $indeterminateCount node(s): local probe could not be sent (no route or insufficient privilege) — not marked as unreachable."
        }

        $reachableCount = @($Topology.Nodes | Where-Object { $_.Reachable -eq $true }).Count
        Write-Verbose "Reachability test complete: $reachableCount/$($Topology.Nodes.Count) nodes reachable"

        return $Topology
    }
}

#endregion

#region SNMP Functions

function Invoke-SnmpWalk {
    <#
    .SYNOPSIS
        Invokes the net-snmp snmpwalk binary against a target device
    .DESCRIPTION
        Calls snmpwalk directly (must be in PATH) with specified OID and credentials.
        Resolves 'snmpwalk' on macOS/Linux and 'snmpwalk.exe' on Windows.
        Returns raw output lines.

        SECURITY - PROCESS LIST EXPOSURE (known limitation): snmpwalk receives the
        community string as a command-line argument ('-c <community>'). While it runs,
        the community is visible to any local user who can list processes (ps, Get-Process
        with command-line access, /proc). This is inherent to shelling out to net-snmp and
        cannot be avoided without a native SNMP client. Verbose logging in this function
        redacts the community (prints '-c ****'), but the process arguments themselves are
        not redacted. Treat SNMP v1/v2c community strings as low-secrecy and prefer SNMPv3
        with authentication for anything sensitive.
    .PARAMETER TargetIP
        IP address or hostname (FQDN) to query. Must not begin with '-'.
    .PARAMETER Community
        SNMP community string. Must not begin with '-' (argument-injection guard).
    .PARAMETER OID
        OID to walk (default: LLDP remote table). Digits and dots only.
    .PARAMETER Version
        SNMP version: v1, v2c, or v3 (default: v2c)
    .PARAMETER TimeoutSeconds
        Timeout in seconds (default: 2)
    .EXAMPLE
        Invoke-SnmpWalk -TargetIP '10.66.1.1' -Community 'public'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({
            if ($_ -match '^-') { throw "TargetIP must not begin with '-'." }
            if ($_ -notmatch '^(?:\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*)$') {
                throw "TargetIP '$_' is not a valid IPv4 address or hostname."
            }
            $true
        })]
        [string]$TargetIP,

        [Parameter(Mandatory)]
        [ValidateScript({
            if ($_ -match '^-') { throw "Community must not begin with '-' (argument-injection guard)." }
            $true
        })]
        [string]$Community,

        [Parameter()]
        [ValidatePattern('^\d+(\.\d+)*$')]
        [string]$OID = '1.0.8802.1.1.2.1.4',

        [Parameter()]
        [ValidateSet('v1', 'v2c', 'v3')]
        [string]$Version = 'v2c',

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 2
    )

    # Locate the snmpwalk binary. It is 'snmpwalk.exe' on Windows and 'snmpwalk'
    # on macOS/Linux, so probe for both rather than assuming the Windows name.
    # Restrict to Application so a same-named function/alias/script cannot be invoked.
    $snmpWalkCmd = $null
    foreach ($candidate in @('snmpwalk', 'snmpwalk.exe')) {
        $found = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $snmpWalkCmd = $found.Source
            break
        }
    }
    if (-not $snmpWalkCmd) {
        throw "snmpwalk not found in PATH. Please install net-snmp tools (brew install net-snmp, apt install snmp, or choco install net-snmp)."
    }

    try {
        $arguments = @(
            '-' + $Version.ToLower()
            '-c', $Community
            '-t', $TimeoutSeconds.ToString()
            $TargetIP
            $OID
        )

        # Never emit the community string in verbose output. Redact '-c <community>'
        # to '-c ****'. (The community is still visible in the process argument list
        # while snmpwalk runs - see the SECURITY note in the function help.)
        $redactedArgs = @(
            '-' + $Version.ToLower()
            '-c', '****'
            '-t', $TimeoutSeconds.ToString()
            $TargetIP
            $OID
        )
        Write-Verbose "Running: $snmpWalkCmd $($redactedArgs -join ' ')"

        $output = & $snmpWalkCmd @arguments 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "snmpwalk failed for $TargetIP with exit code $LASTEXITCODE"
            return @()
        }

        return $output
    }
    catch {
        Write-Warning "Failed to execute snmpwalk for ${TargetIP}: $_"
        return @()
    }
}


function Get-SnmpNeighbors {
    <#
    .SYNOPSIS
        Discovers neighbors via SNMP LLDP/CDP (best-effort MVP)
    .DESCRIPTION
        Queries nodes for LLDP neighbor information via SNMP.
        Uses credential map to resolve community strings from SecretManagement.
        Adds discovered edges with provisional L2-SNMP-Heuristic confidence. The parser
        does not assign verified L2-SNMP confidence because it does not fully correlate
        structured LLDP/CDP table rows.

        CREDENTIAL MATCHING: The most specific matching IPv4 CIDR wins regardless of
        JSON property order. Default is used only when no CIDR matches. If the selected
        entry has no available community secret, the node is skipped unless -TryPublic
        was explicitly supplied.

        NODE ELIGIBILITY: By default every node is queried EXCEPT nodes that have been
        explicitly marked unreachable (Reachable -eq $false). Nodes with unknown
        reachability (Reachable -eq $null, e.g. straight after Import-Inventory) ARE
        queried, so the documented "import inventory then discover via SNMP" workflow
        works without first running Test-DeviceReachability. Pass -OnlyReachable to
        restrict querying to nodes proven reachable (Reachable -eq $true).

        PARSING IS BEST-EFFORT (MVP): the neighbor parser scans snmpwalk output for the
        first IPv4-looking token on each line and only creates an edge when that address
        already exists as a node in the topology. It does NOT fully decode the LLDP/CDP
        MIB rows (chassis-id / management-address / port-id sub-OIDs are not joined). It
        can miss neighbors and, on unusual output, misattribute a link. Treat the SNMP
        edges as hints to verify, not authoritative topology.
    .PARAMETER Topology
        Topology object with nodes
    .PARAMETER CredentialMapPath
        Path to credential map JSON file
    .PARAMETER OID
        SNMP OID to walk (default: LLDP remote table)
    .PARAMETER OnlyReachable
        Only query nodes proven reachable (Reachable -eq $true). Off by default so that
        freshly imported inventory (Reachable = $null) is still queried.
    .PARAMETER TryPublic
        If no credentials found for a node, try the common "public" community string.
        WARNING: This may be logged by security systems. Only use on networks you own.
    .EXAMPLE
        $topo = $topo | Get-SnmpNeighbors -CredentialMapPath '.\examples\credmap.json'
    .EXAMPLE
        $topo = $topo | Get-SnmpNeighbors -CredentialMapPath '.\credmap.json' -TryPublic

        Tries user credentials first, falls back to "public" if none found (with warning)
    .EXAMPLE
        $topo = $topo | Test-DeviceReachability | Get-SnmpNeighbors -CredentialMapPath '.\credmap.json' -OnlyReachable

        Ping-tests first, then queries only the nodes that answered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$CredentialMapPath,

        [Parameter()]
        [string]$OID = '1.0.8802.1.1.2.1.4',

        [Parameter()]
        [switch]$OnlyReachable,

        [Parameter()]
        [switch]$TryPublic
    )

    process {
        if ($null -eq $Topology -or $null -eq $Topology.Nodes) {
            throw "Invalid topology object"
        }

        if (-not (Test-Path -Path $CredentialMapPath -PathType Leaf)) {
            throw "Credential map file not found: $CredentialMapPath"
        }

        try {
            $credMap = Get-Content -Path $CredentialMapPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Failed to parse credential map JSON: $_"
        }

        # Show warning if -TryPublic is enabled
        if ($TryPublic) {
            Write-Warning @"
SECURITY WARNING: -TryPublic flag enabled
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
This will attempt to use the default SNMP community string "public"
on devices where no credentials are configured.

⚠️  This may be logged by network security systems
⚠️  Only use on networks you own or have authorization to scan
⚠️  Consider using SNMPv3 with authentication for production

All SNMP attempts will be logged to verbose output.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"@
        }

        # Decide which nodes to query. Default: everything that is not explicitly
        # unreachable (so freshly imported inventory with Reachable = $null is eligible).
        # -OnlyReachable narrows to nodes proven reachable (Reachable -eq $true).
        if ($OnlyReachable) {
            $nodesToQuery = @($Topology.Nodes | Where-Object { $_.Reachable -eq $true })
            $eligibilityDesc = 'reachable'
        }
        else {
            $nodesToQuery = @($Topology.Nodes | Where-Object { $_.Reachable -ne $false })
            $eligibilityDesc = 'eligible (reachable or untested)'
        }

        if ($nodesToQuery.Count -eq 0) {
            Write-Warning "No $eligibilityDesc nodes to query via SNMP"
            return $Topology
        }

        Write-Verbose "Querying SNMP neighbors for $($nodesToQuery.Count) $eligibilityDesc node(s)"

        $discoveredEdges = [System.Collections.ArrayList]::new()
        $publicAttempts = 0
        $snmpOutcomes = @{}
        $snmpCounts = @{ queried = $nodesToQuery.Count; answered = 0; skippedNoCredential = 0; skippedError = 0; skippedNoData = 0 }

        foreach ($node in $nodesToQuery) {
            # Resolve SNMP community for this node
            $community = $null
            $communitySecret = $null
            $source = 'CredentialMap'

            if ($credMap.PSObject.Properties['snmp'] -and $credMap.snmp) {
                $credentialMatch = Resolve-SnmpCredentialConfig -SnmpMap $credMap.snmp -IPAddress $node.IP
                if ($credentialMatch) {
                    $source = "CredentialMap:$($credentialMatch.CIDR)"
                    if ($credentialMatch.Config.PSObject.Properties['communitySecret']) {
                        $communitySecret = $credentialMatch.Config.communitySecret
                    }
                    else {
                        Write-Warning "SNMP credential entry '$($credentialMatch.CIDR)' has no communitySecret; skipping configured credential for $($node.IP)"
                    }
                }
            }

            # Try to get secret from SecretManagement
            if ($communitySecret) {
                try {
                    $secretModule = Get-Module -Name Microsoft.PowerShell.SecretManagement -ListAvailable -ErrorAction SilentlyContinue
                    if ($secretModule) {
                        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction SilentlyContinue
                        $communitySecretInfo = Get-Secret -Name $communitySecret -AsPlainText -ErrorAction SilentlyContinue
                        if ($communitySecretInfo) {
                            $community = $communitySecretInfo
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to retrieve secret '$communitySecret' for $($node.IP): $_"
                }
            }

            # Level 3: Try "public" if no credentials found and -TryPublic is enabled
            if ([string]::IsNullOrWhiteSpace($community) -and $TryPublic) {
                $community = 'public'
                $source = 'DefaultPublic'
                $publicAttempts++
                Write-Verbose "[TryPublic] Attempting default 'public' community for $($node.IP)"
            }

            if ([string]::IsNullOrWhiteSpace($community)) {
                Write-Warning "No SNMP community found for $($node.IP), skipping"
                $snmpOutcomes[$node.IP] = 'noCredential'
                $snmpCounts.skippedNoCredential++
                continue
            }

            # Invoke SNMP walk
            Write-Verbose "  Querying $($node.IP) with community from $source"
            $output = $null
            $snmpError = $null
            try {
                $output = Invoke-SnmpWalk -TargetIP $node.IP -Community $community -OID $OID -ErrorAction Stop
            }
            catch {
                $snmpError = $_.Exception.Message
                Write-Warning "SNMP query failed for $($node.IP): $snmpError"
                $snmpOutcomes[$node.IP] = 'error'
                $snmpCounts.skippedError++
                continue
            }

            if ($null -eq $output -or @($output).Count -eq 0) {
                Write-Verbose "No SNMP data returned from $($node.IP)"
                $snmpOutcomes[$node.IP] = 'noData'
                $snmpCounts.skippedNoData++
                continue
            }
            $snmpOutcomes[$node.IP] = 'answered'
            $snmpCounts.answered++

            # Parse LLDP/CDP output. BEST-EFFORT MVP (see function help): we do not fully
            # decode the LLDP MIB rows. For each output line we look only at the VALUE
            # portion (right of '='), never the OID itself (the numeric OID contains
            # dotted-decimal runs that would otherwise be mistaken for IPv4 addresses),
            # extract an octet-validated IPv4 management address, and only create an edge
            # when that address is already a known node.
            foreach ($line in $output) {
                $value = if ($line -match '=\s*(.+)$') { $matches[1] } else { '' }
                if ([string]::IsNullOrWhiteSpace($value)) { continue }

                $targetIP = $null

                # Only typed address values are eligible. Arbitrary STRING values can
                # contain known IPs but are not evidence of a neighbor relationship.
                if ($value -match '^IpAddress:\s*((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})\s*$') {
                    $targetIP = $matches[1]
                }
                elseif ($value -match '^Hex-STRING:\s*([0-9A-Fa-f]{2})[ :]+([0-9A-Fa-f]{2})[ :]+([0-9A-Fa-f]{2})[ :]+([0-9A-Fa-f]{2})\s*$') {
                    $targetIP = @(
                        [Convert]::ToInt32($matches[1], 16)
                        [Convert]::ToInt32($matches[2], 16)
                        [Convert]::ToInt32($matches[3], 16)
                        [Convert]::ToInt32($matches[4], 16)
                    ) -join '.'
                }

                if ([string]::IsNullOrWhiteSpace($targetIP)) { continue }

                # Skip self-loops.
                if ($targetIP -eq $node.IP) { continue }

                # Only accept addresses that map to a node already in the topology.
                $targetNode = $Topology.Nodes | Where-Object { $_.IP -eq $targetIP }
                if (-not $targetNode) { continue }

                # Best-effort interface label extraction.
                $label = 'LLDP'
                if ($value -match '(?:ifName|Interface|Port(?:Id)?)\s*[:=]\s*"?([^"\s]+)"?') {
                    $label = $matches[1]
                }

                $edge = [pscustomobject]@{
                    SourceIP   = $node.IP
                    TargetIP   = $targetIP
                    Label      = $label
                    Source     = 'SNMP'
                    Confidence = 'L2-SNMP-Heuristic'
                }

                $null = $discoveredEdges.Add($edge)
            }
        }

        Write-Verbose "Discovered $($discoveredEdges.Count) SNMP edges"
        $summaryLine = "SNMP summary: queried $($snmpCounts.queried) answered $($snmpCounts.answered) skippedNoCredential $($snmpCounts.skippedNoCredential) skippedError $($snmpCounts.skippedError) skippedNoData $($snmpCounts.skippedNoData)"
        Write-Host $summaryLine
        Write-Verbose $summaryLine

        if ($TryPublic -and $publicAttempts -gt 0) {
            Write-Warning "Used default 'public' community string on $publicAttempts device(s)"
        }

        # Attach completeness evidence to topology
        $Topology | Add-Member -NotePropertyName SnmpOutcomes -NotePropertyValue $snmpOutcomes -Force
        $Topology | Add-Member -NotePropertyName SnmpSummary -NotePropertyValue $snmpCounts -Force

        # Merge new edges with existing ones
        $allEdges = @($Topology.Edges) + @($discoveredEdges)
        $Topology.Edges = Merge-Edges -Edges $allEdges

        return $Topology
    }
}

function Resolve-SnmpCredentialConfig {
    param(
        [Parameter(Mandatory)][psobject]$SnmpMap,
        [Parameter(Mandatory)][string]$IPAddress
    )

    $defaultConfig = $null
    $cidrMatches = @()

    foreach ($entry in $SnmpMap.PSObject.Properties) {
        if ($entry.Name -eq 'Default') {
            $defaultConfig = $entry.Value
            continue
        }

        if ($entry.Name -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})$') {
            throw "Invalid SNMP credential-map CIDR '$($entry.Name)'. Expected an IPv4 CIDR or Default."
        }

        $prefixLength = [int]$matches[2]
        $networkAddress = $null
        if ($prefixLength -gt 32 -or
            -not [System.Net.IPAddress]::TryParse($matches[1], [ref]$networkAddress) -or
            $networkAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Invalid SNMP credential-map CIDR '$($entry.Name)'. Expected an IPv4 CIDR or Default."
        }

        if (Test-IPInSubnet -IP $IPAddress -CIDR $entry.Name) {
            $cidrMatches += [pscustomobject]@{
                CIDR = $entry.Name
                PrefixLength = $prefixLength
                Config = $entry.Value
            }
        }
    }

    $bestMatch = $cidrMatches | Sort-Object PrefixLength -Descending | Select-Object -First 1
    if ($bestMatch) {
        return $bestMatch
    }
    if ($null -ne $defaultConfig) {
        return [pscustomobject]@{
            CIDR = 'Default'
            PrefixLength = -1
            Config = $defaultConfig
        }
    }

    return $null
}

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

#endregion

#region Merge-Edges

function Merge-Edges {
    <#
    .SYNOPSIS
        Merges and deduplicates edge candidates
    .DESCRIPTION
        Deduplicates edges using sorted endpoints as key.
        Prioritizes verified L2-SNMP, then provisional L2-SNMP-Heuristic, then
        L3-Inferred. An SNMP source alone never promotes an edge to verified.
        Keeps first non-empty label.
    .PARAMETER Edges
        Array of edge objects to merge
    .EXAMPLE
        $merged = Merge-Edges -Edges $allEdges
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Edges
    )

    if ($null -eq $Edges -or $Edges.Count -eq 0) {
        return @()
    }

    $edgeMap = [ordered]@{}

    foreach ($edge in $Edges) {
        if ($null -eq $edge) {
            continue
        }

        # Null safety checks
        if ([string]::IsNullOrWhiteSpace($edge.SourceIP) -or [string]::IsNullOrWhiteSpace($edge.TargetIP)) {
            Write-Warning "Skipping edge with missing IP addresses"
            continue
        }

        # Create dedupe key using sorted endpoints
        $endpoints = @($edge.SourceIP, $edge.TargetIP) | Sort-Object
        $key = "$($endpoints[0])|$($endpoints[1])"

        $incomingConfidence = if ($edge.PSObject.Properties['Confidence']) {
            $edge.Confidence
        }
        elseif ($edge.PSObject.Properties['Source'] -and $edge.Source -eq 'SNMP') {
            'L2-SNMP-Heuristic'
        }
        else {
            'L3-Inferred'
        }

        $confidenceRank = @{
            'L3-Inferred' = 1
            'L2-SNMP-Heuristic' = 2
            'L2-SNMP' = 3
        }

        if ($edgeMap.Contains($key)) {
            $existing = $edgeMap[$key]

            $existingRank = if ($confidenceRank.ContainsKey($existing.Confidence)) { $confidenceRank[$existing.Confidence] } else { 0 }
            $incomingRank = if ($confidenceRank.ContainsKey($incomingConfidence)) { $confidenceRank[$incomingConfidence] } else { 0 }
            if ($incomingRank -gt $existingRank) {
                $existing.Source = if ($edge.PSObject.Properties['Source']) { $edge.Source } else { 'Unknown' }
                $existing.Confidence = $incomingConfidence
            }

            # Keep first non-empty label
            if ([string]::IsNullOrWhiteSpace($existing.Label) -and -not [string]::IsNullOrWhiteSpace($edge.Label)) {
                $existing.Label = $edge.Label
            }
        }
        else {
            # Add new edge with confidence
            $edgeMap[$key] = [pscustomobject]@{
                SourceIP   = $edge.SourceIP
                TargetIP   = $edge.TargetIP
                Label      = if ($edge.PSObject.Properties['Label']) { $edge.Label } else { '' }
                Source     = if ($edge.PSObject.Properties['Source']) { $edge.Source } else { 'Unknown' }
                Confidence = $incomingConfidence
            }
        }
    }

    return @($edgeMap.Values)
}

#endregion

#region Export-DrawIO

function Export-DrawIO {
    <#
    .SYNOPSIS
        Exports topology to .drawio XML format
    .DESCRIPTION
        Generates a valid draw.io diagram file with hierarchical node placement.
        Nodes are positioned by layer (Core, Dist, Access, Servers) with fixed coordinates.
    .PARAMETER Topology
        Topology object with nodes and edges
    .PARAMETER OutFile
        Output path for .drawio file
    .EXAMPLE
        $topo | Export-DrawIO -OutFile '.\network.drawio'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [Parameter()]
        [switch]$Force
    )

    process {
        if ($null -eq $Topology -or $null -eq $Topology.Nodes) {
            throw "Invalid topology object"
        }

        if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
            throw "File '$OutFile' already exists. Use -Force to overwrite."
        }
        if (-not $PSCmdlet.ShouldProcess($OutFile, 'Export-DrawIO')) {
            return
        }

        # De-duplicate nodes by IP first. Duplicate IPs would otherwise share a single
        # node-ID map entry yet each still be rendered, emitting multiple mxCells with
        # the same id - which is invalid draw.io. Keep the first occurrence and warn.
        $uniqueNodes = [System.Collections.Generic.List[object]]::new()
        $seenIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($node in $Topology.Nodes) {
            if ([string]::IsNullOrWhiteSpace($node.IP)) {
                Write-Warning "Skipping node with no IP address"
                continue
            }
            if (-not $seenIPs.Add([string]$node.IP)) {
                Write-Warning "Duplicate IP '$($node.IP)' - keeping first occurrence, skipping duplicate node"
                continue
            }
            $uniqueNodes.Add($node)
        }

        # Build node ID map (one entry per unique IP)
        $nodeIDMap = @{}
        $nextID = 2  # Start after mxCell id="0" and id="1"

        foreach ($node in $uniqueNodes) {
            $nodeIDMap[$node.IP] = $nextID++
        }

        # Layer order for Y-axis positioning
        $layerOrder = @('Core', 'Dist', 'Access', 'Servers')

        # Group nodes by layer
        $nodesByLayer = @{}
        foreach ($layer in $layerOrder) {
            $nodesByLayer[$layer] = @($uniqueNodes | Where-Object { $_.Layer -eq $layer })
        }

        # Start building XML
        $xml = [System.Text.StringBuilder]::new()
        $null = $xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
        $null = $xml.AppendLine('<mxfile host="app.diagrams.net">')
        $null = $xml.AppendLine('  <diagram id="Net" name="Network">')
        $null = $xml.AppendLine('    <mxGraphModel>')
        $null = $xml.AppendLine('      <root>')
        $null = $xml.AppendLine('        <mxCell id="0"/>')
        $null = $xml.AppendLine('        <mxCell id="1" parent="0"/>')

        # Assign each node to its first matching subnet before sizing containers.
        $nodeSubnet = @{}
        $subnetNodeCount = @{}
        foreach ($subnet in $Topology.Subnets) {
            $subnetNodeCount[$subnet.CIDR] = 0
        }
        foreach ($node in $uniqueNodes) {
            foreach ($subnet in $Topology.Subnets) {
                if (Test-IPInSubnet -IP $node.IP -CIDR $subnet.CIDR) {
                    $nodeSubnet[$node.IP] = $subnet.CIDR
                    $subnetNodeCount[$subnet.CIDR]++
                    break
                }
            }
        }

        # Add subnet containers. Each row starts below the tallest container in the
        # previous row, so dense subnets cannot overlap the row beneath them.
        $containerID = $nextID
        $subnetContainers = @{}
        $containerIndex = 0
        $containerRowY = 20
        $containerRowHeight = 0

        foreach ($subnet in $Topology.Subnets) {
            $subnetLabel = [System.Security.SecurityElement]::Escape("$($subnet.Label)`n$($subnet.CIDR)")
            $containerStyle = 'swimlane;fontSize=14;fontStyle=1;fillColor=#f5f5f5;strokeColor=#666666;rounded=1;'

            $column = $containerIndex % 2
            if ($column -eq 0 -and $containerIndex -gt 0) {
                $containerRowY += $containerRowHeight + 50
                $containerRowHeight = 0
            }

            $nodeRows = [Math]::Ceiling($subnetNodeCount[$subnet.CIDR] / 4.0)
            $containerWidth = 800
            $containerHeight = [Math]::Max(140, 40 + ([int]$nodeRows * 110))
            $containerX = 20 + ($column * 850)
            $containerY = $containerRowY
            $containerRowHeight = [Math]::Max($containerRowHeight, $containerHeight)

            $null = $xml.AppendLine("        <mxCell id=`"$containerID`" value=`"$subnetLabel`" style=`"$containerStyle`" parent=`"1`" vertex=`"1`">")
            $null = $xml.AppendLine("          <mxGeometry x=`"$containerX`" y=`"$containerY`" width=`"$containerWidth`" height=`"$containerHeight`" as=`"geometry`"/>")
            $null = $xml.AppendLine('        </mxCell>')

            $subnetContainers[$subnet.CIDR] = $containerID
            $containerID++
            $containerIndex++
        }

        $nextID = $containerID

        # Map assigned subnet CIDRs to their emitted container IDs.
        $nodeContainer = @{}
        foreach ($node in $uniqueNodes) {
            if ($nodeSubnet.ContainsKey($node.IP)) {
                $nodeContainer[$node.IP] = $subnetContainers[$nodeSubnet[$node.IP]]
            }
        }

        # Layout bookkeeping: per-container child index, and a base Y for unmatched
        # (canvas-level) nodes placed below the container grid so nothing overlaps.
        $containerChildCount = @{}
        $unmatchedBaseY = if ($subnetContainers.Count -gt 0) {
            $containerRowY + $containerRowHeight + 40
        }
        else {
            20
        }

        # Add nodes with enhanced styles and metadata
        foreach ($layer in $layerOrder) {
            $nodesInLayer = $nodesByLayer[$layer]
            $layerIndex = $layerOrder.IndexOf($layer)

            for ($i = 0; $i -lt $nodesInLayer.Count; $i++) {
                $node = $nodesInLayer[$i]
                $nodeID = $nodeIDMap[$node.IP]

                # Decide parent container and geometry. Nodes matched to a subnet go
                # inside that swimlane (geometry relative to the container); unmatched
                # nodes are laid out on the open canvas by layer, below the containers.
                if ($nodeContainer.ContainsKey($node.IP)) {
                    $parentID = $nodeContainer[$node.IP]
                    $childIndex = if ($containerChildCount.ContainsKey($parentID)) { $containerChildCount[$parentID] } else { 0 }
                    $containerChildCount[$parentID] = $childIndex + 1
                    $col = $childIndex % 4
                    $row = [Math]::Floor($childIndex / 4)
                    $xPos = 20 + ($col * 190)
                    $yPos = 40 + ($row * 110)
                }
                else {
                    $parentID = 1
                    $xPos = 60 + ($i * 190)
                    $yPos = $unmatchedBaseY + ($layerIndex * 130)
                }

                # Get role-specific icon shape and colors
                $shapeConfig = switch ($node.Role) {
                    'core-router'   { @{ shape='mxgraph.cisco.routers.router'; fillColor='#dae8fc'; strokeColor='#6c8ebf' } }
                    'router'        { @{ shape='mxgraph.cisco.routers.router'; fillColor='#dae8fc'; strokeColor='#6c8ebf' } }
                    'distribution'  { @{ shape='mxgraph.cisco.switches.workgroup_switch'; fillColor='#d5e8d4'; strokeColor='#82b366' } }
                    'switch'        { @{ shape='mxgraph.cisco.switches.workgroup_switch'; fillColor='#d5e8d4'; strokeColor='#82b366' } }
                    'server'        { @{ shape='mxgraph.cisco.servers.generic_server'; fillColor='#fff2cc'; strokeColor='#d6b656' } }
                    'workstation'   { @{ shape='mxgraph.cisco.computers_and_peripherals.pc'; fillColor='#e1d5e7'; strokeColor='#9673a6' } }
                    default         { @{ shape='rectangle'; fillColor='#e1e1e1'; strokeColor='#999999' } }
                }

                # Status is tri-state and controls the status color consistently.
                if ($node.Reachable -eq $true) {
                    $status = 'Reachable'
                    $shapeConfig.fillColor = '#d5e8d4'
                    $shapeConfig.strokeColor = '#82b366'
                }
                elseif ($node.Reachable -eq $false) {
                    $status = 'Unreachable'
                    $shapeConfig.fillColor = '#f8cecc'
                    $shapeConfig.strokeColor = '#b85450'
                }
                else {
                    $status = 'Unknown'
                    $shapeConfig.fillColor = '#f5f5f5'
                    $shapeConfig.strokeColor = '#666666'
                }

                # Node label with better formatting (escape entire label for XML)
                $labelText = $node.Hostname
                if ($node.IP -ne $node.Hostname) {
                    $labelText += "`n$($node.IP)"
                }
                $label = ([System.Security.SecurityElement]::Escape($labelText)) -replace "`n", '&#xa;'

                # Build enhanced style with shadow and rounded corners
                $nodeStyle = "shape=$($shapeConfig.shape);rounded=1;whiteSpace=wrap;html=1;align=center;verticalAlign=top;"
                $nodeStyle += "fillColor=$($shapeConfig.fillColor);strokeColor=$($shapeConfig.strokeColor);"
                $nodeStyle += "shadow=1;fontSize=12;fontFamily=Helvetica;spacingTop=10;"

                # Create tooltip with metadata (best practice: add device details)
                $tooltipParts = @(
                    "IP: $($node.IP)",
                    "Hostname: $($node.Hostname)",
                    "Role: $($node.Role)",
                    "Vendor: $($node.Vendor)",
                    "OS: $($node.OS)",
                    "Layer: $($node.Layer)",
                    "Status: $status"
                )
                $tooltip = ([System.Security.SecurityElement]::Escape(($tooltipParts -join "`n"))) -replace "`n", '&#xa;'
                $ipAttribute = [System.Security.SecurityElement]::Escape([string]$node.IP)
                $hostnameAttribute = [System.Security.SecurityElement]::Escape([string]$node.Hostname)
                $roleAttribute = [System.Security.SecurityElement]::Escape([string]$node.Role)
                $vendorAttribute = [System.Security.SecurityElement]::Escape([string]$node.Vendor)
                $osAttribute = [System.Security.SecurityElement]::Escape([string]$node.OS)
                $layerAttribute = [System.Security.SecurityElement]::Escape([string]$node.Layer)

                $null = $xml.AppendLine("        <UserObject id=`"$nodeID`" label=`"$label`" tooltip=`"$tooltip`" ip=`"$ipAttribute`" hostname=`"$hostnameAttribute`" role=`"$roleAttribute`" vendor=`"$vendorAttribute`" os=`"$osAttribute`" layer=`"$layerAttribute`" status=`"$status`">")
                $null = $xml.AppendLine("          <mxCell style=`"$nodeStyle`" parent=`"$parentID`" vertex=`"1`">")
                $null = $xml.AppendLine("            <mxGeometry x=`"$xPos`" y=`"$yPos`" width=`"140`" height=`"80`" as=`"geometry`"/>")
                $null = $xml.AppendLine('          </mxCell>')
                $null = $xml.AppendLine('        </UserObject>')
            }
        }

        # Add edges with enhanced styling (best practice: orthogonal routing, rounded, labeled)
        $edgeID = $nextID
        foreach ($edge in $Topology.Edges) {
            if ($null -eq $edge) {
                continue
            }

            # Validate node IDs exist
            $sourceID = $nodeIDMap[$edge.SourceIP]
            $targetID = $nodeIDMap[$edge.TargetIP]

            if ($null -eq $sourceID -or $null -eq $targetID) {
                Write-Warning "Skipping edge $($edge.SourceIP) -> $($edge.TargetIP): node ID not found"
                continue
            }

            $label = [System.Security.SecurityElement]::Escape($edge.Label)

            # Enhanced edge style with best practices
            $confidence = if ($edge.PSObject.Properties['Confidence']) { $edge.Confidence } else { 'L3-Inferred' }

            # Base style: orthogonal routing with rounded corners (best practice for network diagrams)
            $edgeStyle = 'edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;'
            $edgeStyle += 'labelBackgroundColor=#ffffff;fontSize=11;fontFamily=Helvetica;'

            # Different styling based on confidence level
            if ($confidence -eq 'L2-SNMP') {
                # L2-SNMP: Solid line, green, thicker (verified connection)
                $edgeStyle += 'strokeColor=#2D7600;strokeWidth=2.5;'
                $edgeStyle += 'endArrow=classic;endFill=1;'
            }
            elseif ($confidence -eq 'L2-SNMP-Heuristic') {
                # Provisional SNMP hint: amber and dashed, visually distinct from
                # verified physical topology.
                $edgeStyle += 'strokeColor=#B26A00;strokeWidth=2;dashed=1;dashPattern=8 4;'
                $edgeStyle += 'endArrow=classic;endFill=0;'
            }
            elseif ($confidence -eq 'L3-Inferred') {
                # L3-Inferred: Dashed line, gray (inferred connection)
                $edgeStyle += 'strokeColor=#808080;strokeWidth=1.5;dashed=1;dashPattern=5 5;'
                $edgeStyle += 'endArrow=classic;endFill=0;'
            }
            else {
                # Default: dotted line for unknown
                $edgeStyle += 'strokeColor=#999999;strokeWidth=1;dashed=1;dashPattern=2 2;'
                $edgeStyle += 'endArrow=classic;endFill=0;'
            }

            # Add shadow for depth (best practice)
            $edgeStyle += 'shadow=0;'  # Shadows on edges can be cluttered, keeping it clean

            # Build connector with label
            $null = $xml.AppendLine("        <mxCell id=`"$edgeID`" value=`"$label`" style=`"$edgeStyle`" parent=`"1`" source=`"$sourceID`" target=`"$targetID`" edge=`"1`">")
            $null = $xml.AppendLine('          <mxGeometry relative="1" as="geometry"/>')
            $null = $xml.AppendLine('        </mxCell>')

            $edgeID++
        }

        $null = $xml.AppendLine('      </root>')
        $null = $xml.AppendLine('    </mxGraphModel>')
        $null = $xml.AppendLine('  </diagram>')
        $null = $xml.AppendLine('</mxfile>')

        # Write to file
        try {
            $xml.ToString() | Out-File -FilePath $OutFile -Encoding utf8 -Force
            Write-Verbose "Exported diagram to $OutFile"
        }
        catch {
            throw "Failed to write .drawio file: $_"
        }
    }
}

#endregion

#region Export-Mermaid

function Export-Mermaid {
    <#
    .SYNOPSIS
        Exports topology to Mermaid flowchart
    .DESCRIPTION
        Emits flowchart LR with nodes labelled hostname+IP, edges per topology,
        subgraphs per subnet, and dotted links for L3-Inferred vs solid for L2.
    .PARAMETER Topology
        Topology object with Nodes, Edges, Subnets
    .PARAMETER OutFile
        Output path for .mmd file
    .PARAMETER Force
        Overwrite existing file
    .EXAMPLE
        $topo | Export-Mermaid -OutFile diagram.mmd
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [Parameter()]
        [switch]$Force
    )

    process {
        if ($null -eq $Topology -or $null -eq $Topology.Nodes) {
            throw "Invalid topology object"
        }
        if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
            throw "File '$OutFile' already exists. Use -Force to overwrite."
        }
        if (-not $PSCmdlet.ShouldProcess($OutFile, 'Export-Mermaid')) {
            return
        }

        function ConvertTo-MermaidId { param([string]$IP) ($IP -replace '[^A-Za-z0-9]', '_') }
        function Escape-MermaidLabel { param([string]$Text) ($Text -replace '[\[\]"]', '' -replace '\n', ' ') }

        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine('flowchart LR')

        # Group nodes by subnet for subgraphs
        $nodeSubnet = @{}
        foreach ($node in $Topology.Nodes) {
            foreach ($subnet in @($Topology.Subnets)) {
                if (Test-IPInSubnet -IP $node.IP -CIDR $subnet.CIDR) {
                    $nodeSubnet[$node.IP] = $subnet.CIDR
                    break
                }
            }
        }

        $subnetsByCidr = @{}
        foreach ($s in @($Topology.Subnets)) { $subnetsByCidr[$s.CIDR] = $s }

        # Emit subgraphs and their nodes
        $emitted = @{}
        foreach ($cidr in @($Topology.Subnets | ForEach-Object { $_.CIDR })) {
            $label = Escape-MermaidLabel "$($subnetsByCidr[$cidr].Label) $($cidr)"
            $null = $sb.AppendLine("  subgraph `"$label`"")
            foreach ($node in $Topology.Nodes) {
                if ($nodeSubnet[$node.IP] -eq $cidr) {
                    $id = ConvertTo-MermaidId $node.IP
                    $lab = Escape-MermaidLabel "$($node.Hostname) $($node.IP)"
                    $null = $sb.AppendLine("    $id[`"$lab`"]")
                    $emitted[$node.IP] = $true
                }
            }
            $null = $sb.AppendLine("  end")
        }

        # Unmatched nodes
        foreach ($node in $Topology.Nodes) {
            if (-not $emitted.ContainsKey($node.IP)) {
                $id = ConvertTo-MermaidId $node.IP
                $lab = Escape-MermaidLabel "$($node.Hostname) $($node.IP)"
                $null = $sb.AppendLine("  $id[`"$lab`"]")
            }
        }

        # Edges
        foreach ($edge in @($Topology.Edges)) {
            if (-not $edge.SourceIP -or -not $edge.TargetIP) { continue }
            $src = ConvertTo-MermaidId $edge.SourceIP
            $dst = ConvertTo-MermaidId $edge.TargetIP
            $arrow = if ($edge.Confidence -eq 'L3-Inferred') { '-.->' } else { '-->' }
            $lbl = if ($edge.Label) { " |$(Escape-MermaidLabel $edge.Label)|" } else { '' }
            $null = $sb.AppendLine("  $src $arrow$lbl $dst")
        }

        try {
            $sb.ToString() | Out-File -FilePath $OutFile -Encoding utf8 -Force
            Write-Verbose "Exported Mermaid to $OutFile"
        }
        catch {
            throw "Failed to write Mermaid file: $_"
        }
    }
}

#endregion

#region Export-Metadata

function Export-Metadata {
    <#
    .SYNOPSIS
        Exports scan metadata to JSON
    .DESCRIPTION
        Writes metadata including scan times, confidence counts, node/edge counts.
    .PARAMETER Topology
        Topology object
    .PARAMETER OutFile
        Output path for metadata JSON
    .PARAMETER CredSetsUsed
        Array of credential set names used during scan
    .EXAMPLE
        $topo | Export-Metadata -OutFile '.\scanmeta.json'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [Parameter()]
        [string[]]$CredSetsUsed = @(),

        [Parameter()]
        [switch]$Force
    )

    process {
        if ($null -eq $Topology) {
            throw "Invalid topology object"
        }

        if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
            throw "File '$OutFile' already exists. Use -Force to overwrite."
        }
        if (-not $PSCmdlet.ShouldProcess($OutFile, 'Export-Metadata')) {
            return
        }

        # Calculate confidence counts
        $confidenceCounts = @{}
        foreach ($edge in $Topology.Edges) {
            if ($edge.PSObject.Properties['Confidence'] -and -not [string]::IsNullOrWhiteSpace($edge.Confidence)) {
                $conf = $edge.Confidence
                if ($confidenceCounts.ContainsKey($conf)) {
                    $confidenceCounts[$conf]++
                }
                else {
                    $confidenceCounts[$conf] = 1
                }
            }
        }

        $snmpSummary = if ($Topology.PSObject.Properties['SnmpSummary']) { $Topology.SnmpSummary } else { $null }
        $snmpOutcomes = if ($Topology.PSObject.Properties['SnmpOutcomes']) { $Topology.SnmpOutcomes } else { $null }
        $metadata = [ordered]@{
            scanStarted       = (Get-Date).ToString('o')
            scanFinished      = (Get-Date).ToString('o')
            tool              = "NetDiagram-PS $script:ModuleVersion"
            credSetsUsed      = @($CredSetsUsed)
            confidenceCounts  = $confidenceCounts
            nodeCount         = $Topology.Nodes.Count
            edgeCount         = $Topology.Edges.Count
            snmpSummary       = $snmpSummary
            snmpOutcomes      = $snmpOutcomes
        }

        try {
            $metadata | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutFile -Encoding utf8 -Force
            Write-Verbose "Exported metadata to $OutFile"
        }
        catch {
            throw "Failed to write metadata file: $_"
        }
    }
}

#region Export-NodeInventoryCsv

function Export-NodeInventoryCsv {
    <#
    .SYNOPSIS
        Exports node inventory to CSV
    .DESCRIPTION
        Writes one row per node with columns IP,Hostname,Role,Layer,Vendor,OS,Reachable,MACAddress,OpenPorts.
        Reachable $null -> 'unknown', $true -> 'reachable', $false -> 'unreachable'. OpenPorts joined with ';'.
    .PARAMETER Topology
        Topology object with Nodes
    .PARAMETER OutFile
        Output path for CSV
    .PARAMETER Force
        Overwrite existing file
    .EXAMPLE
        $topo | Export-NodeInventoryCsv -OutFile '.\nodes.csv'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [Parameter()]
        [switch]$Force
    )

    process {
        if ($null -eq $Topology) {
            throw "Invalid topology object"
        }
        if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
            throw "File '$OutFile' already exists. Use -Force to overwrite."
        }
        if (-not $PSCmdlet.ShouldProcess($OutFile, 'Export-NodeInventoryCsv')) {
            return
        }
        $rows = foreach ($node in @($Topology.Nodes)) {
            $reach = if ($null -eq $node.Reachable) { 'unknown' } elseif ($node.Reachable -eq $true) { 'reachable' } else { 'unreachable' }
            $mac = if ($node.PSObject.Properties['MACAddress'] -and $node.MACAddress) { [string]$node.MACAddress } else { '' }
            $ports = if ($node.PSObject.Properties['OpenPorts'] -and $node.OpenPorts) { (@($node.OpenPorts) -join ';') } else { '' }
            [pscustomobject]@{
                IP          = [string]$node.IP
                Hostname    = [string]$node.Hostname
                Role        = [string]$node.Role
                Layer       = [string]$node.Layer
                Vendor      = [string]$node.Vendor
                OS          = [string]$node.OS
                Reachable   = $reach
                MACAddress  = $mac
                OpenPorts   = $ports
            }
        }
        # Ensure header-only file for empty topology (Export-Csv would create 0-byte file)
        if ($null -eq $rows -or @($rows).Count -eq 0) {
            'IP,Hostname,Role,Layer,Vendor,OS,Reachable,MACAddress,OpenPorts' | Out-File -FilePath $OutFile -Encoding utf8 -Force
        }
        else {
            $rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding utf8 -Force
        }
        Write-Verbose "Exported CSV to $OutFile"
    }
}

#endregion

#region Topology Persistence

function Export-Topology {
    <#
    .SYNOPSIS
        Persists a topology object to JSON
    .DESCRIPTION
        Writes the full topology (Nodes, Edges, Subnets) to a JSON file at
        an explicit depth so nested edge properties survive the round trip.
    .PARAMETER Topology
        Topology object with Nodes, Edges, Subnets
    .PARAMETER OutFile
        Output path for topology JSON
    .PARAMETER Force
        Overwrite an existing file
    .EXAMPLE
        $topo | Export-Topology -OutFile '.\topo.json'
        $topo | Export-Topology -OutFile '.\topo.json' -Force
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [Parameter()]
        [switch]$Force
    )

    process {
        if ($null -eq $Topology) {
            throw "Invalid topology object"
        }
        if ((Test-Path -LiteralPath $OutFile) -and -not $Force) {
            throw "File '$OutFile' already exists. Use -Force to overwrite."
        }
        if (-not $PSCmdlet.ShouldProcess($OutFile, 'Export-Topology')) {
            return
        }
        try {
            $Topology | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutFile -Encoding utf8 -Force
            Write-Verbose "Exported topology to $OutFile"
        }
        catch {
            throw "Failed to write topology file: $_"
        }
    }
}

function Import-Topology {
    <#
    .SYNOPSIS
        Loads a topology object from JSON
    .DESCRIPTION
        Reads a JSON file written by Export-Topology and returns a topology
        object with Nodes, Edges, Subnets. Validates the required shape.
    .PARAMETER Path
        Path to topology JSON file
    .EXAMPLE
        $topo = Import-Topology -Path '.\topo.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Topology file not found: '$Path'"
    }
    try {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse topology file '$Path': $_"
    }
    if ($null -eq $data.PSObject.Properties['Nodes']) {
        throw "Invalid topology file '$Path': missing required property 'Nodes'."
    }
    # Normalize to arrays so callers can count safely
    if ($null -eq $data.Nodes) { $data.Nodes = @() }
    if ($null -eq $data.Edges) { $data.Edges = @() }
    if ($null -eq $data.Subnets) { $data.Subnets = @() }
    return $data
}

#endregion

#region Compare-NetworkScans

function Compare-NetworkScans {
    <#
    .SYNOPSIS
        Compares two network scan snapshots
    .DESCRIPTION
        Analyzes differences between two topology snapshots and metadata files.
        Outputs markdown report with nodes/edges added/removed and confidence changes.
    .PARAMETER BaselineMetadata
        Path to baseline metadata JSON
    .PARAMETER BaselineTopology
        Path to baseline topology JSON (serialized Topology object)
    .PARAMETER CurrentMetadata
        Path to current metadata JSON
    .PARAMETER CurrentTopology
        Path to current topology JSON
    .PARAMETER OutFile
        Output path for markdown report (optional, defaults to console)
    .EXAMPLE
        Compare-NetworkScans -BaselineMetadata '.\old-meta.json' -BaselineTopology '.\old-topo.json' `
                             -CurrentMetadata '.\new-meta.json' -CurrentTopology '.\new-topo.json' `
                             -OutFile '.\diff.md'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaselineMetadata,

        [Parameter(Mandatory)]
        [string]$BaselineTopology,

        [Parameter(Mandatory)]
        [string]$CurrentMetadata,

        [Parameter(Mandatory)]
        [string]$CurrentTopology,

        [Parameter()]
        [string]$OutFile
    )

    # Load files (topology via Import-Topology for validation)
    try {
        $baseMeta = Get-Content -Path $BaselineMetadata -Raw | ConvertFrom-Json
        $baseTopoData = Import-Topology -Path $BaselineTopology
        $currMeta = Get-Content -Path $CurrentMetadata -Raw | ConvertFrom-Json
        $currTopoData = Import-Topology -Path $CurrentTopology
    }
    catch {
        throw "Failed to load comparison files: $_"
    }

    $report = [System.Text.StringBuilder]::new()

    $null = $report.AppendLine("# Network Scan Comparison Report")
    $null = $report.AppendLine()

    # Safely handle timestamp strings with colons
    $baselineTime = if ($baseMeta.PSObject.Properties['scanFinished']) { $baseMeta.scanFinished } else { 'Unknown' }
    $currentTime = if ($currMeta.PSObject.Properties['scanFinished']) { $currMeta.scanFinished } else { 'Unknown' }

    $null = $report.AppendLine("**Baseline Scan:** $baselineTime")
    $null = $report.AppendLine("**Current Scan:** $currentTime")
    $null = $report.AppendLine()

    # Compare nodes
    $baseNodeIPs = @($baseTopoData.Nodes | ForEach-Object { $_.IP })
    $currNodeIPs = @($currTopoData.Nodes | ForEach-Object { $_.IP })

    $addedNodes = @($currNodeIPs | Where-Object { $_ -notin $baseNodeIPs })
    $rawRemoved = @($baseNodeIPs | Where-Object { $_ -notin $currNodeIPs })
    # If current topology carries SnmpOutcomes, don't report a node as removed when the current scan merely failed to query it
    $removedNodes = @($rawRemoved | Where-Object {
        $ip = $_
        if ($currTopoData.PSObject.Properties['SnmpOutcomes'] -and $currTopoData.SnmpOutcomes -and $currTopoData.SnmpOutcomes.PSObject.Properties[$ip]) {
            $outcome = $currTopoData.SnmpOutcomes.$ip
            $outcome -eq 'answered' -or $outcome -eq 'noData'
        } else { $true }
    })
    $skippedDueToIncompleteQuery = @($rawRemoved | Where-Object { $_ -notin $removedNodes })

    $null = $report.AppendLine("## Node Changes")
    $null = $report.AppendLine()

    if ($addedNodes.Count -gt 0) {
        $null = $report.AppendLine("### Added Nodes ($($addedNodes.Count))")
        foreach ($ip in $addedNodes) {
            $node = $currTopoData.Nodes | Where-Object { $_.IP -eq $ip }
            $null = $report.AppendLine("- $ip ($($node.Hostname)) - $($node.Role)")
        }
        $null = $report.AppendLine()
    }

    if ($removedNodes.Count -gt 0) {
        $null = $report.AppendLine("### Removed Nodes ($($removedNodes.Count))")
        foreach ($ip in $removedNodes) {
            $node = $baseTopoData.Nodes | Where-Object { $_.IP -eq $ip }
            $null = $report.AppendLine("- $ip ($($node.Hostname)) - $($node.Role)")
        }
        $null = $report.AppendLine()
    }

    if ($skippedDueToIncompleteQuery.Count -gt 0) {
        $null = $report.AppendLine("### Skipped (incomplete SNMP query, not counted as removed) ($($skippedDueToIncompleteQuery.Count))")
        foreach ($ip in $skippedDueToIncompleteQuery) {
            $node = $baseTopoData.Nodes | Where-Object { $_.IP -eq $ip }
            $outcome = $currTopoData.SnmpOutcomes.$ip
            $null = $report.AppendLine("- $ip ($($node.Hostname)) - outcome: $outcome")
        }
        $null = $report.AppendLine()
    }

    if ($addedNodes.Count -eq 0 -and $removedNodes.Count -eq 0) {
        $null = $report.AppendLine("No node changes detected.")
        $null = $report.AppendLine()
    }

    # Compare edges
    $baseEdgeKeys = @($baseTopoData.Edges | ForEach-Object {
        $endpoints = @($_.SourceIP, $_.TargetIP) | Sort-Object
        "$($endpoints[0])|$($endpoints[1])"
    })
    $currEdgeKeys = @($currTopoData.Edges | ForEach-Object {
        $endpoints = @($_.SourceIP, $_.TargetIP) | Sort-Object
        "$($endpoints[0])|$($endpoints[1])"
    })

    $addedEdges = @($currEdgeKeys | Where-Object { $_ -notin $baseEdgeKeys })
    $removedEdges = @($baseEdgeKeys | Where-Object { $_ -notin $currEdgeKeys })

    $null = $report.AppendLine("## Edge Changes")
    $null = $report.AppendLine()

    if ($addedEdges.Count -gt 0) {
        $null = $report.AppendLine("### Added Edges ($($addedEdges.Count))")
        foreach ($key in $addedEdges) {
            $edge = $currTopoData.Edges | Where-Object {
                $endpoints = @($_.SourceIP, $_.TargetIP) | Sort-Object
                "$($endpoints[0])|$($endpoints[1])" -eq $key
            }
            $null = $report.AppendLine("- $($edge.SourceIP) <-> $($edge.TargetIP) [$($edge.Confidence)]")
        }
        $null = $report.AppendLine()
    }

    if ($removedEdges.Count -gt 0) {
        $null = $report.AppendLine("### Removed Edges ($($removedEdges.Count))")
        foreach ($key in $removedEdges) {
            $edge = $baseTopoData.Edges | Where-Object {
                $endpoints = @($_.SourceIP, $_.TargetIP) | Sort-Object
                "$($endpoints[0])|$($endpoints[1])" -eq $key
            }
            $null = $report.AppendLine("- $($edge.SourceIP) <-> $($edge.TargetIP) [$($edge.Confidence)]")
        }
        $null = $report.AppendLine()
    }

    if ($addedEdges.Count -eq 0 -and $removedEdges.Count -eq 0) {
        $null = $report.AppendLine("No edge changes detected.")
        $null = $report.AppendLine()
    }

    # Confidence comparison
    $null = $report.AppendLine("## Confidence Distribution")
    $null = $report.AppendLine()
    $null = $report.AppendLine("| Confidence | Baseline | Current | Change |")
    $null = $report.AppendLine("|------------|----------|---------|--------|")

    # Safely extract confidence type names
    $baseConfidences = if ($baseMeta.PSObject.Properties['confidenceCounts'] -and $baseMeta.confidenceCounts) {
        @($baseMeta.confidenceCounts.PSObject.Properties | ForEach-Object { $_.Name })
    } else { @() }

    $currConfidences = if ($currMeta.PSObject.Properties['confidenceCounts'] -and $currMeta.confidenceCounts) {
        @($currMeta.confidenceCounts.PSObject.Properties | ForEach-Object { $_.Name })
    } else { @() }

    $allConfidences = @($baseConfidences + $currConfidences | Select-Object -Unique)

    foreach ($conf in $allConfidences) {
        $baseCount = if ($baseMeta.PSObject.Properties['confidenceCounts'] -and $baseMeta.confidenceCounts.PSObject.Properties[$conf]) {
            $baseMeta.confidenceCounts.$conf
        } else { 0 }

        $currCount = if ($currMeta.PSObject.Properties['confidenceCounts'] -and $currMeta.confidenceCounts.PSObject.Properties[$conf]) {
            $currMeta.confidenceCounts.$conf
        } else { 0 }

        $change = $currCount - $baseCount
        $changeStr = if ($change -gt 0) { "+$change" } elseif ($change -lt 0) { "$change" } else { "0" }

        $null = $report.AppendLine("| $conf | $baseCount | $currCount | $changeStr |")
    }

    $reportText = $report.ToString()

    if ($OutFile) {
        try {
            $reportText | Out-File -FilePath $OutFile -Encoding utf8 -Force
            Write-Verbose "Comparison report written to $OutFile"
        }
        catch {
            throw "Failed to write report file: $_"
        }
    }
    else {
        Write-Output $reportText
    }
}

#endregion

#region Level 1: Credential-Free Discovery Functions

function ConvertFrom-ArpText {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][ValidateSet('MacOS', 'LinuxIp', 'LinuxArp')][string]$Format,
        [string]$InterfaceAlias
    )

    foreach ($line in $Lines) {
        $entry = $null
        if ($Format -eq 'MacOS') {
            if ($line -notmatch '\s+at\s+') { continue }
            if ($line -match '\s+at\s+\(incomplete\)') { continue }
            if ($line -notmatch '\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]{17})\s+on\s+(\S+)') {
                throw "Unable to parse macOS ARP entry: $line"
            }
            $entry = [pscustomobject]@{
                IPAddress = $matches[1]; MACAddress = $matches[2].ToUpperInvariant()
                State = 'Reachable'; InterfaceAlias = $matches[3]; InterfaceIndex = $null
            }
        }
        elseif ($Format -eq 'LinuxIp') {
            if ($line -notmatch '\s+lladdr\s+') { continue }
            if ($line -notmatch '^(\d+\.\d+\.\d+\.\d+)\s+dev\s+(\S+)\s+lladdr\s+([0-9a-fA-F:]{17})\s+(\S+)') {
                throw "Unable to parse Linux ip-neigh entry: $line"
            }
            $entry = [pscustomobject]@{
                IPAddress = $matches[1]; MACAddress = $matches[3].ToUpperInvariant()
                State = $matches[4]; InterfaceAlias = $matches[2]; InterfaceIndex = $null
            }
        }
        else {
            if ($line -notmatch '\s+at\s+') { continue }
            if ($line -notmatch '\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]{17})') {
                throw "Unable to parse Linux arp entry: $line"
            }
            $entry = [pscustomobject]@{
                IPAddress = $matches[1]; MACAddress = $matches[2].ToUpperInvariant()
                State = 'Reachable'; InterfaceAlias = $null; InterfaceIndex = $null
            }
        }

        if (-not $InterfaceAlias -or $entry.InterfaceAlias -eq $InterfaceAlias) {
            $entry
        }
    }
}

function Get-LocalARPTable {
    <#
    .SYNOPSIS
        Retrieves the local ARP table to discover devices on the network
    .DESCRIPTION
        Parses the ARP cache to find MAC addresses and IP addresses of devices
        that have recently communicated with this host. No credentials required.
        Missing platform commands, command failures, and recognized-but-malformed
        neighbor lines produce terminating errors instead of an empty-cache result.
    .PARAMETER InterfaceAlias
        Optional network interface to filter results
    .EXAMPLE
        Get-LocalARPTable

        Returns all ARP entries from the local cache
    .EXAMPLE
        $devices = Get-LocalARPTable | Where-Object { $_.Type -eq 'dynamic' }

        Get only dynamically learned ARP entries
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$InterfaceAlias
    )

    $arpEntries = @()

    if ($IsWindows) {
            # Windows: Use Get-NetNeighbor
            $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop

            if ($InterfaceAlias) {
                $neighbors = $neighbors | Where-Object { $_.InterfaceAlias -eq $InterfaceAlias }
            }

            foreach ($entry in $neighbors) {
                $arpEntries += [pscustomobject]@{
                    IPAddress       = $entry.IPAddress
                    MACAddress      = $entry.LinkLayerAddress
                    State           = $entry.State
                    InterfaceAlias  = $entry.InterfaceAlias
                    InterfaceIndex  = $entry.InterfaceIndex
                }
            }
    }
    elseif ($IsMacOS) {
            $null = Get-Command arp -CommandType Application -ErrorAction Stop
            $arpOutput = & arp -an 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "arp -an failed with exit code $LASTEXITCODE"
            }
            $arpEntries = @(ConvertFrom-ArpText -Lines $arpOutput -Format MacOS -InterfaceAlias $InterfaceAlias)
    }
    elseif ($IsLinux) {
            $ipCommand = Get-Command ip -CommandType Application -ErrorAction SilentlyContinue
            if ($ipCommand) {
                $neighborOutput = & $ipCommand.Source neigh show 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "ip neigh show failed with exit code $LASTEXITCODE"
                }
                $arpEntries = @(ConvertFrom-ArpText -Lines $neighborOutput -Format LinuxIp -InterfaceAlias $InterfaceAlias)
            }
            else {
                $arpCommand = Get-Command arp -CommandType Application -ErrorAction Stop
                $arpOutput = & $arpCommand.Source -an 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "arp -an failed with exit code $LASTEXITCODE"
                }
                $arpEntries = @(ConvertFrom-ArpText -Lines $arpOutput -Format LinuxArp -InterfaceAlias $InterfaceAlias)
            }
    }

    Write-Verbose "Found $($arpEntries.Count) ARP entries"
    return $arpEntries
}

function Wait-DnsLookupTask {
    param(
        [Parameter(Mandatory)][System.Threading.Tasks.Task]$LookupTask,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    try {
        if ($LookupTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            $result = $LookupTask.Result
            return [pscustomobject]@{
                IPAddress = $IPAddress
                Hostname  = $result.HostName
                Aliases   = $result.Aliases
                Success   = $true
            }
        }

        Write-Verbose "DNS lookup for $IPAddress timed out after $TimeoutSeconds second(s)"
    }
    catch {
        Write-Verbose "DNS lookup for $IPAddress failed: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        IPAddress = $IPAddress
        Hostname  = $null
        Aliases   = @()
        Success   = $false
    }
}

function Resolve-IPHostname {
    <#
    .SYNOPSIS
        Performs reverse DNS lookup for IP addresses
    .DESCRIPTION
        Attempts to resolve hostnames from IP addresses using DNS PTR records.
        No credentials required.
    .PARAMETER IPAddress
        IP address or array of IP addresses to resolve
    .PARAMETER TimeoutSeconds
        DNS query timeout in seconds, 1-300 (default: 2). Enforced with an async lookup;
        addresses that do not resolve within the window are returned with Success = $false.
    .EXAMPLE
        Resolve-IPHostname -IPAddress '8.8.8.8'

        Resolves the hostname for Google DNS
    .EXAMPLE
        $ips = @('192.168.1.1', '192.168.1.10')
        $ips | Resolve-IPHostname

        Resolve multiple IP addresses
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$IPAddress,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 2
    )

    process {
        foreach ($ip in $IPAddress) {
            try {
                # Honor TimeoutSeconds: resolve asynchronously and wait at most
                # $TimeoutSeconds so a slow or unreachable resolver cannot hang the
                # pipeline. On timeout we return a failure object (the background task
                # is abandoned).
                $task = [System.Net.Dns]::GetHostEntryAsync($ip)
                Wait-DnsLookupTask -LookupTask $task -IPAddress $ip -TimeoutSeconds $TimeoutSeconds
            }
            catch {
                [pscustomobject]@{
                    IPAddress = $ip
                    Hostname  = $null
                    Aliases   = @()
                    Success   = $false
                }
            }
        }
    }
}

function Get-MACVendor {
    <#
    .SYNOPSIS
        Looks up vendor information from MAC address OUI
    .DESCRIPTION
        Identifies the manufacturer of a network device based on its MAC address
        using the Organizationally Unique Identifier (OUI) lookup.
        No credentials required. The built-in table is a 31-prefix sample; for
        full coverage download the IEEE oui.csv and use -OuiDatabasePath.

        Example to fetch the full registry:
          Invoke-WebRequest -Uri https://standards-oui.ieee.org/oui/oui.csv -OutFile ./oui.csv
          Get-MACVendor -MACAddress '00:1A:A0:12:34:56' -OuiDatabasePath ./oui.csv
    .PARAMETER MACAddress
        MAC address in any common format (AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF, AABBCCDDEEFF)
    .EXAMPLE
        Get-MACVendor -MACAddress '00:1A:A0:12:34:56'

        Returns vendor information for the MAC address
    .EXAMPLE
        Get-LocalARPTable | ForEach-Object { Get-MACVendor -MACAddress $_.MACAddress }

        Get vendor info for all devices in ARP table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$MACAddress,

        [Parameter()]
        [string]$OuiDatabasePath
    )

    begin {
        # Common OUI prefix database (top vendors) — 31-prefix sample
        $ouiDatabase = @{
            '00:1A:A0' = 'Dell'
            '00:50:56' = 'VMware'
            '00:0C:29' = 'VMware'
            '00:05:69' = 'VMware'
            '08:00:27' = 'Oracle VirtualBox'
            '52:54:00' = 'QEMU/KVM'
            '00:15:5D' = 'Microsoft Hyper-V'
            '00:03:FF' = 'Microsoft'
            'DC:A6:32' = 'Raspberry Pi'
            'B8:27:EB' = 'Raspberry Pi'
            'E4:5F:01' = 'Raspberry Pi'
            '00:0A:95' = 'Apple'
            'AC:DE:48' = 'Apple'
            '00:1B:63' = 'Apple'
            '00:25:00' = 'Apple'
            '28:6A:BA' = 'Apple'
            '00:23:12' = 'Cisco'
            '00:1E:14' = 'Cisco'
            '00:26:0A' = 'Cisco'
            'D0:D0:FD' = 'Cisco'
            '00:04:96' = 'Cisco'
            '00:E0:4C' = 'Realtek'
            '00:27:22' = 'TP-Link'
            '50:C7:BF' = 'TP-Link'
            '00:50:F2' = 'Microsoft'
            '00:12:3F' = 'Dell'
            '00:14:22' = 'Dell'
            '00:1E:C9' = 'HP'
            '00:21:5A' = 'HP'
            '00:30:6E' = 'Netgear'
            '00:09:5B' = 'Netgear'
        }

        # Optionally load full IEEE oui.csv (Assignment, Organization Name)
        if ($OuiDatabasePath) {
            if (-not (Test-Path -LiteralPath $OuiDatabasePath)) {
                throw "OUI database file not found: '$OuiDatabasePath'"
            }
            try {
                $rows = Import-Csv -LiteralPath $OuiDatabasePath
                if ($rows.Count -eq 0 -or -not $rows[0].PSObject.Properties['Assignment'] -or -not $rows[0].PSObject.Properties['Organization Name']) {
                    throw "OUI CSV missing required columns 'Assignment' and 'Organization Name'"
                }
                foreach ($r in $rows) {
                    $assignment = ([string]$r.Assignment -replace '[^0-9A-Fa-f]', '').ToUpper()
                    if ($assignment.Length -ge 6) {
                        $prefix = $assignment.Substring(0, 2) + ':' + $assignment.Substring(2, 2) + ':' + $assignment.Substring(4, 2)
                        $ouiDatabase[$prefix] = [string]$r.'Organization Name'
                    }
                }
            }
            catch {
                throw "Failed to load OUI database '$OuiDatabasePath': $_"
            }
        }
    }

    process {
        foreach ($mac in $MACAddress) {
            if ([string]::IsNullOrWhiteSpace($mac)) {
                continue
            }

            $oui = $null
            $vendor = 'Unknown'

            # Remove non-hex characters and normalize to AA:BB:CC:DD:EE:FF
            $hexOnly = ($mac -replace '[^0-9A-Fa-f]', '').ToUpper()

            if ($hexOnly.Length -ge 12) {
                $hexOnly = $hexOnly.Substring(0, 12)

                $octets = for ($i = 0; $i -lt 12; $i += 2) {
                    $hexOnly.Substring($i, 2)
                }

                $normalizedMAC = ($octets -join ':')
                $oui = ($octets[0..2] -join ':')

                if ($ouiDatabase.ContainsKey($oui)) {
                    $vendor = $ouiDatabase[$oui]
                }
            }
            else {
                $normalizedMAC = $mac.ToUpper()
                $vendor = 'Invalid MAC'
            }

            [pscustomobject]@{
                MACAddress = $normalizedMAC
                OUI        = $oui
                Vendor     = $vendor
            }
        }
    }
}

function Invoke-PortScan {
    <#
    .SYNOPSIS
        Scans common network service ports on target hosts
    .DESCRIPTION
        Performs TCP port scanning and banner grabbing on common service ports.
        No credentials required. Useful for identifying services and device types.
    .PARAMETER IPAddress
        Target IP address or array of IP addresses
    .PARAMETER Ports
        Array of TCP ports to scan, 1-65535 (default: common TCP service ports).
        Note: SNMP (161) is UDP and is deliberately NOT in the defaults - a TCP probe of
        161 does not detect SNMP. Use Invoke-SnmpWalk for SNMP.
    .PARAMETER TimeoutMs
        Per-port connection timeout in milliseconds, 1-60000 (default: 1000)
    .PARAMETER GrabBanners
        Attempt to grab service banners from open ports
    .EXAMPLE
        Invoke-PortScan -IPAddress '192.168.1.1'

        Scan common ports on a single host
    .EXAMPLE
        Invoke-PortScan -IPAddress '192.168.1.1' -Ports @(80,443,22) -GrabBanners

        Scan specific ports and grab banners
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$IPAddress,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int[]]$Ports = @(21, 22, 23, 25, 80, 443, 445, 3389, 8080, 8443),

        [Parameter()]
        [ValidateRange(1, 60000)]
        [int]$TimeoutMs = 1000,

        [Parameter()]
        [switch]$GrabBanners
    )

    process {
        foreach ($ip in $IPAddress) {
            Write-Verbose "Scanning $ip..."

            $openPorts = @()

            foreach ($port in $Ports) {
                $tcpClient = [System.Net.Sockets.TcpClient]::new()
                $connectResult = $null

                try {
                    $connectResult = $tcpClient.BeginConnect($ip, $port, $null, $null)
                    $connectedInTime = $connectResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

                    if (-not $connectedInTime) {
                        continue
                    }

                    try {
                        $tcpClient.EndConnect($connectResult)
                    }
                    catch {
                        continue
                    }

                    if (-not $tcpClient.Connected) {
                        continue
                    }

                    $banner = $null

                    if ($GrabBanners) {
                        try {
                            $stream = $tcpClient.GetStream()
                            if ($stream.CanRead) {
                                $stream.ReadTimeout = 500
                                $buffer = New-Object byte[] 1024
                                $bytesRead = $stream.Read($buffer, 0, 1024)
                                if ($bytesRead -gt 0) {
                                    $banner = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead).Trim()
                                }
                            }
                        }
                        catch {
                            # Banner grab failed, that's OK
                        }
                    }

                    $openPorts += [pscustomobject]@{
                        Port    = $port
                        State   = 'Open'
                        Service = Get-ServiceName -Port $port
                        Banner  = $banner
                    }

                    Write-Verbose "  Port $port - Open"
                }
                catch {
                    # Port closed or filtered
                }
                finally {
                    if ($connectResult -and $connectResult.AsyncWaitHandle) {
                        $connectResult.AsyncWaitHandle.Close()
                    }
                    $tcpClient.Dispose()
                }
            }

            [pscustomobject]@{
                IPAddress = $ip
                OpenPorts = $openPorts
                ScanTime  = Get-Date
            }
        }
    }
}

function Get-ServiceName {
    <#
    .SYNOPSIS
        Maps port numbers to common service names
    #>
    param([int]$Port)

    $services = @{
        21   = 'FTP'
        22   = 'SSH'
        23   = 'Telnet'
        25   = 'SMTP'
        53   = 'DNS'
        80   = 'HTTP'
        110  = 'POP3'
        143  = 'IMAP'
        161  = 'SNMP'
        443  = 'HTTPS'
        445  = 'SMB'
        3389 = 'RDP'
        8080 = 'HTTP-ALT'
        8443 = 'HTTPS-ALT'
    }

    if ($services.ContainsKey($Port)) {
        return $services[$Port]
    }
    return "Unknown"
}

#endregion

#region Level 3: Default Credential Testing (Opt-In)

function Get-CommonSNMPStrings {
    <#
    .SYNOPSIS
        Returns a list of common default SNMP community strings
    .DESCRIPTION
        Provides the most commonly used default SNMP community strings
        for testing. For security research and authorized testing only.
    .EXAMPLE
        Get-CommonSNMPStrings

        Returns array of common strings
    #>
    [CmdletBinding()]
    param()

    @(
        'public'
        'private'
        'community'
        'snmp'
        'manager'
        'monitor'
        'cisco'
        'admin'
        'security'
        'default'
    )
}

#endregion

# Export all public functions
Export-ModuleMember -Function @(
    # Core inventory and topology
    'Import-Inventory'
    'Import-NmapScan'
    'Test-DeviceReachability'
    'Invoke-NetworkDiscovery'
    'Merge-Edges'

    # Level 1: Credential-Free Discovery
    'Get-LocalARPTable'
    'Resolve-IPHostname'
    'Get-MACVendor'
    'Invoke-PortScan'

    # Level 2 & 3: SNMP Discovery
    'Invoke-SnmpWalk'
    'Get-SnmpNeighbors'
    'Get-CommonSNMPStrings'

    # Export and Analysis
    'Export-DrawIO'
    'Export-Mermaid'
    'Export-Metadata'
    'Export-Topology'
    'Import-Topology'
    'Export-NodeInventoryCsv'
    'Compare-NetworkScans'
)
