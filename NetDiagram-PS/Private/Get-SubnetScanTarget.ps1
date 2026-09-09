function Get-SubnetScanTarget {
    <#
    .SYNOPSIS
        Returns the list of host addresses (as UInt32 values) to scan within a subnet,
        derived from the real network/broadcast bounds and bounded by scan depth.
    #>
    param(
        [Parameter(Mandatory)][uint32]$NetworkValue,
        [Parameter(Mandatory)][uint32]$BroadcastValue,
        [ValidateSet('Quick', 'Medium', 'Full')][string]$ScanDepth = 'Quick',
        [int]$MaxScanHosts = 1022
    )

    [int64]$firstHost   = [int64]$NetworkValue + 1
    [int64]$lastHost    = [int64]$BroadcastValue - 1
    [int64]$usableCount = if ($lastHost -ge $firstHost) { $lastHost - $firstHost + 1 } else { 0 }

    $hostValues = [System.Collections.Generic.List[uint32]]::new()
    if ($usableCount -le 0) {
    }
    elseif ($ScanDepth -eq 'Quick') {
        $sampleCount = [int][Math]::Min(8, $usableCount)
        for ($s = 0; $s -lt $sampleCount; $s++) {
            $idx = [int][Math]::Floor($s * $usableCount / $sampleCount)
            $null = $hostValues.Add([uint32]($firstHost + $idx))
        }
    }
    elseif ($ScanDepth -eq 'Medium') {
        $take = [int][Math]::Min(50, $usableCount)
        for ($i = 0; $i -lt $take; $i++) { $null = $hostValues.Add([uint32]($firstHost + $i)) }
    }
    else {
        $take = [int][Math]::Min($usableCount, $MaxScanHosts)
        for ($i = 0; $i -lt $take; $i++) { $null = $hostValues.Add([uint32]($firstHost + $i)) }
    }
    return @($hostValues)
}
