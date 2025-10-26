@{
    RootModule = 'NetDiagram-PS.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a8f7e9c4-6d2b-4a1c-9e3f-7b8c9d0e1f2a'
    Author = 'Jacob Yoby'
    CompanyName = 'NetDiagram-PS'
    Copyright = '(c) 2025 Jacob Yoby. All rights reserved.'
    Description = 'Automatically discover your network topology and generate professional draw.io diagrams with Cisco icons, SNMP discovery, and multi-level device detection.'
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
            Tags = @('Network', 'Discovery', 'Diagram', 'SNMP', 'DrawIO', 'Topology', 'NetworkMapping', 'Cisco', 'LLDP', 'Visualization')
            LicenseUri = 'https://github.com/jacobyoby/PSNetMap/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jacobyoby/PSNetMap'
            IconUri = ''
            ReleaseNotes = 'Version 1.0.0 - First stable release with full network discovery, SNMP support, and professional diagram generation'
        }
    }
}
