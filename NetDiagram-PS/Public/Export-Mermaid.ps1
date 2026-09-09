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
