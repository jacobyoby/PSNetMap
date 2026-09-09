function Get-PrefixMask {
    param([Parameter(Mandatory)][int]$PrefixLength)
    if ($PrefixLength -le 0) { return [uint32]0 }
    if ($PrefixLength -ge 32) { return [uint32]4294967295 }
    return [uint32]((([uint64]4294967295) -shl (32 - $PrefixLength)) -band [uint64]4294967295)
}
