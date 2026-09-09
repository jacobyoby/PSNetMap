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
