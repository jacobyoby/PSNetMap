function ConvertTo-NormalizedIPv4Address {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Context
    )

    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Invalid inventory $Context '$Value': expected an IPv4 address. IPv6 is not supported."
    }
    return $address.ToString()
}
