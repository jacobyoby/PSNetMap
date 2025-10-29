#Requires -Version 7.0

<#
.SYNOPSIS
    NetDiagram-PS - Network discovery and diagram generation module
.DESCRIPTION
    Discovers network nodes/links and emits valid .drawio files with SNMP support
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-level variables
$script:ModuleVersion = '1.0.1'

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

#endregion

#region Import-Inventory

function Import-Inventory {
    <#
    .SYNOPSIS
        Imports network inventory from JSON file
    .DESCRIPTION
        Reads a JSON inventory file and creates a Topology object with Nodes and Subnets.
        Nodes are enriched with Layer information based on their role.
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

        $topology = New-EmptyTopology

        # Process known devices
        $nodes = foreach ($device in $inventory.knownDevices) {
            if ([string]::IsNullOrWhiteSpace($device.ip)) {
                Write-Warning "Skipping device without IP address"
                continue
            }

            $role = if ($device.PSObject.Properties['role']) { $device.role } else { 'unknown' }
            $layer = Get-LayerFromRole -Role $role

            [pscustomobject]@{
                IP        = $device.ip
                Hostname  = if ($device.PSObject.Properties['hostname']) { $device.hostname } else { $device.ip }
                Role      = $role
                Vendor    = if ($device.PSObject.Properties['vendor']) { $device.vendor } else { 'Unknown' }
                OS        = if ($device.PSObject.Properties['os']) { $device.os } else { 'Unknown' }
                Layer     = $layer
                Reachable = $null
            }
        }

        $topology.Nodes = @($nodes)

        # Process subnets if present
        if ($inventory.PSObject.Properties['subnets'] -and $inventory.subnets) {
            $subnets = foreach ($subnet in $inventory.subnets) {
                if ([string]::IsNullOrWhiteSpace($subnet.cidr)) {
                    Write-Warning "Skipping subnet without CIDR"
                    continue
                }

                [pscustomobject]@{
                    CIDR  = $subnet.cidr
                    Label = if ($subnet.PSObject.Properties['label']) { $subnet.label } else { $subnet.cidr }
                    VLAN  = if ($subnet.PSObject.Properties['vlan']) { $subnet.vlan } else { $null }
                }
            }
            $topology.Subnets = @($subnets)
        }

        Write-Verbose "Imported $($topology.Nodes.Count) nodes and $($topology.Subnets.Count) subnets"

        return $topology
    }
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
        [int]$TimeoutSeconds = 1
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

        # Create a synchronized hashtable for results
        $results = [System.Collections.Concurrent.ConcurrentDictionary[string,bool]]::new()

        # Test reachability in parallel
        $Topology.Nodes | ForEach-Object -Parallel {
            $node = $_
            $timeout = $using:TimeoutSeconds
            $resultsDict = $using:results

            try {
                $pingResult = Test-Connection -ComputerName $node.IP -Count 1 -TimeoutSeconds $timeout -ErrorAction SilentlyContinue -Quiet
                $null = $resultsDict.TryAdd($node.IP, $pingResult)
            }
            catch {
                $null = $resultsDict.TryAdd($node.IP, $false)
            }
        } -ThrottleLimit $MaxParallel

        # Update nodes with results
        foreach ($node in $Topology.Nodes) {
            $reachable = $false
            if ($results.TryGetValue($node.IP, [ref]$reachable)) {
                $node.Reachable = $reachable
            }
            else {
                $node.Reachable = $false
            }
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
        Invokes snmpwalk.exe against a target device
    .DESCRIPTION
        Calls snmpwalk.exe directly (must be in PATH) with specified OID and credentials.
        Returns raw output lines.
    .PARAMETER TargetIP
        IP address to query
    .PARAMETER Community
        SNMP community string
    .PARAMETER OID
        OID to walk (default: LLDP remote table)
    .PARAMETER Version
        SNMP version (default: v2c)
    .PARAMETER TimeoutSeconds
        Timeout in seconds (default: 2)
    .EXAMPLE
        Invoke-SnmpWalk -TargetIP '10.66.1.1' -Community 'public'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetIP,

        [Parameter(Mandatory)]
        [string]$Community,

        [Parameter()]
        [string]$OID = '1.0.8802.1.1.2.1.4',

        [Parameter()]
        [string]$Version = 'v2c',

        [Parameter()]
        [int]$TimeoutSeconds = 2
    )

    # Check if snmpwalk.exe is available
    $snmpWalkPath = Get-Command -Name 'snmpwalk.exe' -ErrorAction SilentlyContinue
    if (-not $snmpWalkPath) {
        throw "snmpwalk.exe not found in PATH. Please install net-snmp tools."
    }

    try {
        $arguments = @(
            '-' + $Version.ToLower()
            '-c', $Community
            '-t', $TimeoutSeconds.ToString()
            $TargetIP
            $OID
        )

        Write-Verbose "Running: snmpwalk.exe $($arguments -join ' ')"

        $output = & snmpwalk.exe @arguments 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "snmpwalk.exe failed for $TargetIP with exit code $LASTEXITCODE"
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
        Discovers neighbors via SNMP LLDP/CDP
    .DESCRIPTION
        Queries reachable nodes for LLDP neighbor information via SNMP.
        Uses credential map to resolve community strings from SecretManagement.
        Adds discovered edges to the topology with L2-SNMP confidence.
    .PARAMETER Topology
        Topology object with nodes
    .PARAMETER CredentialMapPath
        Path to credential map JSON file
    .PARAMETER OID
        SNMP OID to walk (default: LLDP remote table)
    .PARAMETER TryPublic
        If no credentials found for a node, try the common "public" community string.
        WARNING: This may be logged by security systems. Only use on networks you own.
    .EXAMPLE
        $topo = $topo | Get-SnmpNeighbors -CredentialMapPath '.\examples\credmap.json'
    .EXAMPLE
        $topo = $topo | Get-SnmpNeighbors -CredentialMapPath '.\credmap.json' -TryPublic

        Tries user credentials first, falls back to "public" if none found (with warning)
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

        # Only query reachable nodes
        $reachableNodes = @($Topology.Nodes | Where-Object { $_.Reachable -eq $true })
        if ($reachableNodes.Count -eq 0) {
            Write-Warning "No reachable nodes to query via SNMP"
            return $Topology
        }

        Write-Verbose "Querying SNMP neighbors for $($reachableNodes.Count) reachable nodes"

        $discoveredEdges = [System.Collections.ArrayList]::new()
        $publicAttempts = 0

        foreach ($node in $reachableNodes) {
            # Resolve SNMP community for this node
            $community = $null
            $communitySecret = $null
            $source = 'CredentialMap'

            if ($credMap.PSObject.Properties['snmp'] -and $credMap.snmp) {
                foreach ($cidrEntry in $credMap.snmp.PSObject.Properties) {
                    $cidr = $cidrEntry.Name
                    $config = $cidrEntry.Value

                    # Simple CIDR matching (for MVP, just match Default or exact match)
                    if ($cidr -eq 'Default' -or (Test-IPInSubnet -IP $node.IP -CIDR $cidr)) {
                        if ($config.PSObject.Properties['communitySecret']) {
                            $communitySecret = $config.communitySecret
                            break
                        }
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
                continue
            }

            # Invoke SNMP walk
            Write-Verbose "  Querying $($node.IP) with community from $source"
            $output = Invoke-SnmpWalk -TargetIP $node.IP -Community $community -OID $OID -ErrorAction SilentlyContinue

            if ($output.Count -eq 0) {
                Write-Verbose "No SNMP data returned from $($node.IP)"
                continue
            }

            # Parse LLDP output (simplified parser for MVP)
            # Expected format: iso.0.8802.1.1.2.1.4.1.1.X.Y.Z = Type: Value
            foreach ($line in $output) {
                if ($line -match '(\d+\.\d+\.\d+\.\d+)') {
                    $targetIP = $matches[1]

                    # Check if target IP is in our topology
                    $targetNode = $Topology.Nodes | Where-Object { $_.IP -eq $targetIP }
                    if (-not $targetNode) {
                        continue
                    }

                    # Extract interface label if possible
                    $label = 'LLDP'
                    if ($line -match 'ifName|Interface|Port\s*[:=]\s*(\S+)') {
                        $label = $matches[1]
                    }

                    $edge = [pscustomobject]@{
                        SourceIP   = $node.IP
                        TargetIP   = $targetIP
                        Label      = $label
                        Source     = 'SNMP'
                        Confidence = 'L2-SNMP'
                    }

                    $null = $discoveredEdges.Add($edge)
                }
            }
        }

        Write-Verbose "Discovered $($discoveredEdges.Count) SNMP edges"

        if ($TryPublic -and $publicAttempts -gt 0) {
            Write-Warning "Used default 'public' community string on $publicAttempts device(s)"
        }

        # Merge new edges with existing ones
        $allEdges = @($Topology.Edges) + @($discoveredEdges)
        $Topology.Edges = Merge-Edges -Edges $allEdges

        return $Topology
    }
}

function Test-IPInSubnet {
    <#
    .SYNOPSIS
        Simple CIDR matching helper
    #>
    param([string]$IP, [string]$CIDR)

    # Simplified implementation for MVP - just check if IP starts with subnet prefix
    if ($CIDR -match '^(\d+\.\d+)') {
        return $IP.StartsWith($matches[1])
    }
    return $false
}

#endregion

#region Merge-Edges

function Merge-Edges {
    <#
    .SYNOPSIS
        Merges and deduplicates edge candidates
    .DESCRIPTION
        Deduplicates edges using sorted endpoints as key.
        Prioritizes L2-SNMP confidence over L3-Inferred.
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

        if ($edgeMap.Contains($key)) {
            $existing = $edgeMap[$key]

            # Prioritize L2-SNMP confidence
            if ($edge.Source -eq 'SNMP' -and $existing.Source -ne 'SNMP') {
                $existing.Source = 'SNMP'
                $existing.Confidence = 'L2-SNMP'
            }

            # Keep first non-empty label
            if ([string]::IsNullOrWhiteSpace($existing.Label) -and -not [string]::IsNullOrWhiteSpace($edge.Label)) {
                $existing.Label = $edge.Label
            }
        }
        else {
            # Add new edge with confidence
            $confidence = if ($edge.PSObject.Properties['Confidence']) {
                $edge.Confidence
            }
            elseif ($edge.Source -eq 'SNMP') {
                'L2-SNMP'
            }
            else {
                'L3-Inferred'
            }

            $edgeMap[$key] = [pscustomobject]@{
                SourceIP   = $edge.SourceIP
                TargetIP   = $edge.TargetIP
                Label      = if ($edge.PSObject.Properties['Label']) { $edge.Label } else { '' }
                Source     = if ($edge.PSObject.Properties['Source']) { $edge.Source } else { 'Unknown' }
                Confidence = $confidence
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile
    )

    process {
        if ($null -eq $Topology -or $null -eq $Topology.Nodes) {
            throw "Invalid topology object"
        }

        # Build node ID map
        $nodeIDMap = @{}
        $nextID = 2  # Start after mxCell id="0" and id="1"

        foreach ($node in $Topology.Nodes) {
            if (-not [string]::IsNullOrWhiteSpace($node.IP)) {
                $nodeIDMap[$node.IP] = $nextID++
            }
        }

        # Layer order for Y-axis positioning
        $layerOrder = @('Core', 'Dist', 'Access', 'Servers')

        # Group nodes by layer
        $nodesByLayer = @{}
        foreach ($layer in $layerOrder) {
            $nodesByLayer[$layer] = @($Topology.Nodes | Where-Object { $_.Layer -eq $layer })
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

        # Add subnet containers (best practice: group by network segment)
        $containerID = $nextID
        $subnetContainers = @{}

        foreach ($subnet in $Topology.Subnets) {
            $subnetLabel = [System.Security.SecurityElement]::Escape("$($subnet.Label)`n$($subnet.CIDR)")
            $containerStyle = 'swimlane;fontSize=14;fontStyle=1;fillColor=#f5f5f5;strokeColor=#666666;rounded=1;'

            # Calculate container size based on nodes in subnet
            $containerWidth = 800
            $containerHeight = 550
            $containerX = 20 + (($subnetContainers.Count % 2) * 850)
            $containerY = 20 + ([Math]::Floor($subnetContainers.Count / 2) * 600)

            $null = $xml.AppendLine("        <mxCell id=`"$containerID`" value=`"$subnetLabel`" style=`"$containerStyle`" parent=`"1`" vertex=`"1`">")
            $null = $xml.AppendLine("          <mxGeometry x=`"$containerX`" y=`"$containerY`" width=`"$containerWidth`" height=`"$containerHeight`" as=`"geometry`"/>")
            $null = $xml.AppendLine('        </mxCell>')

            $subnetContainers[$subnet.CIDR] = $containerID
            $containerID++
        }

        $nextID = $containerID

        # Add nodes with enhanced styles and metadata
        foreach ($layer in $layerOrder) {
            $nodesInLayer = $nodesByLayer[$layer]
            $yPos = 60 + ($layerOrder.IndexOf($layer) * 130)

            for ($i = 0; $i -lt $nodesInLayer.Count; $i++) {
                $node = $nodesInLayer[$i]
                $xPos = 60 + ($i * 190)
                $nodeID = $nodeIDMap[$node.IP]

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

                # Override fill color for reachability status
                if ($node.Reachable -eq $true) {
                    $shapeConfig.fillColor = '#d5e8d4'
                    $shapeConfig.strokeColor = '#82b366'
                } elseif ($node.Reachable -eq $false) {
                    $shapeConfig.fillColor = '#f8cecc'
                    $shapeConfig.strokeColor = '#b85450'
                }

                # Node label with better formatting (escape entire label for XML)
                $labelText = $node.Hostname
                if ($node.IP -ne $node.Hostname) {
                    $labelText += "`n$($node.IP)"
                }
                $label = [System.Security.SecurityElement]::Escape($labelText)

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
                    "Status: $(if ($node.Reachable) { 'Reachable' } else { 'Unreachable' })"
                )
                $tooltip = [System.Security.SecurityElement]::Escape(($tooltipParts -join "`n"))

                $null = $xml.AppendLine("        <mxCell id=`"$nodeID`" value=`"$label`" style=`"$nodeStyle`" parent=`"1`" vertex=`"1`">")
                $null = $xml.AppendLine("          <mxGeometry x=`"$xPos`" y=`"$yPos`" width=`"140`" height=`"80`" as=`"geometry`"/>")
                $null = $xml.AppendLine('        </mxCell>')

                # Add custom metadata as UserObject (best practice)
                # Note: In production, this would replace the mxCell with UserObject, but keeping it simple for MVP
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [Parameter()]
        [string[]]$CredSetsUsed = @()
    )

    process {
        if ($null -eq $Topology) {
            throw "Invalid topology object"
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

        $metadata = [ordered]@{
            scanStarted       = (Get-Date).ToString('o')
            scanFinished      = (Get-Date).ToString('o')
            tool              = "NetDiagram-PS $script:ModuleVersion"
            credSetsUsed      = @($CredSetsUsed)
            confidenceCounts  = $confidenceCounts
            nodeCount         = $Topology.Nodes.Count
            edgeCount         = $Topology.Edges.Count
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

    # Load files
    try {
        $baseMeta = Get-Content -Path $BaselineMetadata -Raw | ConvertFrom-Json
        $baseTopoData = Get-Content -Path $BaselineTopology -Raw | ConvertFrom-Json
        $currMeta = Get-Content -Path $CurrentMetadata -Raw | ConvertFrom-Json
        $currTopoData = Get-Content -Path $CurrentTopology -Raw | ConvertFrom-Json
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
    $removedNodes = @($baseNodeIPs | Where-Object { $_ -notin $currNodeIPs })

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

function Get-LocalARPTable {
    <#
    .SYNOPSIS
        Retrieves the local ARP table to discover devices on the network
    .DESCRIPTION
        Parses the ARP cache to find MAC addresses and IP addresses of devices
        that have recently communicated with this host. No credentials required.
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

    try {
        $arpEntries = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue

        if ($InterfaceAlias) {
            $arpEntries = $arpEntries | Where-Object { $_.InterfaceAlias -eq $InterfaceAlias }
        }

        foreach ($entry in $arpEntries) {
            [pscustomobject]@{
                IPAddress       = $entry.IPAddress
                MACAddress      = $entry.LinkLayerAddress
                State           = $entry.State
                InterfaceAlias  = $entry.InterfaceAlias
                InterfaceIndex  = $entry.InterfaceIndex
            }
        }

        Write-Verbose "Found $($arpEntries.Count) ARP entries"
    }
    catch {
        Write-Warning "Failed to retrieve ARP table: $_"
        return @()
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
        DNS query timeout in seconds (default: 2)
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
        [int]$TimeoutSeconds = 2
    )

    process {
        foreach ($ip in $IPAddress) {
            try {
                $result = [System.Net.Dns]::GetHostEntry($ip)

                [pscustomobject]@{
                    IPAddress = $ip
                    Hostname  = $result.HostName
                    Aliases   = $result.Aliases
                    Success   = $true
                }
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
        No credentials required, uses built-in OUI database.
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
        [string[]]$MACAddress
    )

    begin {
        # Common OUI prefix database (top vendors)
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
    }

    process {
        foreach ($mac in $MACAddress) {
            if ([string]::IsNullOrWhiteSpace($mac)) {
                continue
            }

            # Normalize MAC address format
            $normalizedMAC = $mac.Replace('-', ':').Replace('.', ':').ToUpper()

            # Extract OUI (first 3 octets)
            if ($normalizedMAC -match '^([0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2})') {
                $oui = $matches[1]
                $vendor = $ouiDatabase[$oui]

                if (-not $vendor) {
                    $vendor = 'Unknown'
                }
            }
            else {
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
        Array of ports to scan (default: common ports 21,22,23,80,443,161,3389,8080)
    .PARAMETER TimeoutMs
        Connection timeout in milliseconds (default: 1000)
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
        [int[]]$Ports = @(21, 22, 23, 25, 80, 443, 161, 445, 3389, 8080, 8443),

        [Parameter()]
        [int]$TimeoutMs = 1000,

        [Parameter()]
        [switch]$GrabBanners
    )

    process {
        foreach ($ip in $IPAddress) {
            Write-Verbose "Scanning $ip..."

            $openPorts = @()

            foreach ($port in $Ports) {
                try {
                    $tcpClient = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcpClient.BeginConnect($ip, $port, $null, $null)
                    $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

                    if ($wait -and $tcpClient.Connected) {
                        $banner = $null

                        # Attempt banner grabbing if requested
                        if ($GrabBanners) {
                            try {
                                $stream = $tcpClient.GetStream()
                                $stream.ReadTimeout = 500
                                $buffer = New-Object byte[] 1024
                                $bytesRead = $stream.Read($buffer, 0, 1024)
                                if ($bytesRead -gt 0) {
                                    $banner = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead).Trim()
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

                    $tcpClient.Close()
                }
                catch {
                    # Port closed or filtered
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
    'Test-DeviceReachability'
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
    'Export-Metadata'
    'Compare-NetworkScans'
)
