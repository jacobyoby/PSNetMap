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
