$script:LayerOrder = @('Core','Dist','Access','Servers')
$script:NodeWidth = 140
$script:NodeHeight = 70
$script:NodeXSpacing = 180
$script:NodeStartX = 40
$script:NodeStartY = 40
$script:LayerSpacing = 120
$script:ToolVersion = 'NetDiagram-PS 0.1.0'

function Get-RoleLayer {
    param([string]$Role)
    if ([string]::IsNullOrWhiteSpace($Role)) { return 'Access' }
    switch -Regex ($Role) {
        'core' { return 'Core' }
        'distribution' { return 'Dist' }
        'router' { return 'Core' }
        'switch' { return 'Access' }
        'server' { return 'Servers' }
        default { return 'Access' }
    }
}

function Test-CidrMatch {
    param(
        [string]$Cidr,
        [string]$Ip
    )
    if ([string]::IsNullOrWhiteSpace($Cidr) -or [string]::IsNullOrWhiteSpace($Ip)) {
        return $false
    }
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { return $false }
    $network = $parts[0]
    $prefix = [int]$parts[1]
    try {
        $ipBytes = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
        $netBytes = [System.Net.IPAddress]::Parse($network).GetAddressBytes()
    } catch {
        return $false
    }
    if ($ipBytes.Length -ne $netBytes.Length) { return $false }
    $bitsToCheck = $prefix
    for ($i = 0; $i -lt $ipBytes.Length; $i++) {
        if ($bitsToCheck -ge 8) {
            $mask = 0xFF
        } elseif ($bitsToCheck -le 0) {
            $mask = 0x00
        } else {
            $mask = 0
            for ($b = 0; $b -lt $bitsToCheck; $b++) {
                $mask = $mask -bor (1 -shl (7 - $b))
            }
        }
        if (($ipBytes[$i] -band $mask) -ne ($netBytes[$i] -band $mask)) { return $false }
        $bitsToCheck -= 8
    }
    return $true
}

function Get-SecretValue {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $secretCommand = Get-Command -Name 'Get-Secret' -ErrorAction SilentlyContinue
    if (-not $secretCommand) {
        throw [System.Management.Automation.CommandNotFoundException]::new('Get-Secret not found.')
    }
    $secret = & $secretCommand.Source -Name $Name -ErrorAction Stop
    if ($secret -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $secret).Password
    }
    return [string]$secret
}

function Import-Inventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName=$true, ValueFromPipeline=$true)]
        [string]$Path
    )

    process {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw "Inventory file '$Path' was not found."
        }

        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $data = $content | ConvertFrom-Json -ErrorAction Stop

        $nodes = @()
        foreach ($device in $data.knownDevices) {
            $layer = Get-RoleLayer -Role $device.role
            $node = [pscustomobject]@{
                IP         = $device.ip
                Hostname   = $device.hostname
                Role       = $device.role
                Vendor     = $device.vendor
                OS         = $device.os
                Layer      = $layer
                Reachable  = $false
            }
            $nodes += $node
        }

        $subnets = @()
        foreach ($subnet in $data.subnets) {
            $subnets += [pscustomobject]@{
                cidr  = $subnet.cidr
                label = $subnet.label
                vlan  = $subnet.vlan
            }
        }

        return [pscustomobject]@{
            Nodes   = $nodes
            Edges   = @()
            Subnets = $subnets
        }
    }
}

function Test-DeviceReachability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        $Topology,
        [int]$MaxParallel = 32,
        [ScriptBlock]$PingScript = { param($ip) Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeoutSeconds 1 }
    )
    process {
        if (-not $Topology) { return }
        if (-not $Topology.Nodes) { return $Topology }

        $nodes = $Topology.Nodes
        $updatedNodes = $nodes | ForEach-Object -Parallel {
            param($invokeScript)
            $node = $_ | Select-Object -Property *
            if ([string]::IsNullOrWhiteSpace($node.IP)) {
                $node.Reachable = $false
                return $node
            }
            try {
                $reachable = & $invokeScript $node.IP
                $node.Reachable = [bool]$reachable
            } catch {
                $node.Reachable = $false
            }
            return $node
        } -ThrottleLimit $MaxParallel -ArgumentList $PingScript

        $Topology.Nodes = $updatedNodes
        return $Topology
    }
}

function Invoke-SnmpWalk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Oid = '1.0.8802.1.1.2.1.4',
        [string]$Community,
        [string]$CredentialName,
        [int]$TimeoutSeconds = 5
    )

    $command = Get-Command -Name 'snmpwalk.exe' -ErrorAction SilentlyContinue
    if (-not $command) {
        Write-Warning 'snmpwalk.exe not found in PATH. Skipping SNMP walk.'
        return @()
    }

    if (-not $Community -and $CredentialName) {
        try {
            $Community = Get-SecretValue -Name $CredentialName
        } catch {
            Write-Warning "Unable to resolve secret '$CredentialName' for target $Target: $($_.Exception.Message)"
            return @()
        }
    }

    if ([string]::IsNullOrWhiteSpace($Community)) {
        Write-Warning "No SNMP community provided for target $Target."
        return @()
    }

    $arguments = @('-v2c', '-c', $Community, '-t', [string]$TimeoutSeconds, $Target, $Oid)
    try {
        $output = & $command.Source $arguments
        return $output
    } catch {
        Write-Warning "snmpwalk.exe failed for $Target: $($_.Exception.Message)"
        return @()
    }
}

function Get-SnmpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        $Topology,
        [string]$CredentialMap,
        [int]$TimeoutSeconds = 5
    )

    begin {
        $credConfig = $null
        if ($CredentialMap) {
            if (-not (Test-Path -LiteralPath $CredentialMap)) {
                throw "Credential map file '$CredentialMap' not found."
            }
            $credConfig = (Get-Content -LiteralPath $CredentialMap -Raw) | ConvertFrom-Json -ErrorAction Stop
        }

        function Resolve-SnmpCommunity {
            param([string]$Ip)
            if (-not $credConfig -or -not $credConfig.snmp) { return $null }
            $bestMatch = $null
            foreach ($entry in $credConfig.snmp.PSObject.Properties) {
                if (Test-CidrMatch -Cidr $entry.Name -Ip $Ip) {
                    if (-not $bestMatch) {
                        $bestMatch = $entry
                    } else {
                        $currentMask = [int]($bestMatch.Name.Split('/')[1])
                        $newMask = [int]($entry.Name.Split('/')[1])
                        if ($newMask -gt $currentMask) {
                            $bestMatch = $entry
                        }
                    }
                }
            }
            if (-not $bestMatch) { return $null }
            $secretName = $bestMatch.Value.communitySecret
            if (-not $secretName) { return $null }
            try {
                return Get-SecretValue -Name $secretName
            } catch {
                Write-Warning "Secret '$secretName' unavailable for $Ip: $($_.Exception.Message)"
                return $null
            }
        }

        function Parse-LldpOutput {
            param([string[]]$Lines, [string]$SourceIp)
            $neighbors = @()
            $entries = @{}
            foreach ($line in $Lines) {
                if (-not $line) { continue }
                $parts = $line -split '\s*=\s*', 2
                if ($parts.Count -lt 2) { continue }
                $oid = $parts[0]
                $value = $parts[1]
                if ($oid -match 'lldpRem') {
                    $indexMatch = [regex]::Match($oid, '(\d+\.\d+\.\d+\.\d+\.\d+)$')
                    if (-not $indexMatch.Success) { continue }
                    $index = $indexMatch.Value
                    if (-not $entries.ContainsKey($index)) {
                        $entries[$index] = [ordered]@{}
                    }
                    if ($oid -match 'lldpRemSysName') {
                        $entries[$index]['SysName'] = ($value -replace '^STRING:\s*', '').Trim('"')
                    } elseif ($oid -match 'lldpRemPortDesc|lldpRemPortId') {
                        $entries[$index]['Port'] = ($value -replace '^(STRING|Hex-STRING):\s*', '').Trim()
                    } elseif ($oid -match 'lldpRemManAddr') {
                        $entries[$index]['Address'] = ($value -replace '^(STRING|Hex-STRING):\s*', '').Trim()
                    }
                }
            }
            foreach ($entryKey in $entries.Keys) {
                $entry = $entries[$entryKey]
                $targetIp = $entry['Address']
                if ([string]::IsNullOrWhiteSpace($targetIp)) { continue }
                $label = $entry['Port']
                $neighbors += [pscustomobject]@{
                    SourceIP  = $SourceIp
                    TargetIP  = $targetIp
                    Label     = $label
                    Source    = 'SNMP'
                    Confidence = 'L2-SNMP'
                }
            }
            return $neighbors
        }
    }

    process {
        if (-not $Topology) { return }
        if (-not $Topology.Nodes) { return $Topology }
        $snmpEdges = @()
        foreach ($node in $Topology.Nodes) {
            if (-not $node.IP) { continue }
            $community = Resolve-SnmpCommunity -Ip $node.IP
            if (-not $community) {
                Write-Verbose "Skipping SNMP for $($node.IP) due to missing community."
                continue
            }
            $output = Invoke-SnmpWalk -Target $node.IP -Community $community -TimeoutSeconds $TimeoutSeconds
            if (-not $output) { continue }
            $edges = Parse-LldpOutput -Lines $output -SourceIp $node.IP
            if ($edges) { $snmpEdges += $edges }
        }
        if ($snmpEdges) {
            if (-not $Topology.Edges) { $Topology.Edges = @() }
            $Topology.Edges = @($Topology.Edges + $snmpEdges)
        }
        return $Topology
    }
}

function Merge-Edges {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true)]
        [pscustomobject[]]$InputObject
    )
    begin {
        $edgeMap = @{}
    }
    process {
        foreach ($edge in $InputObject) {
            if (-not $edge) { continue }
            $source = [string]$edge.SourceIP
            $target = [string]$edge.TargetIP
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($target)) { continue }
            $sorted = @($source, $target) | Sort-Object
            $key = "$($sorted[0])|$($sorted[1])"
            if (-not $edgeMap.ContainsKey($key)) {
                $edgeMap[$key] = $edge | Select-Object -Property *
            } else {
                $existing = $edgeMap[$key]
                if ([string]::IsNullOrWhiteSpace($existing.Label) -and -not [string]::IsNullOrWhiteSpace($edge.Label)) {
                    $existing.Label = $edge.Label
                }
                if (($edge.Source -eq 'SNMP') -or ($edge.Confidence -eq 'L2-SNMP')) {
                    $existing.Confidence = 'L2-SNMP'
                    $existing.Source = 'SNMP'
                }
            }
        }
    }
    end {
        foreach ($edge in $edgeMap.Values) {
            if ([string]::IsNullOrWhiteSpace($edge.Confidence)) {
                if ($edge.Source -eq 'SNMP') {
                    $edge.Confidence = 'L2-SNMP'
                } else {
                    $edge.Confidence = 'L3-Inferred'
                }
            }
        }
        return $edgeMap.Values
    }
}

function Export-DrawIO {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        $Topology,
        [Parameter(Mandatory)][string]$OutFile
    )

    process {
        if (-not $Topology) { throw 'Topology object cannot be null.' }
        if (-not $Topology.Nodes) { throw 'Topology must include nodes.' }

        $nodeIdMap = @{}
        $nodeCells = @()
        $edgeCells = @()
        $nodeCounter = 0

        $handledNodes = @()
        foreach ($layer in $script:LayerOrder) {
            $layerNodes = @()
            foreach ($node in $Topology.Nodes) {
                $nodeLayer = if ($node.Layer) { $node.Layer } else { Get-RoleLayer -Role $node.Role }
                if ($nodeLayer -eq $layer) { $layerNodes += $node }
            }
            for ($i = 0; $i -lt $layerNodes.Count; $i++) {
                $node = $layerNodes[$i]
                $handledNodes += $node
                $nodeId = "n$($nodeCounter + 2)"
                if ($node.IP) { $nodeIdMap[$node.IP] = $nodeId }
                if ($node.Hostname) { $nodeIdMap["host:$($node.Hostname)"] = $nodeId }
                $x = $script:NodeStartX + ($i * $script:NodeXSpacing)
                $layerIndex = $script:LayerOrder.IndexOf($layer)
                $y = $script:NodeStartY + ($layerIndex * $script:LayerSpacing)
                $valueParts = @()
                if ($node.Hostname) { $valueParts += [System.Security.SecurityElement]::Escape([string]$node.Hostname) }
                if ($node.IP) { $valueParts += [System.Security.SecurityElement]::Escape([string]$node.IP) }
                if (-not $valueParts) { $valueParts = @('Unknown') }
                $value = ($valueParts -join '&#xa;')
                $nodeCells += @"
        <mxCell id="$nodeId" value="$value" style="shape=rectangle;rounded=1;whiteSpace=wrap;align=center;verticalAlign=middle;" vertex="1" parent="1">
          <mxGeometry x="$x" y="$y" width="$script:NodeWidth" height="$script:NodeHeight" as="geometry"/>
        </mxCell>"@
                $nodeCounter++
            }
        }

        $fallbackIndex = 0
        foreach ($node in $Topology.Nodes) {
            if ($handledNodes -contains $node) { continue }
            $nodeId = "n$($nodeCounter + 2)"
            if ($node.IP) { $nodeIdMap[$node.IP] = $nodeId }
            if ($node.Hostname) { $nodeIdMap["host:$($node.Hostname)"] = $nodeId }
            $x = $script:NodeStartX + ($fallbackIndex * $script:NodeXSpacing)
            $y = $script:NodeStartY + (($script:LayerOrder.Count) * $script:LayerSpacing)
            $valueParts = @()
            if ($node.Hostname) { $valueParts += [System.Security.SecurityElement]::Escape([string]$node.Hostname) }
            if ($node.IP) { $valueParts += [System.Security.SecurityElement]::Escape([string]$node.IP) }
            if (-not $valueParts) { $valueParts = @('Unknown') }
            $value = ($valueParts -join '&#xa;')
            $nodeCells += @"
        <mxCell id="$nodeId" value="$value" style="shape=rectangle;rounded=1;whiteSpace=wrap;align=center;verticalAlign=middle;" vertex="1" parent="1">
          <mxGeometry x="$x" y="$y" width="$script:NodeWidth" height="$script:NodeHeight" as="geometry"/>
        </mxCell>"@
            $nodeCounter++
            $fallbackIndex++
        }

        if ($Topology.Edges) {
            $edgeIndex = 0
            foreach ($edge in $Topology.Edges) {
                if (-not $edge) { continue }
                $sourceIp = [string]$edge.SourceIP
                $targetIp = [string]$edge.TargetIP
                if ([string]::IsNullOrWhiteSpace($sourceIp) -or [string]::IsNullOrWhiteSpace($targetIp)) { continue }
                $sourceKey = if ($nodeIdMap.ContainsKey($sourceIp)) { $sourceIp } else { $null }
                $targetKey = if ($nodeIdMap.ContainsKey($targetIp)) { $targetIp } else { $null }
                if (-not $sourceKey -or -not $targetKey) {
                    Write-Warning "Skipping edge from $sourceIp to $targetIp due to missing node.";
                    continue
                }
                $edgeId = "e$edgeIndex"
                $edgeIndex++
                $label = if ($edge.Label) { [System.Security.SecurityElement]::Escape([string]$edge.Label) } else { '' }
                $edgeCells += @"
        <mxCell id="$edgeId" value="$label" style="endArrow=classic;rounded=0;" edge="1" parent="1" source="${nodeIdMap[$sourceKey]}" target="${nodeIdMap[$targetKey]}">
          <mxGeometry relative="1" as="geometry"/>
        </mxCell>"@
            }
        }

        $xml = @"
<mxfile host="app.diagrams.net">
  <diagram id="Net" name="Network">
    <mxGraphModel>
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
$(($nodeCells + $edgeCells) -join "`n")
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
"@
        Set-Content -LiteralPath $OutFile -Value $xml -Encoding UTF8
        return $OutFile
    }
}

function Export-Metadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        $Topology,
        [Parameter(Mandatory)][string]$OutFile,
        [datetime]$ScanStarted = (Get-Date),
        [datetime]$ScanFinished = (Get-Date),
        [string[]]$CredSetsUsed = @()
    )
    process {
        if (-not $Topology) { throw 'Topology cannot be null.' }
        $edges = $Topology.Edges
        $confidenceCounts = @{}
        if ($edges) {
            foreach ($edge in $edges) {
                if (-not $edge) { continue }
                $confidence = if ($edge.Confidence) { $edge.Confidence } else { 'Unknown' }
                if (-not $confidenceCounts.ContainsKey($confidence)) { $confidenceCounts[$confidence] = 0 }
                $confidenceCounts[$confidence]++
            }
        }
        $metadata = [ordered]@{
            scanStarted      = $ScanStarted.ToString('o')
            scanFinished     = $ScanFinished.ToString('o')
            tool             = $script:ToolVersion
            credSetsUsed     = $CredSetsUsed
            confidenceCounts = $confidenceCounts
            nodeCount        = if ($Topology.Nodes) { $Topology.Nodes.Count } else { 0 }
            edgeCount        = if ($edges) { $edges.Count } else { 0 }
        }
        $json = $metadata | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8
        return $OutFile
    }
}

function Compare-NetworkScans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OldMetadata,
        [Parameter(Mandatory)][string]$NewMetadata,
        [Parameter(Mandatory)][string]$OldTopology,
        [Parameter(Mandatory)][string]$NewTopology
    )

    if (-not (Test-Path -LiteralPath $OldMetadata)) { throw "File '$OldMetadata' not found." }
    if (-not (Test-Path -LiteralPath $NewMetadata)) { throw "File '$NewMetadata' not found." }
    if (-not (Test-Path -LiteralPath $OldTopology)) { throw "File '$OldTopology' not found." }
    if (-not (Test-Path -LiteralPath $NewTopology)) { throw "File '$NewTopology' not found." }

    $oldTopo = (Get-Content -LiteralPath $OldTopology -Raw) | ConvertFrom-Json -ErrorAction Stop
    $newTopo = (Get-Content -LiteralPath $NewTopology -Raw) | ConvertFrom-Json -ErrorAction Stop

    $oldNodes = @{}
    foreach ($node in $oldTopo.Nodes) { if ($node.IP) { $oldNodes[$node.IP] = $node } }
    $newNodes = @{}
    foreach ($node in $newTopo.Nodes) { if ($node.IP) { $newNodes[$node.IP] = $node } }

    $addedNodes = @($newNodes.Keys | Where-Object { -not $oldNodes.ContainsKey($_) })
    $removedNodes = @($oldNodes.Keys | Where-Object { -not $newNodes.ContainsKey($_) })

    function Get-EdgeKey { param($edge) return (($edge.SourceIP, $edge.TargetIP) | Sort-Object) -join '|' }

    $oldEdges = @{}
    foreach ($edge in $oldTopo.Edges) { if ($edge.SourceIP -and $edge.TargetIP) { $oldEdges[(Get-EdgeKey $edge)] = $edge } }
    $newEdges = @{}
    foreach ($edge in $newTopo.Edges) { if ($edge.SourceIP -and $edge.TargetIP) { $newEdges[(Get-EdgeKey $edge)] = $edge } }

    $addedEdges = @($newEdges.Keys | Where-Object { -not $oldEdges.ContainsKey($_) })
    $removedEdges = @($oldEdges.Keys | Where-Object { -not $newEdges.ContainsKey($_) })

    $labelChanges = @()
    $confidenceChanges = @()
    foreach ($key in $newEdges.Keys) {
        if ($oldEdges.ContainsKey($key)) {
            $oldEdge = $oldEdges[$key]
            $newEdge = $newEdges[$key]
            if (($oldEdge.Label ?? '') -ne ($newEdge.Label ?? '')) {
                $labelChanges += "${key}: '$($oldEdge.Label)' -> '$($newEdge.Label)'"
            }
            if (($oldEdge.Confidence ?? '') -ne ($newEdge.Confidence ?? '')) {
                $confidenceChanges += "${key}: '$($oldEdge.Confidence)' -> '$($newEdge.Confidence)'"
            }
        }
    }

    $markdown = @()
    $markdown += '# Network Scan Comparison'
    $markdown += ''
    $markdown += '## Nodes'
    $markdown += "- Added: $([string]::Join(', ', $addedNodes))"
    $markdown += "- Removed: $([string]::Join(', ', $removedNodes))"
    $markdown += ''
    $markdown += '## Edges'
    $markdown += "- Added: $([string]::Join(', ', $addedEdges))"
    $markdown += "- Removed: $([string]::Join(', ', $removedEdges))"
    $markdown += ''
    if ($labelChanges) {
        $markdown += '### Label Changes'
        foreach ($change in $labelChanges) { $markdown += "- $change" }
        $markdown += ''
    }
    if ($confidenceChanges) {
        $markdown += '### Confidence Changes'
        foreach ($change in $confidenceChanges) { $markdown += "- $change" }
        $markdown += ''
    }

    return ($markdown -join [Environment]::NewLine)
}

Export-ModuleMember -Function @(
    'Import-Inventory',
    'Test-DeviceReachability',
    'Invoke-SnmpWalk',
    'Get-SnmpNeighbors',
    'Merge-Edges',
    'Export-DrawIO',
    'Export-Metadata',
    'Compare-NetworkScans'
)
