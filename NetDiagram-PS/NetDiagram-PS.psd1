@{
    RootModule = 'NetDiagram-PS.psm1'
    ModuleVersion = '1.4.0'
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
            Tags = @('Network', 'Discovery', 'Diagram', 'SNMP', 'DrawIO', 'Topology', 'NetworkMapping', 'Cisco', 'LLDP', 'IPv6', 'NetBox', 'Visualization')
            LicenseUri = 'https://github.com/jacobyoby/PSNetMap/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jacobyoby/PSNetMap'
            ReleaseNotes = '1.4.0. Module split into Public/Private loader files. Dual-stack inventory, IPv6 subnet matching/ARP/DrawIO parenting, bounded IPv6 discovery (ND plus /120+ CIDR; no /64 sweep), and Import-NmapScan IPv6 hosts (IPv4 preferred on dual-stack). Get-SnmpBridgeNeighbors emits L2-FDB edges (solid teal). Invoke-SnmpWalk and SNMP credential maps accept IPv6. Export-NetBox writes IPv6 to primary_ip6 and leaves unknown reachability empty. New commands: Invoke-NetworkDiscovery, Import-NmapScan, Export-Mermaid, Export-NetBox, Export-NodeInventoryCsv, Export-Topology, Import-Topology. Reachability is tri-state with optional TCP fallback. Packaged CI smoke imports FunctionsToExport and runs offline dual-stack DrawIO via Import-Inventory.'
        }
    }
}
