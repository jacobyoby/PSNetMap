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

        $cidrParts = $entry.Name -split '/', 2
        $networkAddress = $null
        $prefixLength = 0
        $maxPrefix = -1
        if ($cidrParts.Count -eq 2 -and
            [int]::TryParse($cidrParts[1], [ref]$prefixLength) -and
            [System.Net.IPAddress]::TryParse($cidrParts[0], [ref]$networkAddress)) {
            if ($networkAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $maxPrefix = 32
            }
            elseif ($networkAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                $maxPrefix = 128
            }
        }

        if ($maxPrefix -lt 0 -or $prefixLength -lt 0 -or $prefixLength -gt $maxPrefix) {
            throw "Invalid SNMP credential-map CIDR '$($entry.Name)'. Expected an IPv4 or IPv6 CIDR or Default."
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
