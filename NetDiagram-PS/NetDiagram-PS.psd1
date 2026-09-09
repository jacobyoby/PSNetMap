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
        'Get-CommonSNMPStrings'

        # Export and Analysis
        'Export-DrawIO'
        'Export-Mermaid'
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
            Tags = @('Network', 'Discovery', 'Diagram', 'SNMP', 'DrawIO', 'Topology', 'NetworkMapping', 'Cisco', 'LLDP', 'Visualization')
            LicenseUri = 'https://github.com/jacobyoby/PSNetMap/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jacobyoby/PSNetMap'
            ReleaseNotes = 'Version 1.3.0 - Code-review hardening. Get-SnmpNeighbors now queries untested nodes by default (Reachable = $null), fixing the import-then-discover workflow, with an -OnlyReachable opt-in switch. Invoke-SnmpWalk redacts the community string from verbose output, validates all parameters (SNMP version set, IP/FQDN, OID format, argument-injection guard), restricts binary resolution to Application, and documents process-list exposure. LLDP/CDP parsing hardened (value-only, octet-validated, Hex-STRING aware) and clearly documented as best-effort. Export-DrawIO de-duplicates node IPs and parents nodes into their matching subnet containers. Invoke-PortScan validates port/timeout ranges and drops TCP 161 (SNMP is UDP). Resolve-IPHostname now honors -TimeoutSeconds via async DNS. Example wizard uses real CIDR host enumeration (with a /22 scan cap) instead of assuming /24.'
        }
    }
}
