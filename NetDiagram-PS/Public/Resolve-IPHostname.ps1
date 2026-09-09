function Resolve-IPHostname {
    <#
    .SYNOPSIS
        Performs reverse DNS lookup for IP addresses
    .DESCRIPTION
        Attempts to resolve hostnames from IP addresses using DNS PTR records.
        No credentials required.
    .PARAMETER IPAddress
        IP address or array of IP addresses to resolve
    .PARAMETER TimeoutSeconds
        DNS query timeout in seconds, 1-300 (default: 2). Enforced with an async lookup;
        addresses that do not resolve within the window are returned with Success = $false.
    .EXAMPLE
        Resolve-IPHostname -IPAddress '8.8.8.8'

        Resolves the hostname for Google DNS
    .EXAMPLE
        $ips = @('192.168.1.1', '192.168.1.10')
        $ips | Resolve-IPHostname

        Resolve multiple IP addresses
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$IPAddress,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 2
    )

    process {
        foreach ($ip in $IPAddress) {
            try {
                # Honor TimeoutSeconds: resolve asynchronously and wait at most
                # $TimeoutSeconds so a slow or unreachable resolver cannot hang the
                # pipeline. On timeout we return a failure object (the background task
                # is abandoned).
                $task = [System.Net.Dns]::GetHostEntryAsync($ip)
                Wait-DnsLookupTask -LookupTask $task -IPAddress $ip -TimeoutSeconds $TimeoutSeconds
            }
            catch {
                [pscustomobject]@{
                    IPAddress = $ip
                    Hostname  = $null
                    Aliases   = @()
                    Success   = $false
                }
            }
        }
    }
}
