function Get-SnmpNeighbors {
    <#
    .SYNOPSIS
        Discovers neighbors via SNMP LLDP/CDP (best-effort MVP)
    .DESCRIPTION
        Queries nodes for LLDP neighbor information via SNMP.
        Uses credential map to resolve community strings from SecretManagement.
        Adds discovered edges with provisional L2-SNMP-Heuristic confidence. The parser
        does not assign verified L2-SNMP confidence because it does not fully correlate
        structured LLDP/CDP table rows.

        CREDENTIAL MATCHING: The most specific matching IPv4 CIDR wins regardless of
        JSON property order. Default is used only when no CIDR matches. If the selected
        entry has no available community secret, the node is skipped unless -TryPublic
        was explicitly supplied.

        NODE ELIGIBILITY: By default every node is queried EXCEPT nodes that have been
        explicitly marked unreachable (Reachable -eq $false). Nodes with unknown
        reachability (Reachable -eq $null, e.g. straight after Import-Inventory) ARE
        queried, so the documented "import inventory then discover via SNMP" workflow
        works without first running Test-DeviceReachability. Pass -OnlyReachable to
        restrict querying to nodes proven reachable (Reachable -eq $true).

        PARSING IS BEST-EFFORT (MVP): the neighbor parser scans snmpwalk output for the
        first IPv4-looking token on each line and only creates an edge when that address
        already exists as a node in the topology. It does NOT fully decode the LLDP/CDP
        MIB rows (chassis-id / management-address / port-id sub-OIDs are not joined). It
        can miss neighbors and, on unusual output, misattribute a link. Treat the SNMP
        edges as hints to verify, not authoritative topology.
    .PARAMETER Topology
        Topology object with nodes
    .PARAMETER CredentialMapPath
        Path to credential map JSON file
    .PARAMETER OID
        SNMP OID to walk (default: LLDP remote table)
    .PARAMETER OnlyReachable
        Only query nodes proven reachable (Reachable -eq $true). Off by default so that
        freshly imported inventory (Reachable = $null) is still queried.
    .PARAMETER TryPublic
        If no credentials found for a node, try the common "public" community string.
        WARNING: This may be logged by security systems. Only use on networks you own.
    .EXAMPLE
        $topo = $topo | Get-SnmpNeighbors -CredentialMapPath '.\examples\credmap.json'
    .EXAMPLE
        $topo = $topo | Get-SnmpNeighbors -CredentialMapPath '.\credmap.json' -TryPublic

        Tries user credentials first, falls back to "public" if none found (with warning)
    .EXAMPLE
        $topo = $topo | Test-DeviceReachability | Get-SnmpNeighbors -CredentialMapPath '.\credmap.json' -OnlyReachable

        Ping-tests first, then queries only the nodes that answered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [pscustomobject]$Topology,

        [Parameter(Mandatory)]
        [string]$CredentialMapPath,

        [Parameter()]
        [string]$OID = '1.0.8802.1.1.2.1.4',

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

        # Show warning if -TryPublic is enabled
        if ($TryPublic) {
            Write-Warning @"
SECURITY WARNING: -TryPublic flag enabled
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
This will attempt to use the default SNMP community string "public"
on devices where no credentials are configured.

⚠️  This may be logged by network security systems
⚠️  Only use on networks you own or have authorization to scan
⚠️  Consider using SNMPv3 with authentication for production

All SNMP attempts will be logged to verbose output.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
"@
        }

        # Decide which nodes to query. Default: everything that is not explicitly
        # unreachable (so freshly imported inventory with Reachable = $null is eligible).
        # -OnlyReachable narrows to nodes proven reachable (Reachable -eq $true).
        if ($OnlyReachable) {
            $nodesToQuery = @($Topology.Nodes | Where-Object { $_.Reachable -eq $true })
            $eligibilityDesc = 'reachable'
        }
        else {
            $nodesToQuery = @($Topology.Nodes | Where-Object { $_.Reachable -ne $false })
            $eligibilityDesc = 'eligible (reachable or untested)'
        }

        if ($nodesToQuery.Count -eq 0) {
            Write-Warning "No $eligibilityDesc nodes to query via SNMP"
            return $Topology
        }

        Write-Verbose "Querying SNMP neighbors for $($nodesToQuery.Count) $eligibilityDesc node(s)"

        $discoveredEdges = [System.Collections.ArrayList]::new()
        $publicAttempts = 0
        $snmpOutcomes = @{}
        $snmpCounts = @{ queried = $nodesToQuery.Count; answered = 0; skippedNoCredential = 0; skippedError = 0; skippedNoData = 0 }

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

            # Level 3: Try "public" if no credentials found and -TryPublic is enabled
            if ([string]::IsNullOrWhiteSpace($community) -and $TryPublic) {
                $community = 'public'
                $source = 'DefaultPublic'
                $publicAttempts++
                Write-Verbose "[TryPublic] Attempting default 'public' community for $($node.IP)"
            }

            if ([string]::IsNullOrWhiteSpace($community)) {
                Write-Warning "No SNMP community found for $($node.IP), skipping"
                $snmpOutcomes[$node.IP] = 'noCredential'
                $snmpCounts.skippedNoCredential++
                continue
            }

            # Invoke SNMP walk
            Write-Verbose "  Querying $($node.IP) with community from $source"
            $output = $null
            $snmpError = $null
            try {
                $output = Invoke-SnmpWalk -TargetIP $node.IP -Community $community -OID $OID -ErrorAction Stop
            }
            catch {
                $snmpError = $_.Exception.Message
                Write-Warning "SNMP query failed for $($node.IP): $snmpError"
                $snmpOutcomes[$node.IP] = 'error'
                $snmpCounts.skippedError++
                continue
            }

            if ($null -eq $output -or @($output).Count -eq 0) {
                Write-Verbose "No SNMP data returned from $($node.IP)"
                $snmpOutcomes[$node.IP] = 'noData'
                $snmpCounts.skippedNoData++
                continue
            }
            $snmpOutcomes[$node.IP] = 'answered'
            $snmpCounts.answered++

            # Parse LLDP/CDP output. BEST-EFFORT MVP (see function help): we do not fully
            # decode the LLDP MIB rows. For each output line we look only at the VALUE
            # portion (right of '='), never the OID itself (the numeric OID contains
            # dotted-decimal runs that would otherwise be mistaken for IPv4 addresses),
            # extract an octet-validated IPv4 management address, and only create an edge
            # when that address is already a known node.
            foreach ($line in $output) {
                $value = if ($line -match '=\s*(.+)$') { $matches[1] } else { '' }
                if ([string]::IsNullOrWhiteSpace($value)) { continue }

                $targetIP = $null

                # Only typed address values are eligible. Arbitrary STRING values can
                # contain known IPs but are not evidence of a neighbor relationship.
                if ($value -match '^IpAddress:\s*((?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3})\s*$') {
                    $targetIP = $matches[1]
                }
                elseif ($value -match '^Hex-STRING:\s*([0-9A-Fa-f]{2})[ :]+([0-9A-Fa-f]{2})[ :]+([0-9A-Fa-f]{2})[ :]+([0-9A-Fa-f]{2})\s*$') {
                    $targetIP = @(
                        [Convert]::ToInt32($matches[1], 16)
                        [Convert]::ToInt32($matches[2], 16)
                        [Convert]::ToInt32($matches[3], 16)
                        [Convert]::ToInt32($matches[4], 16)
                    ) -join '.'
                }

                if ([string]::IsNullOrWhiteSpace($targetIP)) { continue }

                # Skip self-loops.
                if ($targetIP -eq $node.IP) { continue }

                # Only accept addresses that map to a node already in the topology.
                $targetNode = $Topology.Nodes | Where-Object { $_.IP -eq $targetIP }
                if (-not $targetNode) { continue }

                # Best-effort interface label extraction.
                $label = 'LLDP'
                if ($value -match '(?:ifName|Interface|Port(?:Id)?)\s*[:=]\s*"?([^"\s]+)"?') {
                    $label = $matches[1]
                }

                $edge = [pscustomobject]@{
                    SourceIP   = $node.IP
                    TargetIP   = $targetIP
                    Label      = $label
                    Source     = 'SNMP'
                    Confidence = 'L2-SNMP-Heuristic'
                }

                $null = $discoveredEdges.Add($edge)
            }
        }

        Write-Verbose "Discovered $($discoveredEdges.Count) SNMP edges"
        $summaryLine = "SNMP summary: queried $($snmpCounts.queried) answered $($snmpCounts.answered) skippedNoCredential $($snmpCounts.skippedNoCredential) skippedError $($snmpCounts.skippedError) skippedNoData $($snmpCounts.skippedNoData)"
        Write-Host $summaryLine
        Write-Verbose $summaryLine

        if ($TryPublic -and $publicAttempts -gt 0) {
            Write-Warning "Used default 'public' community string on $publicAttempts device(s)"
        }

        # Attach completeness evidence to topology
        $Topology | Add-Member -NotePropertyName SnmpOutcomes -NotePropertyValue $snmpOutcomes -Force
        $Topology | Add-Member -NotePropertyName SnmpSummary -NotePropertyValue $snmpCounts -Force

        # Merge new edges with existing ones
        $allEdges = @($Topology.Edges) + @($discoveredEdges)
        $Topology.Edges = Merge-Edges -Edges $allEdges

        return $Topology
    }
}
