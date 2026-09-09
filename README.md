# NetDiagram-PS

NetDiagram-PS is a cross-platform PowerShell 7.4+ module that discovers your network topology and generates draw.io diagrams with Cisco network icons, subnet containers, and consistent styling.

**✓ Windows | ✓ macOS | ✓ Linux**

---

## Quick Start

To generate a diagram of the local network, run the example wizard from the repository root:

```powershell
# 1. Clone this repository
cd PSNetMap

# 2. Run the wizard from the examples folder
pwsh .\examples\New-NetworkDiagram.ps1

# 3. Open my-network.drawio in draw.io
```

The wizard performs the following actions:
- Discovers the network configuration
- Scans for active devices
- Tests connectivity
- Generates a draw.io diagram
- Saves an inventory file for later refinement

---

## Prerequisites

- **PowerShell 7.4+** (required, cross-platform — 7.4 is the current LTS and provides `Test-Connection -TimeoutSeconds`)
  - Windows: https://aka.ms/powershell
  - macOS: `brew install --cask powershell` or download from https://aka.ms/powershell
  - Linux: Follow instructions at https://aka.ms/powershell
  - Already installed? Check with: `$PSVersionTable.PSVersion`

- **net-snmp tools** (optional, for SNMP discovery)
  - Windows: `choco install net-snmp` (module calls `snmpwalk.exe`)
  - macOS: `brew install net-snmp` (provides `snmpwalk`)
  - Linux: `apt install snmp` or `yum install net-snmp-utils`

- **Pester 5.0+** (optional, only for running tests)
  - Install: `Install-Module -Name Pester -MinimumVersion 5.0.0`

---

## Installation

### From PowerShell Gallery

```powershell
Install-Module -Name NetDiagram-PS -Scope CurrentUser
Import-Module NetDiagram-PS
```

Available at [powershellgallery.com/packages/NetDiagram-PS](https://www.powershellgallery.com/packages/NetDiagram-PS).

### From source (clone)

```powershell
git clone https://github.com/jacobyoby/PSNetMap.git
Import-Module ./PSNetMap/NetDiagram-PS/NetDiagram-PS.psd1
```

See [PUBLISHING.md](PUBLISHING.md) for how the module is packaged and released to the Gallery.

---

## Usage

### Method 1: Quick Start Wizard (recommended)

```powershell
# Quick scan (common IPs only, ~10 seconds)
pwsh .\examples\New-NetworkDiagram.ps1

# Medium scan (first 50 IPs, ~30 seconds)
pwsh .\examples\New-NetworkDiagram.ps1 -ScanDepth Medium

# Full scan (all 254 IPs, ~2 minutes)
pwsh .\examples\New-NetworkDiagram.ps1 -ScanDepth Full -OutputPath .\office-network.drawio

# Choose an interface explicitly (useful with VPNs or multiple adapters)
pwsh .\examples\New-NetworkDiagram.ps1 -InterfaceName en0

# Limit each reverse DNS lookup to one second
pwsh .\examples\New-NetworkDiagram.ps1 -DnsTimeoutSeconds 1
```

### Method 2: Manual Workflow (manual inventory)

```powershell
# Import the module
Import-Module .\NetDiagram-PS\NetDiagram-PS.psd1

# Create your inventory file (copy from examples/inventory-template.json)
# Edit it with your devices

# Generate diagram
$topo = Import-Inventory -Path '.\my-inventory.json'
$topo | Export-DrawIO -OutFile '.\my-network.drawio'
```

### Method 3: With SNMP Discovery (advanced)

```powershell
Import-Module .\NetDiagram-PS\NetDiagram-PS.psd1

# 1. Store SNMP community string securely
Install-Module Microsoft.PowerShell.SecretManagement
Register-SecretVault -Name LocalVault -ModuleName Microsoft.PowerShell.SecretStore
Set-Secret -Name 'MySNMPCommunity' -Secret 'public'

# 2. Create credential map (copy examples/credmap.json and edit)

# 3. Discover topology with SNMP
$topo = Import-Inventory -Path '.\my-inventory.json'
$topo = $topo | Get-SnmpNeighbors -CredentialMapPath '.\my-credmap.json'
$topo | Export-DrawIO -OutFile '.\network.drawio'
```

> **Note:** `Get-SnmpNeighbors` queries every imported node by default (nodes whose
> reachability has not been tested are still queried), so the workflow above runs end to
> end without a separate reachability pass. Add `-OnlyReachable` (after piping through
> `Test-DeviceReachability`) to query only nodes that answered a ping.
>
> **LLDP/CDP parsing is best-effort (MVP):** it extracts management IPs from `snmpwalk`
> output and links them to known nodes, but does not fully decode the LLDP MIB. Treat the
> resulting SNMP edges as hints to verify, not authoritative topology. The community
> string is redacted from verbose logging, but is briefly visible in the local process
> list while `snmpwalk` runs — prefer SNMPv3 for anything sensitive.

---

## Inventory File Format

Create a JSON file with your network devices:

```json
{
  "knownDevices": [
    {
      "ip": "192.168.1.1",
      "hostname": "my-router",
      "role": "router",
      "vendor": "Cisco",
      "os": "IOS 15.x"
    },
    {
      "ip": "192.168.1.100",
      "hostname": "my-server",
      "role": "server",
      "vendor": "Dell",
      "os": "Ubuntu 22.04"
    }
  ],
  "subnets": [
    {
      "cidr": "192.168.1.0/24",
      "label": "Main Network",
      "vlan": 1
    }
  ]
}
```

Supported roles: `router`, `core-router`, `distribution`, `switch`, `server`, `workstation`

See `examples/inventory-template.json` for a complete template.

---

## Diagram Features

Generated diagrams include:

- Cisco network icons for routers, switches, and servers
- Subnet containers for visual grouping by network segment
- Color-coded status indicators: green (reachable), red (unreachable), and gray (unknown)
- Orthogonal connectors with rounded corners
- Confidence levels: solid lines (layer 2 SNMP verified) and dashed lines (layer 3 inferred)
- Labels that include device names, IP addresses, and connection details
- Hierarchical layouts that align devices by network layer

### Example Output

```
┌─────────────────────────────────────┐
│ Subnet: 192.168.1.0/24              │
│                                     │
│   ┌─────────┐         ┌─────────┐   │
│   │ Router  │─────────│ Switch  │   │
│   │ .1      │         │ .10     │   │
│   └─────────┘         └─────────┘   │
│        │                   │        │
│   ┌─────────┐         ┌─────────┐   │
│   │ Server  │         │   PC    │   │
│   │ .100    │         │ .200    │   │
│   └─────────┘         └─────────┘   │
└─────────────────────────────────────┘
```

---

## Repository Layout

```text
PSNetMap/
├── CHANGELOG.md            # Release history
├── LICENSE                 # MIT license
├── README.md               # Main documentation (this file)
├── STRUCTURE.md            # Additional notes on the folder layout
├── WHERE-TO-SAVE-FILES.txt # Tips for keeping inventories outside the repo
├── NetDiagram-PS/          # PowerShell module manifest & implementation
├── examples/               # Wizard script plus sample JSON templates
└── tests/                  # Pester test suite
```

The module ships without a separate `docs/` directory. All user-facing documentation currently lives in the files listed above.

---

## Available Commands

After importing the module, you have access to:

| Command | Purpose |
|---------|---------|
| `Import-Inventory` | Load network inventory from JSON |
| `Test-DeviceReachability` | Ping test all devices in parallel |
| `Get-LocalARPTable` | Read the local ARP cache |
| `Resolve-IPHostname` | Perform reverse DNS lookups |
| `Get-MACVendor` | Look up vendors for MAC addresses |
| `Invoke-PortScan` | Check TCP ports with optional banner grabbing |
| `Get-SnmpNeighbors` | Discover connections via SNMP |
| `Get-CommonSNMPStrings` | Suggest likely SNMP community strings |
| `Merge-Edges` | Combine and deduplicate connections |
| `Export-DrawIO` | Generate diagram file |
| `Export-Metadata` | Save scan statistics |
| `Compare-NetworkScans` | Diff two topology snapshots |
| `Invoke-SnmpWalk` | Direct SNMP queries |

Get help on any command:
```powershell
Get-Help Export-DrawIO -Full
```

---

## Common Workflows

### 1. Diagram Your Current Network

```powershell
# Run the wizard with default settings
pwsh .\examples\New-NetworkDiagram.ps1
```

### 2. Document Server Infrastructure

```powershell
# Create inventory file with your servers
$inventory = @{
    knownDevices = @(
        @{ ip='10.0.0.10'; hostname='db-server'; role='server'; vendor='Dell' }
        @{ ip='10.0.0.20'; hostname='web-server'; role='server'; vendor='HP' }
    )
    subnets = @(
        @{ cidr='10.0.0.0/24'; label='DMZ'; vlan=10 }
    )
}
$inventory | ConvertTo-Json | Out-File my-servers.json

# Generate diagram
Import-Module .\NetDiagram-PS\NetDiagram-PS.psd1
Import-Inventory my-servers.json | Export-DrawIO -OutFile servers.drawio
```

### 3. Compare Network Changes

```powershell
# Save baseline
$baseline = Import-Inventory old-network.json
$baseline | ConvertTo-Json | Out-File baseline-topo.json
$baseline | Export-Metadata -OutFile baseline-meta.json

# Save current state
$current = Import-Inventory current-network.json
$current | ConvertTo-Json | Out-File current-topo.json
$current | Export-Metadata -OutFile current-meta.json

# Compare
Compare-NetworkScans `
    -BaselineMetadata baseline-meta.json `
    -BaselineTopology baseline-topo.json `
    -CurrentMetadata current-meta.json `
    -CurrentTopology current-topo.json `
    -OutFile network-changes.md
```

---

## Examples

Check the `examples/` directory:

- `inventory-template.json` - Template for creating your inventory
- `credmap.json` - Template for SNMP credentials
- `New-NetworkDiagram.ps1` - Guided discovery wizard

---

## Troubleshooting

### "No devices found during scan"

**Cause:** Firewall blocking ICMP (ping)

**Solutions:**
- Windows: Run from an administrator/elevated PowerShell, temporarily disable Windows Firewall
- macOS: Run with `sudo pwsh ./examples/New-NetworkDiagram.ps1` to bypass firewall restrictions
- Linux: Run with `sudo pwsh ./examples/New-NetworkDiagram.ps1` or adjust iptables rules
- All platforms: Manually create inventory file with known IPs

### "draw.io won't open the file"

**Cause:** XML validation issue

**Solutions:**
- Open file in draw.io Desktop (not web)
- Check that all device IPs are valid
- Verify inventory JSON is valid: `Get-Content file.json | ConvertFrom-Json`

### "Module won't import"

**Cause:** PowerShell version too old

**Solutions:**
- Check version: `$PSVersionTable.PSVersion` (must be 7.4+)
- Upgrade: Download from https://aka.ms/powershell

### "SNMP returns nothing"

**Cause:** SNMP not configured or community string wrong

**Solutions:**
- Verify SNMP is enabled on devices
- Check community string is correct
- Ensure UDP port 161 is open
- Try manual test: `snmpwalk.exe -v2c -c public 192.168.1.1`

---

## Running Tests

On macOS or Linux, use the local runner so missing prerequisites are explicit:

```bash
./tests/run-tests.sh
```

Exit `0` means pass, `1` means tests failed, and `2` means `pwsh` or Pester is
unavailable and the suite did not run.

```powershell
# Install Pester if needed
Install-Module -Name Pester -MinimumVersion 5.0.0 -Force

# Run all tests
Invoke-Pester -Path .\tests\NetDiagram.Tests.ps1

# Run with detailed output
Invoke-Pester -Path .\tests\NetDiagram.Tests.ps1 -Output Detailed
```

---

## Security

- **Never commit** credential files with secrets
- Use `SecretManagement` module for SNMP community strings
- SNMP v2c sends community strings in clear text - use v3 for production
- The quick-start wizard does NOT store any credentials

---

## Additional Resources

- **draw.io Editor:** https://app.diagrams.net/
- **draw.io Desktop:** https://github.com/jgraph/drawio-desktop
- **PowerShell 7:** https://aka.ms/powershell
- **SecretManagement:** https://docs.microsoft.com/powershell/module/microsoft.powershell.secretmanagement

---

## Contributing

Contributions welcome! Please:
1. Ensure tests pass: `Invoke-Pester .\tests\NetDiagram.Tests.ps1`
2. Follow PowerShell best practices
3. Update documentation
4. Add tests for new features

---

## License

Released under the [MIT License](LICENSE). Copyright (c) 2025 Jacob Yoby.

---

## Quick Reference

```powershell
# Quickly generate a diagram of the current network:
pwsh .\examples\New-NetworkDiagram.ps1

# Open the generated diagram in https://app.diagrams.net/

# Modify the generated inventory if needed:
notepad my-network-inventory.json

# Export an updated diagram after editing the inventory:
Import-Module .\NetDiagram-PS\NetDiagram-PS.psd1
Import-Inventory my-network-inventory.json | Export-DrawIO -OutFile my-network.drawio
```

---

## Need Help?

1. Read the troubleshooting section above
2. Check command help: `Get-Help <CommandName> -Examples`
3. Review example files in `examples/`
4. Report issues with detailed error messages
