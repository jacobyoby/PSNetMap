function Wait-DnsLookupTask {
    param(
        [Parameter(Mandatory)][System.Threading.Tasks.Task]$LookupTask,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    try {
        if ($LookupTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            $result = $LookupTask.Result
            return [pscustomobject]@{
                IPAddress = $IPAddress
                Hostname  = $result.HostName
                Aliases   = $result.Aliases
                Success   = $true
            }
        }

        Write-Verbose "DNS lookup for $IPAddress timed out after $TimeoutSeconds second(s)"
    }
    catch {
        Write-Verbose "DNS lookup for $IPAddress failed: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        IPAddress = $IPAddress
        Hostname  = $null
        Aliases   = @()
        Success   = $false
    }
}
