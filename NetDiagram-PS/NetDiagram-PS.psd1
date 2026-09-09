@{
    RootModule = 'NetDiagram-PS.psm1'
    ModuleVersion = '1.3.0'
    GUID = 'a8f7e9c4-6d2b-4a1c-9e3f-7b8c9d0e1f2a'
    Author = 'Jacob Yoby'
    CompanyName = 'NetDiagram-PS'
    Copyright = '(c) 2025 Jacob Yoby. All rights reserved.'
    Description = 'Automatically discover your network topology and generate professional draw.io diagrams with Cisco icons, SNMP discovery, and multi-level device detection.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')

    FunctionsToExport = @(
        # Core inventory and topology
        'Import-Inventory'
        'Import-NmapScan'
        'Test-DeviceReachability'
        'Invoke-NetworkDiscovery'
        'Merge-Edges'

        # Level 1: Credential-Free Discovery
        'Get-LocalARPTable'
        'Resolve-IPHostname'
        'Get-MACVendor'
        'Invoke-PortScan'

        # Level 2 & 3: SNMP Discovery
        'Invoke-SnmpWalk'
        'Get-SnmpNeighbors'
        'Get-SnmpBridgeNeighbors'
        'Get-CommonSNMPStrings'

        # Export and Analysis
        'Export-DrawIO'
        'Export-Mermaid'
        'Export-NetBox'
        'Export-Metadata'
        'Export-Topology'
        'Import-Topology'
        'Export-NodeInventoryCsv'
        'Compare-NetworkScans'
    )

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()

    PrivateData = @{
        PSData = @{
            Tags = @('Network', 'Discovery', 'Diagram', 'SNMP', 'DrawIO', 'Topology', 'NetworkMapping', 'Cisco', 'LLDP', 'IPv6', 'Visualization')
            LicenseUri = 'https://github.com/jacobyoby/PSNetMap/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jacobyoby/PSNetMap'
            ReleaseNotes = 'Unreleased (post-1.3.0). Module split into Public/Private loader files. IPv6 subnet matching, ARP discovery, DrawIO parenting, and dual-stack Import-Inventory. Import-NmapScan accepts IPv6-only nmap hosts (IPv4 preferred on dual-stack). Get-SnmpBridgeNeighbors walks BRIDGE-MIB forwarding tables and emits L2-FDB edges. New commands: Invoke-NetworkDiscovery, Import-NmapScan, Export-Mermaid, Export-NetBox, Export-NodeInventoryCsv, Export-Topology, Import-Topology. Test-DeviceReachability is tri-state ($true/$false/$null) with optional TCP fallback; the wizard uses the same helper. Packaged CI smoke checks FunctionsToExport and offline IPv6 DrawIO parenting.'
        }
    }
}
