function Get-SnmpBridgeNeighbors {
    <#
    .SYNOPSIS
        Discovers layer-2 neighbors via BRIDGE-MIB forwarding tables
    .DESCRIPTION
        Walks the BRIDGE-MIB dot1dTpFdbTable on each eligible node to learn which MAC
        addresses the switch has forwarded. For each learned MAC (status = 3), resolves
        the MAC to an IP address via the local ARP table (Get-LocalARPTable) and emits
        an edge when the IP matches a node already in the topology.

        This fills in layer-2 edges that CDP and LLDP do not report (e.g. unmanaged
        switches, devices that do not speak CDP/LLDP).

        CONFIDENCE: Edges are emitted with Confidence = 'L2-FDB', which ranks between
        L2-SNMP (CDP/LLDP) and L3-Inferred in Merge-Edges.

        NODE ELIGIBILITY: Same as Get-SnmpNeighbors — every node except those explicitly
        marked unreachable (Reachable -eq $false) is queried by default.

        ARP RESOLUTION: The local ARP table is queried once at the start. MACs that
        cannot be resolved to an IP produce a Verbose message, not a warning.

        SECURITY: Reuses Invoke-SnmpWalk for all SNMP queries (redaction + injection guards).
    .PARAMETER Topology
        Topology object with nodes
    .PARAMETER CredentialMapPath
        Path to credential map JSON file
    .PARAMETER OnlyReachable
        Only query nodes proven reachable (Reachable -eq $true).
    .PARAMETER TryPublic
        If no credentials found for a node, try the common "public" community string.
    .EXAMPLE
        $topo = $topo | Get-SnmpBridgeNeighbors -CredentialMapPath '.\credmap.json' -TryPublic
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$CredentialMapPath,

        [Parameter()]
        [switch]$OnlyReachable,

        [Parameter()]
        [switch]$TryPublic
    )

    process {
        if ($null -eq $Topology -or $null -eq $Topology.Nodes) {
            throw "Invalid topology object"
        }

        if (-not (Test-Path -Path $CredentialMapPath -PathType Leaf)) {
            throw "Credential map file not found: $CredentialMapPath"
        }

        try {
            $credMap = Get-Content -Path $CredentialMapPath -Raw | ConvertFrom-Json
        }
        catch {
            throw "Failed to parse credential map JSON: $_"
        }

        # Build a MAC-to-IP lookup from the local ARP table (queried once).
        $arpLookup = @{}
        try {
            $arpEntries = @(Get-LocalARPTable)
            foreach ($entry in $arpEntries) {
                if (-not [string]::IsNullOrWhiteSpace($entry.MACAddress) -and
                    -not [string]::IsNullOrWhiteSpace($entry.IPAddress)) {
                    # Normalize MAC to colon-delimited uppercase for consistent matching
                    $normalizedMAC = ($entry.MACAddress -replace '[-.]', ':').ToUpperInvariant()
                    $arpLookup[$normalizedMAC] = $entry.IPAddress
                }
            }
            Write-Verbose "ARP table loaded: $($arpLookup.Count) MAC-to-IP mappings"
        }
        catch {
            Write-Warning "Failed to load local ARP table: $_. Bridge neighbor discovery will not resolve MACs to IPs."
        }

        # Decide which nodes to query (same logic as Get-SnmpNeighbors).
        if ($OnlyReachable) {
            $nodesToQuery = @($Topology.Nodes | Where-Object { $_.Reachable -eq $true })
            $eligibilityDesc = 'reachable'
        }
        else {
            $nodesToQuery = @($Topology.Nodes | Where-Object { $_.Reachable -ne $false })
            $eligibilityDesc = 'eligible (reachable or untested)'
        }

        if ($nodesToQuery.Count -eq 0) {
            Write-Warning "No $eligibilityDesc nodes to query via SNMP bridge walk"
            return $Topology
        }

        Write-Verbose "Querying BRIDGE-MIB for $($nodesToQuery.Count) $eligibilityDesc node(s)"

        $discoveredEdges = [System.Collections.ArrayList]::new()

        # BRIDGE-MIB OIDs
        $oidFdbAddress = '1.3.6.1.2.1.17.4.3.1.1'   # dot1dTpFdbAddress (MAC)
        $oidFdbPort    = '1.3.6.1.2.1.17.4.3.1.2'   # dot1dTpFdbPort (port number)
        $oidFdbStatus  = '1.3.6.1.2.1.17.4.3.1.3'   # dot1dTpFdbStatus (1=other,2=invalid,3=learned,4=self,5=mgmt)

        foreach ($node in $nodesToQuery) {
            # Resolve SNMP community for this node
            $community = $null
            $communitySecret = $null
            $source = 'CredentialMap'

            if ($credMap.PSObject.Properties['snmp'] -and $credMap.snmp) {
                $credentialMatch = Resolve-SnmpCredentialConfig -SnmpMap $credMap.snmp -IPAddress $node.IP
                if ($credentialMatch) {
                    $source = "CredentialMap:$($credentialMatch.CIDR)"
                    if ($credentialMatch.Config.PSObject.Properties['communitySecret']) {
                        $communitySecret = $credentialMatch.Config.communitySecret
                    }
                    else {
                        Write-Warning "SNMP credential entry '$($credentialMatch.CIDR)' has no communitySecret; skipping configured credential for $($node.IP)"
                    }
                }
            }

            # Try to get secret from SecretManagement
            if ($communitySecret) {
                try {
                    $secretModule = Get-Module -Name Microsoft.PowerShell.SecretManagement -ListAvailable -ErrorAction SilentlyContinue
                    if ($secretModule) {
                        Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction SilentlyContinue
                        $communitySecretInfo = Get-Secret -Name $communitySecret -AsPlainText -ErrorAction SilentlyContinue
                        if ($communitySecretInfo) {
                            $community = $communitySecretInfo
                        }
                    }
                }
                catch {
                    Write-Warning "Failed to retrieve secret '$communitySecret' for $($node.IP): $_"
                }
            }

            # Try "public" if no credentials found and -TryPublic is enabled
            if ([string]::IsNullOrWhiteSpace($community) -and $TryPublic) {
                $community = 'public'
                $source = 'DefaultPublic'
                Write-Verbose "[TryPublic] Attempting default 'public' community for $($node.IP)"
            }

            if ([string]::IsNullOrWhiteSpace($community)) {
                Write-Warning "No SNMP community found for $($node.IP), skipping bridge walk"
                continue
            }

            Write-Verbose "  Walking BRIDGE-MIB on $($node.IP) with community from $source"

            # Walk the three columns of dot1dTpFdbTable
            $addressLines = @()
            $portLines = @()
            $statusLines = @()
            try {
                $addressLines = @(Invoke-SnmpWalk -TargetIP $node.IP -Community $community -OID $oidFdbAddress -ErrorAction Stop)
                $portLines    = @(Invoke-SnmpWalk -TargetIP $node.IP -Community $community -OID $oidFdbPort -ErrorAction Stop)
                $statusLines  = @(Invoke-SnmpWalk -TargetIP $node.IP -Community $community -OID $oidFdbStatus -ErrorAction Stop)
            }
            catch {
                Write-Warning "BRIDGE-MIB walk failed for $($node.IP): $($_.Exception.Message)"
                continue
            }

            if (@($addressLines).Count -eq 0) {
                Write-Verbose "No BRIDGE-MIB data returned from $($node.IP)"
                continue
            }

            # Parse status walk into a hashtable: MAC-index → status value
            # Status lines look like:
            #   .1.3.6.1.2.1.17.4.3.1.3.0.26.183.12.34.56 = INTEGER: 3
            $statusMap = @{}
            foreach ($line in $statusLines) {
                if ($line -match '\.1\.3\.6\.1\.2\.1\.17\.4\.3\.1\.3\.(.+?)\s*=\s*INTEGER:\s*(\d+)') {
                    $macIndex = $matches[1]
                    $statusVal = [int]$matches[2]
                    $statusMap[$macIndex] = $statusVal
                }
            }

            # Parse port walk into a hashtable: MAC-index → port number
            # Port lines look like:
            #   .1.3.6.1.2.1.17.4.3.1.2.0.26.183.12.34.56 = INTEGER: 3
            $portMap = @{}
            foreach ($line in $portLines) {
                if ($line -match '\.1\.3\.6\.1\.2\.1\.17\.4\.3\.1\.2\.(.+?)\s*=\s*INTEGER:\s*(\d+)') {
                    $macIndex = $matches[1]
                    $portVal = [int]$matches[2]
                    $portMap[$macIndex] = $portVal
                }
            }

            # Parse address walk: extract MAC from Hex-STRING value, keyed by MAC-index
            # Address lines look like:
            #   .1.3.6.1.2.1.17.4.3.1.1.0.26.183.12.34.56 = Hex-STRING: 00 1A B7 0C 22 38
            $addressMap = @{}
            foreach ($line in $addressLines) {
                if ($line -match '\.1\.3\.6\.1\.2\.1\.17\.4\.3\.1\.1\.(.+?)\s*=\s*Hex-STRING:\s*(.+)') {
                    $macIndex = $matches[1]
                    $hexValue = $matches[2].Trim()
                    # Parse hex octets into colon-delimited uppercase MAC
                    $octets = $hexValue -split '[\s:]+' | Where-Object { $_ -ne '' }
                    if ($octets.Count -ge 6) {
                        $mac = ($octets[0..5] | ForEach-Object { $_.ToUpperInvariant().PadLeft(2, '0') }) -join ':'
                        $addressMap[$macIndex] = $mac
                    }
                }
            }

            Write-Verbose "  $($node.IP): parsed $($addressMap.Count) FDB addresses, $($statusMap.Count) statuses, $($portMap.Count) ports"

            # For each learned MAC (status=3), resolve via ARP and emit edge
            foreach ($macIndex in $addressMap.Keys) {
                # Filter: only keep status=3 (learned)
                $status = if ($statusMap.ContainsKey($macIndex)) { $statusMap[$macIndex] } else { $null }
                if ($status -ne 3) {
                    continue
                }

                $mac = $addressMap[$macIndex]
                $port = if ($portMap.ContainsKey($macIndex)) { $portMap[$macIndex] } else { $null }

                # Look up MAC in local ARP table
                $resolvedIP = if ($arpLookup.ContainsKey($mac)) { $arpLookup[$mac] } else { $null }

                if ([string]::IsNullOrWhiteSpace($resolvedIP)) {
                    Write-Verbose "  MAC $mac (port $port) on $($node.IP): no ARP match, skipping"
                    continue
                }

                # Skip self-loops
                if ($resolvedIP -eq $node.IP) { continue }

                # Only accept addresses that map to a node already in the topology
                $targetNode = $Topology.Nodes | Where-Object { $_.IP -eq $resolvedIP }
                if (-not $targetNode) { continue }

                $label = if ($null -ne $port) { "port-$port" } else { 'FDB' }

                $edge = [pscustomobject]@{
                    SourceIP   = $node.IP
                    TargetIP   = $resolvedIP
                    Label      = $label
                    Source     = 'SNMP-FDB'
                    Confidence = 'L2-FDB'
                }

                $null = $discoveredEdges.Add($edge)
            }
        }

        Write-Verbose "Discovered $($discoveredEdges.Count) bridge-FDB edges"

        # Merge new edges with existing ones
        $allEdges = @($Topology.Edges) + @($discoveredEdges)
        $Topology.Edges = Merge-Edges -Edges $allEdges

        return $Topology
    }
}
