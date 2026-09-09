function Invoke-PortScan {
    <#
    .SYNOPSIS
        Scans common network service ports on target hosts
    .DESCRIPTION
        Performs TCP port scanning and banner grabbing on common service ports.
        No credentials required. Useful for identifying services and device types.
    .PARAMETER IPAddress
        Target IP address or array of IP addresses
    .PARAMETER Ports
        Array of TCP ports to scan, 1-65535 (default: common TCP service ports).
        Note: SNMP (161) is UDP and is deliberately NOT in the defaults - a TCP probe of
        161 does not detect SNMP. Use Invoke-SnmpWalk for SNMP.
    .PARAMETER TimeoutMs
        Per-port connection timeout in milliseconds, 1-60000 (default: 1000)
    .PARAMETER GrabBanners
        Attempt to grab service banners from open ports
    .EXAMPLE
        Invoke-PortScan -IPAddress '192.168.1.1'

        Scan common ports on a single host
    .EXAMPLE
        Invoke-PortScan -IPAddress '192.168.1.1' -Ports @(80,443,22) -GrabBanners

        Scan specific ports and grab banners
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$IPAddress,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int[]]$Ports = @(21, 22, 23, 25, 80, 443, 445, 3389, 8080, 8443),

        [Parameter()]
        [ValidateRange(1, 60000)]
        [int]$TimeoutMs = 1000,

        [Parameter()]
        [switch]$GrabBanners
    )

    process {
        foreach ($ip in $IPAddress) {
            Write-Verbose "Scanning $ip..."

            $openPorts = @()

            foreach ($port in $Ports) {
                $tcpClient = [System.Net.Sockets.TcpClient]::new()
                $connectResult = $null

                try {
                    $connectResult = $tcpClient.BeginConnect($ip, $port, $null, $null)
                    $connectedInTime = $connectResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

                    if (-not $connectedInTime) {
                        continue
                    }

                    try {
                        $tcpClient.EndConnect($connectResult)
                    }
                    catch {
                        continue
                    }

                    if (-not $tcpClient.Connected) {
                        continue
                    }

                    $banner = $null

                    if ($GrabBanners) {
                        try {
                            $stream = $tcpClient.GetStream()
                            if ($stream.CanRead) {
                                $stream.ReadTimeout = 500
                                $buffer = New-Object byte[] 1024
                                $bytesRead = $stream.Read($buffer, 0, 1024)
                                if ($bytesRead -gt 0) {
                                    $banner = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesRead).Trim()
                                }
                            }
                        }
                        catch {
                            # Banner grab failed, that's OK
                        }
                    }

                    $openPorts += [pscustomobject]@{
                        Port    = $port
                        State   = 'Open'
                        Service = Get-ServiceName -Port $port
                        Banner  = $banner
                    }

                    Write-Verbose "  Port $port - Open"
                }
                catch {
                    # Port closed or filtered
                }
                finally {
                    if ($connectResult -and $connectResult.AsyncWaitHandle) {
                        $connectResult.AsyncWaitHandle.Close()
                    }
                    $tcpClient.Dispose()
                }
            }

            [pscustomobject]@{
                IPAddress = $ip
                OpenPorts = $openPorts
                ScanTime  = Get-Date
            }
        }
    }
}
