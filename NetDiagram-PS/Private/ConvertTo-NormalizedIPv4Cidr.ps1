function ConvertTo-NormalizedIPv4Cidr {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Value -notmatch '^(.+)\/(\d{1,2})$') {
        throw "Invalid inventory $Context '$Value': expected IPv4 CIDR notation."
    }

    $address = ConvertTo-NormalizedIPv4Address -Value $matches[1] -Context $Context
    $prefixLength = [int]$matches[2]
    if ($prefixLength -gt 32) {
        throw "Invalid inventory $Context '$Value': IPv4 prefix must be between 0 and 32."
    }

    $bytes = ([System.Net.IPAddress]::Parse($address)).GetAddressBytes()
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
