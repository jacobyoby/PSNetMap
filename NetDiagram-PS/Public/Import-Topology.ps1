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
