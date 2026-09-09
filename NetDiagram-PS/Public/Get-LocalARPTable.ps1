function Get-LocalARPTable {
    <#
    .SYNOPSIS
        Retrieves the local ARP table to discover devices on the network
    .DESCRIPTION
        Parses the ARP cache to find MAC addresses and IP addresses of devices
        that have recently communicated with this host. No credentials required.
        Missing platform commands, command failures, and recognized-but-malformed
        neighbor lines produce terminating errors instead of an empty-cache result.
    .PARAMETER InterfaceAlias
        Optional network interface to filter results
    .EXAMPLE
        Get-LocalARPTable

        Returns all ARP entries from the local cache
    .EXAMPLE
        $devices = Get-LocalARPTable | Where-Object { $_.Type -eq 'dynamic' }

        Get only dynamically learned ARP entries
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$InterfaceAlias
    )

    $arpEntries = @()

    if ($IsWindows) {
            # Windows: Use Get-NetNeighbor (both IPv4 and IPv6)
            $neighbors = Get-NetNeighbor -ErrorAction Stop

            if ($InterfaceAlias) {
                $neighbors = $neighbors | Where-Object { $_.InterfaceAlias -eq $InterfaceAlias }
            }

            foreach ($entry in $neighbors) {
                $family = if ($entry.AddressFamily -eq 'IPv4') { 'IPv4' } else { 'IPv6' }
                $arpEntries += [pscustomobject]@{
                    IPAddress       = $entry.IPAddress
                    MACAddress      = $entry.LinkLayerAddress
                    State           = $entry.State
                    InterfaceAlias  = $entry.InterfaceAlias
                    InterfaceIndex  = $entry.InterfaceIndex
                    AddressFamily   = $family
                }
            }
    }
    elseif ($IsMacOS) {
            $null = Get-Command arp -CommandType Application -ErrorAction Stop
            $arpOutput = & arp -an 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "arp -an failed with exit code $LASTEXITCODE"
            }
            $arpEntries = @(ConvertFrom-ArpText -Lines $arpOutput -Format MacOS -InterfaceAlias $InterfaceAlias)
    }
    elseif ($IsLinux) {
            $ipCommand = Get-Command ip -CommandType Application -ErrorAction SilentlyContinue
            if ($ipCommand) {
                $neighborOutput = & $ipCommand.Source neigh show 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "ip neigh show failed with exit code $LASTEXITCODE"
                }
                $arpEntries = @(ConvertFrom-ArpText -Lines $neighborOutput -Format LinuxIp -InterfaceAlias $InterfaceAlias)
            }
            else {
                $arpCommand = Get-Command arp -CommandType Application -ErrorAction Stop
                $arpOutput = & $arpCommand.Source -an 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "arp -an failed with exit code $LASTEXITCODE"
                }
                $arpEntries = @(ConvertFrom-ArpText -Lines $arpOutput -Format LinuxArp -InterfaceAlias $InterfaceAlias)
            }
    }

    Write-Verbose "Found $($arpEntries.Count) ARP entries"
    return $arpEntries
}
