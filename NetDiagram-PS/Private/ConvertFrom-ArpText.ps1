function ConvertFrom-ArpText {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][ValidateSet('MacOS', 'LinuxIp', 'LinuxArp')][string]$Format,
        [string]$InterfaceAlias
    )

    foreach ($line in $Lines) {
        $entry = $null
        if ($Format -eq 'MacOS') {
            if ($line -notmatch '\s+at\s+') { continue }
            if ($line -match '\s+at\s+\(incomplete\)') { continue }
            # Try IPv4 first, then IPv6
            if ($line -match '\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]{17})\s+on\s+(\S+)') {
                $entry = [pscustomobject]@{
                    IPAddress = $matches[1]; MACAddress = $matches[2].ToUpperInvariant()
                    State = 'Reachable'; InterfaceAlias = $matches[3]; InterfaceIndex = $null
                    AddressFamily = 'IPv4'
                }
            }
            elseif ($line -match '\(([0-9a-fA-F:]+)\)\s+at\s+([0-9a-fA-F:]{17})\s+on\s+(\S+)') {
                $entry = [pscustomobject]@{
                    IPAddress = $matches[1]; MACAddress = $matches[2].ToUpperInvariant()
                    State = 'Reachable'; InterfaceAlias = $matches[3]; InterfaceIndex = $null
                    AddressFamily = 'IPv6'
                }
            }
            else {
                throw "Unable to parse macOS ARP entry: $line"
            }
        }
        elseif ($Format -eq 'LinuxIp') {
            if ($line -notmatch '\s+lladdr\s+') { continue }
            # Try IPv4 first, then IPv6
            if ($line -match '^(\d+\.\d+\.\d+\.\d+)\s+dev\s+(\S+)\s+lladdr\s+([0-9a-fA-F:]{17})\s+(\S+)') {
                $entry = [pscustomobject]@{
                    IPAddress = $matches[1]; MACAddress = $matches[3].ToUpperInvariant()
                    State = $matches[4]; InterfaceAlias = $matches[2]; InterfaceIndex = $null
                    AddressFamily = 'IPv4'
                }
            }
            elseif ($line -match '^([0-9a-fA-F:]+)\s+dev\s+(\S+)\s+lladdr\s+([0-9a-fA-F:]{17})\s+(\S+)') {
                $entry = [pscustomobject]@{
                    IPAddress = $matches[1]; MACAddress = $matches[3].ToUpperInvariant()
                    State = $matches[4]; InterfaceAlias = $matches[2]; InterfaceIndex = $null
                    AddressFamily = 'IPv6'
                }
            }
            else {
                throw "Unable to parse Linux ip-neigh entry: $line"
            }
        }
        else {
            if ($line -notmatch '\s+at\s+') { continue }
            if ($line -notmatch '\((\d+\.\d+\.\d+\.\d+)\)\s+at\s+([0-9a-fA-F:]{17})') {
                throw "Unable to parse Linux arp entry: $line"
            }
            $entry = [pscustomobject]@{
                IPAddress = $matches[1]; MACAddress = $matches[2].ToUpperInvariant()
                State = 'Reachable'; InterfaceAlias = $null; InterfaceIndex = $null
                AddressFamily = 'IPv4'
            }
        }

        if (-not $InterfaceAlias -or $entry.InterfaceAlias -eq $InterfaceAlias) {
            $entry
        }
    }
}
