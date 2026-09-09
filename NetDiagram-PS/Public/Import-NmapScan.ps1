function Import-NmapScan {
    <#
    .SYNOPSIS
        Imports topology from nmap XML output
    .DESCRIPTION
        Parses nmap -oX XML and returns a Topology with Nodes derived from hosts
        whose status is up. Reads IPv4 and IPv6 address elements (addrtype
        ipv4/ipv6). When both families are present on one host, IPv4 is preferred
        so the host keeps a single node identity; IPv6 is used only when no IPv4
        address is present. Addresses are validated with [System.Net.IPAddress]::Parse
        and stored in canonical form; malformed addresses are skipped. Maps
        hostname/vendor/OS/ports. Role stays unknown unless nmap data clearly
        indicates otherwise.
    .PARAMETER Path
        Path to nmap XML file
    .EXAMPLE
        Import-NmapScan -Path scan.xml | Export-DrawIO -OutFile net.drawio
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "nmap file not found: '$Path'"
    }
    try {
        [xml]$xml = Get-Content -LiteralPath $Path -Raw
    }
    catch {
        throw "Failed to parse nmap XML file '$Path': $_"
    }
    if (-not $xml.PSObject.Properties['nmaprun'] -or $null -eq $xml.nmaprun) {
        throw "Invalid nmap XML file '$Path': missing required element 'nmaprun'."
    }

    $topo = New-EmptyTopology
    $nodes = @()
    foreach ($hostNode in @($xml.nmaprun.host)) {
        $state = $hostNode.status.state
        if ($state -and $state -ne 'up') { continue }

        $ipv4 = $null
        $ipv6 = $null
        foreach ($addr in @($hostNode.address)) {
            if (-not $addr.addr) { continue }
            if ($addr.addrtype -eq 'ipv4' -and -not $ipv4) { $ipv4 = $addr.addr }
            elseif ($addr.addrtype -eq 'ipv6' -and -not $ipv6) { $ipv6 = $addr.addr }
        }

        # One node per nmap host: prefer IPv4 when both families are present.
        $chosen = if ($ipv4) { $ipv4 } else { $ipv6 }
        if (-not $chosen) { continue }

        try {
            $parsed = [System.Net.IPAddress]::Parse($chosen)
        }
        catch {
            continue
        }
        $ip = $parsed.ToString()

        $hostname = $ip
        if ($hostNode.PSObject.Properties['hostnames'] -and $hostNode.hostnames -and $hostNode.hostnames.PSObject.Properties['hostname'] -and $hostNode.hostnames.hostname) {
            $hn = @($hostNode.hostnames.hostname)[0]
            if ($hn.PSObject.Properties['name'] -and $hn.name) { $hostname = $hn.name }
        }

        $vendor = 'Unknown'
        foreach ($addr in @($hostNode.address)) {
            if ($addr.addrtype -eq 'mac' -and $addr.PSObject.Properties['vendor'] -and $addr.vendor) { $vendor = $addr.vendor; break }
        }

        $os = 'Unknown'
        if ($hostNode.PSObject.Properties['os'] -and $hostNode.os -and $hostNode.os.PSObject.Properties['osmatch'] -and $hostNode.os.osmatch -and @($hostNode.os.osmatch)[0].PSObject.Properties['name'] -and @($hostNode.os.osmatch)[0].name) {
            $os = @($hostNode.os.osmatch)[0].name
        }

        $ports = @()
        if ($hostNode.PSObject.Properties['ports'] -and $hostNode.ports -and $hostNode.ports.PSObject.Properties['port'] -and $hostNode.ports.port) {
            foreach ($p in @($hostNode.ports.port)) {
                if ($p.PSObject.Properties['state'] -and $p.state -and $p.state.PSObject.Properties['state'] -and $p.state.state -eq 'open' -and $p.PSObject.Properties['portid'] -and $p.portid) { $ports += $p.portid }
            }
        }

        $mac = ''
        foreach ($addr in @($hostNode.address)) {
            if ($addr.addrtype -eq 'mac' -and $addr.addr) { $mac = $addr.addr; break }
        }

        $nodes += [pscustomobject]@{
            IP         = $ip
            Hostname   = $hostname
            Role       = 'unknown'
            Vendor     = $vendor
            OS         = $os
            Layer      = Get-LayerFromRole -Role 'unknown'
            Reachable  = $null
            MACAddress = $mac
            OpenPorts  = $ports
        }
    }

    $topo.Nodes = @($nodes)
    return $topo
}
