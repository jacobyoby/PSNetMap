function Get-LayerFromRole {
    <#
    .SYNOPSIS
        Maps device role to network layer for diagram placement
    #>
    param([string]$Role)

    switch ($Role) {
        'core-router' { return 'Core' }
        'router'      { return 'Core' }
        'distribution'{ return 'Dist' }
        'switch'      { return 'Access' }
        'server'      { return 'Servers' }
        default       { return 'Access' }
    }
}
