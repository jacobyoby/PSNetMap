function ConvertTo-NormalizedCidr {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Value -notmatch '^(.+)\/(\d{1,3})$') {
        throw "Invalid inventory $Context '$Value': expected IPv4 or IPv6 CIDR notation."
    }

    $address = ConvertTo-NormalizedIPAddress -Value $matches[1] -Context $Context
    $prefixLength = [int]$matches[2]
    $parsed = [System.Net.IPAddress]::Parse($address)
    $maxPrefix = if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        32
    }
    else {
        128
    }
    if ($prefixLength -gt $maxPrefix) {
        $familyName = if ($maxPrefix -eq 32) { 'IPv4' } else { 'IPv6' }
        throw "Invalid inventory $Context '$Value': $familyName prefix must be between 0 and $maxPrefix."
    }

    $bytes = $parsed.GetAddressBytes()
    $bitsRemaining = $prefixLength
    for ($index = 0; $index -lt $bytes.Count; $index++) {
        $mask = if ($bitsRemaining -ge 8) {
            255
        }
        elseif ($bitsRemaining -le 0) {
            0
        }
        else {
            256 - [Math]::Pow(2, 8 - $bitsRemaining)
        }
        $bytes[$index] = [byte]($bytes[$index] -band [int]$mask)
        $bitsRemaining -= 8
    }

    return "$([System.Net.IPAddress]::new($bytes))/$prefixLength"
}
