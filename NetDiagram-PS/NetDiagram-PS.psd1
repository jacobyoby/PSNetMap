@{
    RootModule = 'NetDiagram-PS.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'a8f7e9c4-6d2b-4a1c-9e3f-7b8c9d0e1f2a'
    Author = 'NetDiagram-PS Team'
    CompanyName = 'Unknown'
    Copyright = '(c) 2025. All rights reserved.'
    Description = 'Network discovery and diagram generation module that discovers network nodes/links and emits valid .drawio files with SNMP support.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        # Core inventory and topology
        'Import-Inventory'
        'Test-DeviceReachability'
        'Merge-Edges'

        # Level 1: Credential-Free Discovery
        'Get-LocalARPTable'
        'Resolve-IPHostname'
        'Get-MACVendor'
        'Invoke-PortScan'

        # Level 2 & 3: SNMP Discovery
        'Invoke-SnmpWalk'
        'Get-SnmpNeighbors'
        'Get-CommonSNMPStrings'

        # Export and Analysis
        'Export-DrawIO'
        'Export-Metadata'
        'Compare-NetworkScans'
    )

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @('Network', 'Discovery', 'Diagram', 'SNMP', 'DrawIO', 'Topology')
            LicenseUri = ''
            ProjectUri = ''
            ReleaseNotes = 'Initial MVP release with core discovery and diagram export functionality'
        }
    }
}
