# Changelog

All notable changes to NetDiagram-PS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2026-07-30

### Fixed
- **SNMP discovery now works straight after `Import-Inventory`.** `Get-SnmpNeighbors`
  only queried nodes with `Reachable -eq $true`, but freshly imported inventory has
  `Reachable = $null`, so the documented import-then-discover workflow silently returned
  nothing. Untested nodes are now eligible by default; only nodes proven unreachable are
  skipped. New `-OnlyReachable` switch restores the strict behavior.
- **Community string no longer leaked to verbose output.** `Invoke-SnmpWalk` redacts
  `-c <community>` to `-c ****` in verbose logging. Process-list exposure (inherent to
  shelling out to net-snmp) is now documented as a known limitation.
- **`Export-DrawIO` duplicate-IP handling.** Duplicate device IPs overwrote the node-ID
  map and emitted multiple `mxCell` elements with the same id (invalid draw.io). Nodes
  are now de-duplicated by IP (first occurrence wins, with a warning).
- **Subnet containers now contain their nodes.** Nodes are parented into the matching
  subnet swimlane via `Test-IPInSubnet` instead of always being parented to `1`;
  unmatched nodes are laid out on the canvas below the containers.
- **Quick-start wizard subnet math.** The example script assumed a /24 (first three
  octets, `.1`-`.254`). It now derives host addresses from the interface's real CIDR
  prefix and caps scans of large subnets at a /22 (1022 hosts) with a warning. Also
  fixed a Windows-separator `Join-Path` in the module path.
- `Resolve-IPHostname` now honors `-TimeoutSeconds` (previously ignored) using an async
  DNS lookup with a bounded wait.

### Changed
- **Hardened LLDP/CDP parsing.** The neighbor parser inspects only the value portion of
  each line, validates IPv4 octets, decodes 4-octet `Hex-STRING` management addresses,
  and skips self-loops. It remains best-effort (does not fully decode the LLDP MIB) and
  is now clearly documented as such.
- **`Invoke-SnmpWalk` parameter validation.** SNMP `Version` restricted to v1/v2c/v3,
  `TargetIP` validated as IPv4/FQDN, `OID` validated as dotted-decimal, and an
  argument-injection guard rejects values beginning with `-`. Binary resolution is
  restricted to `-CommandType Application`.
- **`Invoke-PortScan` validation.** `-Ports` constrained to 1-65535, `-TimeoutMs` to
  1-60000 (previously unbounded, allowing indefinite hangs). TCP 161 removed from the
  defaults (SNMP is UDP; a TCP probe does not detect it).

## [1.2.0] - 2025-11-02

### Fixed
- **SNMP discovery on macOS/Linux** - `Invoke-SnmpWalk` hard-coded `snmpwalk.exe`, so
  SNMP neighbor discovery never worked on the platforms added in 1.1.0. It now resolves
  `snmpwalk` (Unix) or `snmpwalk.exe` (Windows) from PATH.
- Pester suite no longer asserts a stale hard-coded module version; the version test now
  reads the manifest, and the module path is built with `Join-Path` (no literal backslash),
  so tests run on macOS/Linux as well as Windows.

### Changed
- **Minimum PowerShell raised to 7.4.** The reachability functions use
  `Test-Connection -TimeoutSeconds`, which only exists in PowerShell 7.4+. The manifest
  previously advertised 7.0, on which those calls error.
- Added `CompatiblePSEditions = @('Core')` to the manifest.
- LICENSE copyright holder and README license section aligned with the manifest (MIT,
  Jacob Yoby).

### Added
- Additional Pester tests for `Get-MACVendor`, `Get-CommonSNMPStrings`,
  `Resolve-IPHostname`, `Invoke-SnmpWalk` (missing-binary path), and the private
  `Test-IPInSubnet` helper.
- `PUBLISHING.md` documenting the PowerShell Gallery release process.
- GitHub Actions workflow running the Pester suite on Windows, macOS, and Linux.

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
