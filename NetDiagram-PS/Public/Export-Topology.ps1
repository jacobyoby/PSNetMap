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
