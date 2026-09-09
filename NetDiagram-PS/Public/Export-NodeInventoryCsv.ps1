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
