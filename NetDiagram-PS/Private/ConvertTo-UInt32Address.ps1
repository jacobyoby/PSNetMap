function ConvertTo-UInt32Address {
    param([Parameter(Mandatory)][string]$IPAddress)
    $bytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [System.BitConverter]::ToUInt32($bytes, 0)
}
