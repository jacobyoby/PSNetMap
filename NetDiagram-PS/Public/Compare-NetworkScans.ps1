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
