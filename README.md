# NetDiagram-PS

NetDiagram-PS is a PowerShell 7+ module that builds simple network topology diagrams and metadata from an inventory. The module can discover reachability, merge link information, and export Draw.io diagrams without external APIs.

## Prerequisites

- PowerShell 7.0 or newer
- Optional: `snmpwalk.exe` from the Net-SNMP toolkit (if you want LLDP/CDP discovery)
- Optional: [Microsoft.PowerShell.SecretManagement](https://learn.microsoft.com/powershell/module/microsoft.powershell.secretmanagement/) for credential resolution

## Installation

```powershell
Import-Module (Join-Path $PSScriptRoot 'src' 'NetDiagram-PS.psd1')
```

## Quickstart

```powershell
$topology = Import-Inventory ./examples/baseline.json |
            Test-DeviceReachability -MaxParallel 64
$topology.Edges = @(
    [pscustomobject]@{ SourceIP='10.66.1.1'; TargetIP='10.66.10.11'; Label='Gi0/1'; Source='Manual' },
    [pscustomobject]@{ SourceIP='10.66.1.1'; TargetIP='10.66.1.2'; Label='VPC'; Source='Manual' }
)
$topology | Export-DrawIO -OutFile ./network.drawio
```

### With SNMP

```powershell
$topology = Import-Inventory ./examples/baseline.json |
            Test-DeviceReachability
$topology = $topology | Get-SnmpNeighbors -CredentialMap ./examples/credmap.json
$topology | Export-Metadata -OutFile ./scanmeta.json -CredSetsUsed @('Cred-CoreSwitch','Snmp-Comm-Internal')
```

## Tests

```powershell
Invoke-Pester -Path ./tests/NetDiagram.Tests.ps1
```

## Troubleshooting

- **Draw.io cannot open the file**: Ensure `<mxCell id="0"/>` and `<mxCell id="1" parent="0"/>` exist and that all other cells reference `parent="1"`.
- **SNMP discovery returns nothing**: Verify the SNMP community secret, device ACLs, SNMP version, and that `snmpwalk.exe` is on the PATH.
- **Ping or SNMP time out**: Adjust throttle limits or verify device reachability. The module uses conservative timeouts and skips unreachable nodes instead of failing.
