function New-EmptyTopology {
    <#
    .SYNOPSIS
        Creates an empty topology object
    #>
    [pscustomobject]@{
        Nodes   = @()
        Edges   = @()
        Subnets = @()
    }
}
