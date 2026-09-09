# Project Structure

This document describes the layout of the NetDiagram-PS module after the per-responsibility split (issue #31).

## Top level

```
PSNetMap/
├── NetDiagram-PS/          # The PowerShell module
├── examples/               # Example inventories, wizard scripts
├── tests/                  # Pester tests
├── AGENTS.md               # Contributor / AI-agent guidance
├── CHANGELOG.md            # Release history
├── PUBLISHING.md           # Publish-to-Gallery checklist
├── README.md               # User-facing documentation
└── STRUCTURE.md            # This file
```

## Module directory (`NetDiagram-PS/`)

The module is split into one function per file. `NetDiagram-PS.psm1` is now a
**loader** that dot-sources `Private/*.ps1` then `Public/*.ps1` and re-exports
the public function basenames.

```
NetDiagram-PS/
├── NetDiagram-PS.psd1      # Module manifest (FunctionsToExport lists Public/)
├── NetDiagram-PS.psm1      # Loader — dot-sources Private + Public
├── Private/                # Internal helpers, not exported
│   ├── ConvertFrom-ArpText.ps1
│   ├── ConvertFrom-UInt32Address.ps1
│   ├── ConvertTo-NormalizedCidr.ps1
│   ├── ConvertTo-NormalizedIPAddress.ps1
│   ├── ConvertTo-NormalizedIPv4Address.ps1
│   ├── ConvertTo-NormalizedIPv4Cidr.ps1
│   ├── ConvertTo-UInt32Address.ps1
│   ├── Get-IPv6CidrScanTarget.ps1
│   ├── Get-LayerFromRole.ps1
│   ├── Get-PrefixMask.ps1
│   ├── Get-ServiceName.ps1
│   ├── Get-SubnetScanTarget.ps1
│   ├── New-EmptyTopology.ps1
│   ├── Resolve-SnmpCredentialConfig.ps1
│   ├── Test-IPInSubnet.ps1
│   └── Wait-DnsLookupTask.ps1
└── Public/                 # Exported commands (one file per function)
    ├── Compare-NetworkScans.ps1
    ├── Export-DrawIO.ps1
    ├── Export-Mermaid.ps1
    ├── Export-Metadata.ps1
    ├── Export-NetBox.ps1
    ├── Export-NodeInventoryCsv.ps1
    ├── Export-Topology.ps1
    ├── Get-CommonSNMPStrings.ps1
    ├── Get-LocalARPTable.ps1
    ├── Get-MACVendor.ps1
    ├── Get-SnmpBridgeNeighbors.ps1
    ├── Get-SnmpNeighbors.ps1
    ├── Import-Inventory.ps1
    ├── Import-NmapScan.ps1
    ├── Import-Topology.ps1
    ├── Invoke-NetworkDiscovery.ps1
    ├── Invoke-PortScan.ps1
    ├── Invoke-SnmpWalk.ps1
    ├── Merge-Edges.ps1
    ├── Resolve-IPHostname.ps1
    └── Test-DeviceReachability.ps1
```

### Conventions

- **One function per file.** The file's basename must match the function name exactly (e.g. `Get-LayerFromRole.ps1` defines `function Get-LayerFromRole`).
- **Private vs Public.** Helpers that are only called from inside the module live in `Private/`. Anything users should be able to call directly lives in `Public/`.
- **Manifest is authoritative.** `FunctionsToExport` in `NetDiagram-PS.psd1` must list exactly the basenames found in `Public/`. When adding a new public command, create the file in `Public/` and add its name to the manifest.
- **Loader order.** `NetDiagram-PS.psm1` dot-sources `Private/` before `Public/` so public functions can reference private helpers at load time.
- **No logic in the loader.** The loader only sets strict mode, dot-sources files, and calls `Export-ModuleMember`. New module-level state belongs in a dedicated file under `Private/`.
