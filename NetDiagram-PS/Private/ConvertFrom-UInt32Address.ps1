function ConvertFrom-UInt32Address {
    param([Parameter(Mandatory)][uint32]$Value)
    $bytes = [System.BitConverter]::GetBytes($Value)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}
