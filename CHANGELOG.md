# Changelog

All notable changes to NetDiagram-PS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2025-10-31

### Added
- **Cross-Platform Support** - NetDiagram-PS now works natively on Windows, macOS, and Linux
  - macOS: Uses `ifconfig`, `route`, `scutil`, and `arp` commands for network discovery
  - Linux: Uses `ip` and `arp` commands for network discovery
  - All platforms: Automatic OS detection and appropriate command selection
  - macOS/Linux: Hostname detection via `hostname` command
  - macOS: OS version detection via `sw_vers`
  - Linux: Distribution detection via `/etc/os-release`

### Changed
- `New-NetworkDiagram.ps1` now detects the operating system and uses platform-appropriate commands
- `Get-LocalARPTable` function updated with cross-platform ARP cache parsing
- Network interface discovery now supports both Windows PowerShell cmdlets and Unix commands
- DNS server discovery adapted for macOS (`scutil --dns`) and Linux (`/etc/resolv.conf`)
- README updated with cross-platform installation instructions and troubleshooting
- Prerequisites section now includes macOS and Linux installation methods

### Fixed
- Script no longer crashes on macOS/Linux due to Windows-only cmdlets
- Gateway and DNS discovery now works correctly on Unix-based systems

## [1.0.1] - 2025-11-01

### Changed
- Clarified quick-start instructions to call the wizard from the `examples/` folder.
- Documented the actual repository layout and removed references to a non-existent `docs/` directory.
- Noted the `snmpwalk.exe` requirement for SNMP discovery and the need for shims on non-Windows platforms.
- Updated metadata files to reflect version `1.0.1`.

### Fixed
- Corrected STRUCTURE.md to match the current filesystem and documentation set.

## [1.0.0] - 2025-10-25

### Added
- **Core Network Discovery Functions**
  - `Import-Inventory` - Load network topology from JSON inventory files
  - `Test-DeviceReachability` - Parallel ICMP ping testing with configurable concurrency
  - `Export-DrawIO` - Generate professional network diagrams in draw.io XML format
  - `Export-Metadata` - Save scan statistics and confidence metrics
  - `Compare-NetworkScans` - Diff two network snapshots with markdown reports

- **SNMP Discovery (Level 2)**
  - `Invoke-SnmpWalk` - Direct SNMP queries via net-snmp tools
  - `Get-SnmpNeighbors` - Automated LLDP/CDP neighbor discovery
  - Support for SecretManagement integration for secure credential storage
  - Credential mapping with CIDR-based configuration

- **Credential-Free Discovery (Level 1)**
  - `Get-LocalARPTable` - Parse local ARP cache for device discovery
  - `Resolve-IPHostname` - Reverse DNS lookups for hostname resolution
  - `Get-MACVendor` - OUI-based vendor identification
  - `Invoke-PortScan` - TCP port scanning with optional banner grabbing

- **Diagram Features**
  - Professional Cisco network icons for all device types
  - Color-coded reachability status (Green/Red/Gray)
  - Hierarchical layout by network layer (Core/Distribution/Access/Servers)
  - Subnet containers with VLAN support
  - Confidence-based edge styling (L2-SNMP solid, L3-Inferred dashed)
  - Orthogonal routing with rounded corners
  - Rich tooltips with device metadata
  - Shadow effects and professional styling

- **Quick Start Tools**
  - `New-NetworkDiagram.ps1` - Interactive wizard for instant network discovery
  - Configurable scan depths (Quick/Medium/Full)
  - Automatic inventory file generation
  - No configuration required - works out of the box

- **Documentation**
  - README with quick start instructions and usage examples
  - STRUCTURE.md and WHERE-TO-SAVE-FILES.txt with project layout guidance
  - Example JSON templates for inventories and credential maps

### Security Features
- Opt-in default credential testing with clear warnings
- SecretManagement integration for SNMP community strings
- Security warnings for potentially logged operations
- No credentials stored in plain text

### Technical Details
- PowerShell 7.0+ required (validated on Windows environments)
- Pester 5.0+ test suite covering core cmdlets
- Fully typed with strict mode enabled
- Defensive null safety throughout
- Parallel processing for performance

### Standards Compliance
- SNMP v2c support via net-snmp tools
- LLDP (IEEE 802.1AB) neighbor discovery
- Draw.io XML format compatibility
- JSON inventory format

### Testing
- Pester tests for import, export, comparison, and discovery cmdlets
- Round-trip validation of generated Draw.io files
- Mock-based unit tests for external dependencies

[1.0.0]: https://github.com/jacobyoby/PSNetMap/releases/tag/v1.0.0
