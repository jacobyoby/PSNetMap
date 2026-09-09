function ConvertTo-NormalizedIPAddress {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address)) {
        throw "Invalid inventory $Context '$Value': expected an IPv4 or IPv6 address."
    }
    return $address.ToString()
}
