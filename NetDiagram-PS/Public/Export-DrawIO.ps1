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
            # Visual rank matches Merge-Edges: L2-SNMP > L2-FDB > L2-SNMP-Heuristic > L3-Inferred
            if ($confidence -eq 'L2-SNMP') {
                # L2-SNMP: Solid line, green, thicker (verified CDP/LLDP)
                $edgeStyle += 'strokeColor=#2D7600;strokeWidth=2.5;'
                $edgeStyle += 'endArrow=classic;endFill=1;'
            }
            elseif ($confidence -eq 'L2-FDB') {
                # L2-FDB: Solid teal — verified-ish bridge forwarding table,
                # distinct from SNMP green and from dashed heuristic/L3 styles.
                $edgeStyle += 'strokeColor=#0B7285;strokeWidth=2;dashed=0;'
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
