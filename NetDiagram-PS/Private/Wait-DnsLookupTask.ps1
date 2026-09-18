function Wait-DnsLookupTask {
    param(
        [Parameter(Mandatory)][System.Threading.Tasks.Task]$LookupTask,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    try {
        if ($LookupTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            if ($LookupTask.IsFaulted) { throw $LookupTask.Exception.InnerException ?? $LookupTask.Exception }
            if ($LookupTask.IsCanceled) { throw [System.OperationCanceledException]::new("DNS lookup canceled for $IPAddress") }
            $result = $LookupTask.Result
            return [pscustomobject]@{
                IPAddress = $IPAddress
                Hostname  = $result.HostName
                Aliases   = $result.Aliases
                Success   = $true
            }
        }

        Write-Verbose "DNS lookup for $IPAddress timed out after $TimeoutSeconds second(s) — abandoning task (observing fault to prevent UnobservedTaskException)"
        if ($LookupTask.IsFaulted) { $null = $LookupTask.Exception }
    }
    catch {
        Write-Verbose "DNS lookup for $IPAddress failed: $($_.Exception.Message)"
        if ($LookupTask.IsFaulted) { $null = $LookupTask.Exception }
    }

    return [pscustomobject]@{
        IPAddress = $IPAddress
        Hostname  = $null
        Aliases   = @()
        Success   = $false
    }
}
