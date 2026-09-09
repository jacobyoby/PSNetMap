function Test-DeviceReachability {
    <#
    .SYNOPSIS
        Tests network reachability for all nodes in a topology
    .DESCRIPTION
        Uses Test-Connection with parallel processing to quickly test device reachability.
        Updates the Reachable property on each node.
    .PARAMETER Topology
        Topology object from Import-Inventory
    .PARAMETER MaxParallel
        Maximum number of parallel ping tests (default: 32)
    .PARAMETER TimeoutSeconds
        Timeout for each ping test (default: 1)
    .PARAMETER TcpFallbackPort
        If ICMP fails, try TCP connect to this port to promote an ICMP-silent host to reachable
    .EXAMPLE
        $topo = Import-Inventory -Path '.\my-inventory.json' | Test-DeviceReachability -MaxParallel 64
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter()]
        [int]$MaxParallel = 32,

        [Parameter()]
        [int]$TimeoutSeconds = 1,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int]$TcpFallbackPort,

        [Parameter(DontShow)]
        [scriptblock]$ProbeScript
    )

    process {
        if ($null -eq $Topology -or $null -eq $Topology.Nodes) {
            throw "Invalid topology object"
        }

        if ($Topology.Nodes.Count -eq 0) {
            Write-Warning "No nodes to test"
            return $Topology
        }

        Write-Verbose "Testing reachability for $($Topology.Nodes.Count) nodes with $MaxParallel parallel threads"

        # Create a synchronized hashtable for results (tri-state: $true/$false/$null)
        $results = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
        $tcpPort = $TcpFallbackPort
        $probe = $ProbeScript

        if ($probe) {
            # Test seam: ProbeScript returns $true/$false/$null directly per IP
            foreach ($node in $Topology.Nodes) {
                try {
                    $r = & $probe $node.IP
                    $null = $results.TryAdd($node.IP, $r)
                }
                catch { $null = $results.TryAdd($node.IP, $null) }
            }
        }
        else {
            # Test reachability in parallel
            $Topology.Nodes | ForEach-Object -Parallel {
                $node = $_
                $timeout = $using:TimeoutSeconds
                $resultsDict = $using:results
                $fallbackPort = $using:tcpPort

                try {
                    $pingResult = Test-Connection -ComputerName $node.IP -Count 1 -TimeoutSeconds $timeout -ErrorAction Stop -Quiet
                    if ($pingResult -eq $true) {
                        $null = $resultsDict.TryAdd($node.IP, $true)
                        continue
                    }
                    if ($fallbackPort) {
                        try {
                            $tcp = [System.Net.Sockets.TcpClient]::new()
                            $task = $tcp.ConnectAsync($node.IP, $fallbackPort)
                            if ($task.Wait([TimeSpan]::FromSeconds($timeout))) {
                                $ok = $task.IsCompletedSuccessfully -and $tcp.Connected
                                $tcp.Dispose()
                                if ($ok) { $null = $resultsDict.TryAdd($node.IP, $true); continue }
                            } else { $tcp.Dispose() }
                        } catch {}
                    }
                    $null = $resultsDict.TryAdd($node.IP, $false)
                }
                catch {
                    $null = $resultsDict.TryAdd($node.IP, $null)
                }
            } -ThrottleLimit $MaxParallel
        }

        # Update nodes with results
        $indeterminateCount = 0
        foreach ($node in $Topology.Nodes) {
            $val = $null
            $found = $results.TryGetValue($node.IP, [ref]$val)
            if ($found) {
                if ($null -eq $val) { $indeterminateCount++ }
                $node.Reachable = $val
            }
            else {
                $node.Reachable = $null
                $indeterminateCount++
            }
        }
        if ($indeterminateCount -gt 0) {
            Write-Warning "Reachability indeterminate for $indeterminateCount node(s): local probe could not be sent (no route or insufficient privilege) — not marked as unreachable."
        }

        $reachableCount = @($Topology.Nodes | Where-Object { $_.Reachable -eq $true }).Count
        Write-Verbose "Reachability test complete: $reachableCount/$($Topology.Nodes.Count) nodes reachable"

        return $Topology
    }
}
