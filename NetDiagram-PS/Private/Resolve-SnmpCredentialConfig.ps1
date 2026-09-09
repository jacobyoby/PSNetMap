function Resolve-SnmpCredentialConfig {
    param(
        [Parameter(Mandatory)][psobject]$SnmpMap,
        [Parameter(Mandatory)][string]$IPAddress
    )

    $defaultConfig = $null
    $cidrMatches = @()

    foreach ($entry in $SnmpMap.PSObject.Properties) {
        if ($entry.Name -eq 'Default') {
            $defaultConfig = $entry.Value
            continue
        }

        if ($entry.Name -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})$') {
            throw "Invalid SNMP credential-map CIDR '$($entry.Name)'. Expected an IPv4 CIDR or Default."
        }

        $prefixLength = [int]$matches[2]
        $networkAddress = $null
        if ($prefixLength -gt 32 -or
            -not [System.Net.IPAddress]::TryParse($matches[1], [ref]$networkAddress) -or
            $networkAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Invalid SNMP credential-map CIDR '$($entry.Name)'. Expected an IPv4 CIDR or Default."
        }

        if (Test-IPInSubnet -IP $IPAddress -CIDR $entry.Name) {
            $cidrMatches += [pscustomobject]@{
                CIDR = $entry.Name
                PrefixLength = $prefixLength
                Config = $entry.Value
            }
        }
    }

    $bestMatch = $cidrMatches | Sort-Object PrefixLength -Descending | Select-Object -First 1
    if ($bestMatch) {
        return $bestMatch
    }
    if ($null -ne $defaultConfig) {
        return [pscustomobject]@{
            CIDR = 'Default'
            PrefixLength = -1
            Config = $defaultConfig
        }
    }

    return $null
}
