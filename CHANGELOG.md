# Changelog

All notable changes to NetDiagram-PS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  - Comprehensive README with usage examples
  - Detailed function help with examples
  - Security best practices guide
  - Troubleshooting section

### Security Features
- Opt-in default credential testing with clear warnings
- SecretManagement integration for SNMP community strings
- Security warnings for potentially logged operations
- No credentials stored in plain text

### Technical Details
- PowerShell 7.0+ required
- Pester 5.0+ test suite with 100+ test cases
- Fully typed with strict mode enabled
- Defensive null safety throughout
- Parallel processing for performance
- Cross-platform compatible (Windows/Linux/macOS)

### Standards Compliance
- SNMP v2c/v3 support
- LLDP (IEEE 802.1AB) neighbor discovery
- Draw.io XML format compatibility
- JSON inventory format

### Testing
- 100+ Pester test cases
- Round-trip validation
- Defensive coding tests
- Mock-based unit tests for external dependencies

[1.0.0]: https://github.com/jacobyoby/PSNetMap/releases/tag/v1.0.0
