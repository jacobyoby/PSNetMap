function Import-Inventory {
    <#
    .SYNOPSIS
        Imports network inventory from JSON file
    .DESCRIPTION
        Reads a JSON inventory file and creates a Topology object with Nodes and Subnets.
        The stable inventory contract is IPv4-only. Device addresses and subnet CIDRs
        are validated and normalized; subnet host bits are cleared. Duplicate device
        addresses are rejected. Unknown or omitted roles are retained and placed in the
        Access layer.
    .PARAMETER Path
        Path to the inventory JSON file
    .EXAMPLE
        $topo = Import-Inventory -Path '.\examples\inventory-template.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Path
    )

    process {
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            throw "Inventory file not found: $Path"
        }

        try {
            $inventory = Get-Content -Path $Path -Raw | ConvertFrom-Json
        }
        catch {
            throw "Failed to parse inventory JSON: $_"
        }

        if (-not $inventory.PSObject.Properties['knownDevices']) {
            throw "Invalid inventory: missing 'knownDevices' property"
        }
        if ($null -eq $inventory.knownDevices -or
            $inventory.knownDevices -is [string] -or
            $inventory.knownDevices -isnot [System.Collections.IEnumerable]) {
            throw "Invalid inventory: 'knownDevices' must be an array"
        }
        if ($inventory.PSObject.Properties['subnets'] -and
            ($null -eq $inventory.subnets -or $inventory.subnets -is [string] -or
             $inventory.subnets -isnot [System.Collections.IEnumerable])) {
            throw "Invalid inventory: 'subnets' must be an array when present"
        }

        $topology = New-EmptyTopology
        $deviceAddresses = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        # Process known devices
        $deviceIndex = 0
        $nodes = foreach ($device in @($inventory.knownDevices)) {
            if ($null -eq $device -or -not $device.PSObject.Properties['ip'] -or
                $device.ip -isnot [string] -or [string]::IsNullOrWhiteSpace($device.ip)) {
                throw "Invalid inventory knownDevices[$deviceIndex]: missing string 'ip'"
            }

            $normalizedIP = ConvertTo-NormalizedIPv4Address -Value $device.ip -Context "knownDevices[$deviceIndex].ip"
            if (-not $deviceAddresses.Add($normalizedIP)) {
                throw "Invalid inventory knownDevices[$deviceIndex].ip '$normalizedIP': duplicate device address"
            }

            $role = if ($device.PSObject.Properties['role']) { $device.role } else { 'unknown' }
            $layer = Get-LayerFromRole -Role $role

            [pscustomobject]@{
                IP        = $normalizedIP
                Hostname  = if ($device.PSObject.Properties['hostname'] -and -not [string]::IsNullOrWhiteSpace($device.hostname)) { $device.hostname } else { $normalizedIP }
                Role      = $role
                Vendor    = if ($device.PSObject.Properties['vendor']) { $device.vendor } else { 'Unknown' }
                OS        = if ($device.PSObject.Properties['os']) { $device.os } else { 'Unknown' }
                Layer     = $layer
                Reachable = $null
            }
            $deviceIndex++
        }

        $topology.Nodes = @($nodes)

        # Process subnets if present
        if ($inventory.PSObject.Properties['subnets'] -and $inventory.subnets) {
            $subnetIndex = 0
            $subnetCidrs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            $subnets = foreach ($subnet in @($inventory.subnets)) {
                if ($null -eq $subnet -or -not $subnet.PSObject.Properties['cidr'] -or
                    $subnet.cidr -isnot [string] -or [string]::IsNullOrWhiteSpace($subnet.cidr)) {
                    throw "Invalid inventory subnets[$subnetIndex]: missing string 'cidr'"
                }

                $normalizedCidr = ConvertTo-NormalizedIPv4Cidr -Value $subnet.cidr -Context "subnets[$subnetIndex].cidr"
                if (-not $subnetCidrs.Add($normalizedCidr)) {
                    throw "Invalid inventory subnets[$subnetIndex].cidr '$normalizedCidr': duplicate subnet"
                }

                [pscustomobject]@{
                    CIDR  = $normalizedCidr
                    Label = if ($subnet.PSObject.Properties['label'] -and -not [string]::IsNullOrWhiteSpace($subnet.label)) { $subnet.label } else { $normalizedCidr }
                    VLAN  = if ($subnet.PSObject.Properties['vlan']) { $subnet.vlan } else { $null }
                }
                $subnetIndex++
            }
            $topology.Subnets = @($subnets)
        }

        Write-Verbose "Imported $($topology.Nodes.Count) nodes and $($topology.Subnets.Count) subnets"

        return $topology
    }
}
