function Export-NetBox {
    <#
    .SYNOPSIS
        Exports topology to NetBox bulk-import CSV
    .DESCRIPTION
        Writes devices CSV for NetBox with columns name,role,manufacturer,device_type,site,status,primary_ip4.
        Role mapping: router/core-router->router, switch/distribution->switch, server->server, workstation->workstation.
        Vendor Unknown -> empty manufacturer. Reachable true->active else offline.
    .PARAMETER Topology
        Topology object with Nodes
    .PARAMETER OutFile
        Output path for CSV
    .PARAMETER Site
        NetBox site name
    .PARAMETER Force
        Overwrite existing file
    .EXAMPLE
        $topo | Export-NetBox -OutFile devices.csv -Site "HQ"
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$OutFile,

        [Parameter(Mandatory)]
        [string]$Site,

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
        if (-not $PSCmdlet.ShouldProcess($OutFile, 'Export-NetBox')) {
            return
        }

        $roleMap = @{
            'core-router'  = 'router'
            'router'       = 'router'
            'switch'       = 'switch'
            'distribution' = 'switch'
            'server'       = 'server'
            'workstation'  = 'workstation'
            'unknown'      = 'unknown'
        }

        $rows = foreach ($node in @($Topology.Nodes)) {
            $roleKey = if ($node.Role) { [string]$node.Role } else { 'unknown' }
            $mappedRole = if ($roleMap.ContainsKey($roleKey)) { $roleMap[$roleKey] } else { 'unknown' }
            $manufacturer = if ($node.PSObject.Properties['Vendor'] -and $node.Vendor -and $node.Vendor -ne 'Unknown') { [string]$node.Vendor } else { '' }
            $deviceType = if ($node.PSObject.Properties['OS'] -and $node.OS -and $node.OS -ne 'Unknown') { [string]$node.OS } else { 'unknown' }
            $status = if ($node.Reachable -eq $true) { 'active' } else { 'offline' }
            [pscustomobject]@{
                name         = [string]$node.Hostname
                role         = $mappedRole
                manufacturer = $manufacturer
                device_type  = $deviceType
                site         = $Site
                status       = $status
                primary_ip4  = [string]$node.IP
            }
        }

        if ($null -eq $rows -or @($rows).Count -eq 0) {
            'name,role,manufacturer,device_type,site,status,primary_ip4' | Out-File -FilePath $OutFile -Encoding utf8 -Force
        }
        else {
            $rows | Export-Csv -LiteralPath $OutFile -NoTypeInformation -Encoding utf8 -Force
        }
        Write-Verbose "Exported NetBox CSV to $OutFile"
    }
}
