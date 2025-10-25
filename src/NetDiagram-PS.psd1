@{
    RootModule        = 'NetDiagram-PS.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '12345678-90ab-cdef-1234-567890abcdef'
    Author            = 'NetDiagram Team'
    CompanyName       = 'NetDiagram'
    Copyright         = '(c) NetDiagram. All rights reserved.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Import-Inventory',
        'Test-DeviceReachability',
        'Invoke-SnmpWalk',
        'Get-SnmpNeighbors',
        'Merge-Edges',
        'Export-DrawIO',
        'Export-Metadata',
        'Compare-NetworkScans'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('network', 'diagram', 'drawio', 'snmp')
            ProjectUri = 'https://example.com/NetDiagram-PS'
        }
    }
}
