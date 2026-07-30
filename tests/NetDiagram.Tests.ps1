#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    # Import module (Join-Path built cross-platform, no backslash literal)
    $modulePath = Join-Path $PSScriptRoot '..' 'NetDiagram-PS' 'NetDiagram-PS.psd1'
    Import-Module $modulePath -Force

    # Read the manifest so version assertions track the manifest instead of a hard-coded string
    $script:Manifest = Import-PowerShellDataFile -Path $modulePath

    # Setup test data directory
    $script:TestDataPath = Join-Path $PSScriptRoot 'TestData'
    if (-not (Test-Path $script:TestDataPath)) {
        New-Item -Path $script:TestDataPath -ItemType Directory -Force | Out-Null
    }

    # Create test inventory
    $script:TestInventory = @{
        knownDevices = @(
            @{ ip = '192.168.1.1'; hostname = 'router01'; role = 'core-router'; vendor = 'Cisco' }
            @{ ip = '192.168.1.10'; hostname = 'switch01'; role = 'switch'; vendor = 'Cisco' }
            @{ ip = '192.168.1.20'; hostname = 'server01'; role = 'server'; vendor = 'Dell' }
        )
        subnets = @(
            @{ cidr = '192.168.1.0/24'; label = 'Test Network'; vlan = 1 }
        )
    }

    $script:TestInventoryPath = Join-Path $script:TestDataPath 'test-inventory.json'
    $script:TestInventory | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:TestInventoryPath -Force
}

AfterAll {
    # Cleanup test data
    if (Test-Path $script:TestDataPath) {
        Remove-Item -Path $script:TestDataPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Module Import' {
    It 'Should import the module successfully' {
        $module = Get-Module -Name 'NetDiagram-PS'
        $module | Should -Not -BeNullOrEmpty
        $module.Version | Should -Be $script:Manifest.ModuleVersion
    }

    It 'Should export all required cmdlets' {
        $commands = Get-Command -Module 'NetDiagram-PS'
        $commandNames = $commands.Name

        $commandNames | Should -Contain 'Import-Inventory'
        $commandNames | Should -Contain 'Test-DeviceReachability'
        $commandNames | Should -Contain 'Invoke-SnmpWalk'
        $commandNames | Should -Contain 'Get-SnmpNeighbors'
        $commandNames | Should -Contain 'Merge-Edges'
        $commandNames | Should -Contain 'Export-DrawIO'
        $commandNames | Should -Contain 'Export-Metadata'
        $commandNames | Should -Contain 'Compare-NetworkScans'
    }
}

Describe 'Import-Inventory' {
    It 'Should import inventory from JSON file' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $topology | Should -Not -BeNullOrEmpty
        $topology.Nodes | Should -HaveCount 3
        $topology.Subnets | Should -HaveCount 1
        $topology.Edges | Should -HaveCount 0
    }

    It 'Should set Layer property based on role' {
        $topology = Import-Inventory -Path $script:TestInventoryPath

        $router = $topology.Nodes | Where-Object { $_.Role -eq 'core-router' }
        $router.Layer | Should -Be 'Core'

        $switch = $topology.Nodes | Where-Object { $_.Role -eq 'switch' }
        $switch.Layer | Should -Be 'Access'

        $server = $topology.Nodes | Where-Object { $_.Role -eq 'server' }
        $server.Layer | Should -Be 'Servers'
    }

    It 'Should initialize Reachable property to null' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        foreach ($node in $topology.Nodes) {
            $node.Reachable | Should -BeNullOrEmpty
        }
    }

    It 'Should throw error for missing file' {
        { Import-Inventory -Path 'C:\NonExistent\file.json' } | Should -Throw
    }
}

Describe 'Test-DeviceReachability' {
    It 'Should set Reachable property for all nodes' {
        $topology = Import-Inventory -Path $script:TestInventoryPath

        # Mock Test-Connection to avoid actual network calls
        Mock Test-Connection {
            param($ComputerName)
            # Simulate: .1 is reachable, others are not
            return $ComputerName -eq '192.168.1.1'
        } -ModuleName 'NetDiagram-PS'

        $topology = $topology | Test-DeviceReachability -MaxParallel 4

        foreach ($node in $topology.Nodes) {
            $node.Reachable | Should -Not -BeNullOrEmpty
            $node.Reachable | Should -BeOfType [bool]
        }
    }

    It 'Should handle empty topology gracefully' {
        $emptyTopology = [pscustomobject]@{
            Nodes = @()
            Edges = @()
            Subnets = @()
        }

        { $emptyTopology | Test-DeviceReachability } | Should -Not -Throw
    }
}

Describe 'Merge-Edges' {
    It 'Should merge duplicate edges' {
        $edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'Gi0/1'; Source = 'Manual' }
            [pscustomobject]@{ SourceIP = '192.168.1.10'; TargetIP = '192.168.1.1'; Label = 'Gi0/2'; Source = 'Manual' }
        )

        $merged = Merge-Edges -Edges $edges
        $merged | Should -HaveCount 1
    }

    It 'Should prioritize L2-SNMP confidence over L3-Inferred' {
        $edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'Link1'; Source = 'Manual'; Confidence = 'L3-Inferred' }
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'Link2'; Source = 'SNMP'; Confidence = 'L2-SNMP' }
        )

        $merged = Merge-Edges -Edges $edges
        $merged | Should -HaveCount 1
        $merged[0].Confidence | Should -Be 'L2-SNMP'
    }

    It 'Should keep first non-empty label' {
        $edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'FirstLabel'; Source = 'Manual' }
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'SecondLabel'; Source = 'Manual' }
        )

        $merged = Merge-Edges -Edges $edges
        $merged | Should -HaveCount 1
        $merged[0].Label | Should -Be 'FirstLabel'
    }

    It 'Should handle empty edge array' {
        $merged = Merge-Edges -Edges @()
        $merged | Should -HaveCount 0
    }

    It 'Should skip edges with null or empty IP addresses' {
        $edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = ''; Label = 'Bad'; Source = 'Manual' }
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'Good'; Source = 'Manual' }
        )

        $merged = Merge-Edges -Edges $edges
        $merged | Should -HaveCount 1
        $merged[0].Label | Should -Be 'Good'
    }
}

Describe 'Export-DrawIO' {
    It 'Should export valid XML with required mxCell elements' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $drawioPath = Join-Path $script:TestDataPath 'test.drawio'

        $topology | Export-DrawIO -OutFile $drawioPath

        Test-Path $drawioPath | Should -Be $true

        $content = Get-Content -Path $drawioPath -Raw
        $content | Should -Match '<mxCell id="0"/>'
        $content | Should -Match '<mxCell id="1" parent="0"/>'
    }

    It 'Should contain correct number of node cells' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $drawioPath = Join-Path $script:TestDataPath 'test-nodes.drawio'

        $topology | Export-DrawIO -OutFile $drawioPath

        $content = Get-Content -Path $drawioPath -Raw

        # Count vertex cells (nodes + subnet containers) - should have 3 nodes + 1 subnet = 4
        $vertexMatches = [regex]::Matches($content, 'vertex="1"')
        $vertexMatches.Count | Should -Be 4
    }

    It 'Should reference existing node IDs in edges' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $topology.Edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'Test'; Source = 'Manual'; Confidence = 'L3-Inferred' }
        )

        $drawioPath = Join-Path $script:TestDataPath 'test-edges.drawio'
        $topology | Export-DrawIO -OutFile $drawioPath

        $content = Get-Content -Path $drawioPath -Raw

        # Should contain edge element
        $content | Should -Match 'edge="1"'

        # Edge should reference source and target
        $content | Should -Match 'source="\d+"'
        $content | Should -Match 'target="\d+"'
    }

    It 'Should skip edges with invalid node IDs' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $topology.Edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '10.99.99.99'; Label = 'Invalid'; Source = 'Manual'; Confidence = 'L3-Inferred' }
        )

        $drawioPath = Join-Path $script:TestDataPath 'test-invalid-edge.drawio'

        # Should not throw, just skip invalid edge
        { $topology | Export-DrawIO -OutFile $drawioPath } | Should -Not -Throw
    }

    It 'Should create valid XML structure' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $drawioPath = Join-Path $script:TestDataPath 'test-xml.drawio'

        $topology | Export-DrawIO -OutFile $drawioPath

        # Try to load as XML to verify it's valid
        { [xml](Get-Content -Path $drawioPath -Raw) } | Should -Not -Throw
    }
}

Describe 'Export-Metadata' {
    It 'Should export metadata JSON with all required fields' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $topology.Edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'Test'; Source = 'SNMP'; Confidence = 'L2-SNMP' }
        )

        $metaPath = Join-Path $script:TestDataPath 'test-meta.json'
        $topology | Export-Metadata -OutFile $metaPath -CredSetsUsed @('TestCred1', 'TestCred2')

        Test-Path $metaPath | Should -Be $true

        $metadata = Get-Content -Path $metaPath -Raw | ConvertFrom-Json

        $metadata.scanStarted | Should -Not -BeNullOrEmpty
        $metadata.scanFinished | Should -Not -BeNullOrEmpty
        $metadata.tool | Should -Match 'NetDiagram-PS'
        $metadata.nodeCount | Should -Be 3
        $metadata.edgeCount | Should -Be 1
        $metadata.confidenceCounts.'L2-SNMP' | Should -Be 1
    }

    It 'Should handle empty credential sets' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $metaPath = Join-Path $script:TestDataPath 'test-meta-nocreds.json'

        { $topology | Export-Metadata -OutFile $metaPath } | Should -Not -Throw

        $metadata = Get-Content -Path $metaPath -Raw | ConvertFrom-Json
        $metadata.credSetsUsed | Should -HaveCount 0
    }
}

Describe 'Compare-NetworkScans' {
    It 'Should compare two scan snapshots and generate report' {
        # Create baseline
        $baseline = Import-Inventory -Path $script:TestInventoryPath
        $baselineMeta = Join-Path $script:TestDataPath 'baseline-meta.json'
        $baselineTopo = Join-Path $script:TestDataPath 'baseline-topo.json'

        $baseline | Export-Metadata -OutFile $baselineMeta
        $baseline | ConvertTo-Json -Depth 10 | Out-File -FilePath $baselineTopo -Force

        # Create current with changes
        $current = Import-Inventory -Path $script:TestInventoryPath
        $current.Nodes += [pscustomobject]@{
            IP = '192.168.1.30'
            Hostname = 'newserver01'
            Role = 'server'
            Vendor = 'HP'
            OS = 'Ubuntu'
            Layer = 'Servers'
            Reachable = $true
        }
        $current.Edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'New'; Source = 'SNMP'; Confidence = 'L2-SNMP' }
        )

        $currentMeta = Join-Path $script:TestDataPath 'current-meta.json'
        $currentTopo = Join-Path $script:TestDataPath 'current-topo.json'

        $current | Export-Metadata -OutFile $currentMeta
        $current | ConvertTo-Json -Depth 10 | Out-File -FilePath $currentTopo -Force

        # Compare
        $reportPath = Join-Path $script:TestDataPath 'comparison.md'

        { Compare-NetworkScans -BaselineMetadata $baselineMeta -BaselineTopology $baselineTopo `
                               -CurrentMetadata $currentMeta -CurrentTopology $currentTopo `
                               -OutFile $reportPath } | Should -Not -Throw

        Test-Path $reportPath | Should -Be $true

        $report = Get-Content -Path $reportPath -Raw
        $report | Should -Match 'Added Nodes'
        $report | Should -Match '192.168.1.30'
    }
}

Describe 'Round-trip Test' {
    It 'Should create topology, export to DrawIO, and produce valid XML' {
        $topology = Import-Inventory -Path $script:TestInventoryPath

        # Add some edges
        $topology.Edges = @(
            [pscustomobject]@{ SourceIP = '192.168.1.1'; TargetIP = '192.168.1.10'; Label = 'Gi0/1'; Source = 'Manual'; Confidence = 'L2-SNMP' }
            [pscustomobject]@{ SourceIP = '192.168.1.10'; TargetIP = '192.168.1.20'; Label = 'Gi0/2'; Source = 'Manual'; Confidence = 'L3-Inferred' }
        )

        $drawioPath = Join-Path $script:TestDataPath 'roundtrip.drawio'
        $topology | Export-DrawIO -OutFile $drawioPath

        # Read back and validate
        Test-Path $drawioPath | Should -Be $true

        $content = Get-Content -Path $drawioPath -Raw

        # Count mxCell lines
        $cellMatches = [regex]::Matches($content, '<mxCell')
        $cellMatches.Count | Should -BeGreaterThan 5  # At least root cells + 3 nodes + 2 edges

        # Validate XML structure
        $xml = [xml]$content
        $xml.mxfile | Should -Not -BeNullOrEmpty
        $xml.mxfile.diagram | Should -Not -BeNullOrEmpty
    }
}

Describe 'Defensive Coding Tests' {
    It 'Should handle null topology gracefully in Export-DrawIO' {
        $nullTopo = [pscustomobject]@{
            Nodes = $null
            Edges = @()
            Subnets = @()
        }

        $drawioPath = Join-Path $script:TestDataPath 'null-test.drawio'

        { $nullTopo | Export-DrawIO -OutFile $drawioPath } | Should -Throw
    }

    It 'Should handle missing properties in nodes' {
        $minimalInventory = @{
            knownDevices = @(
                @{ ip = '192.168.1.1' }  # Only IP, no other properties
            )
        }

        $minimalPath = Join-Path $script:TestDataPath 'minimal-inventory.json'
        $minimalInventory | ConvertTo-Json -Depth 10 | Out-File -FilePath $minimalPath -Force

        $topology = Import-Inventory -Path $minimalPath

        $topology.Nodes | Should -HaveCount 1
        $topology.Nodes[0].IP | Should -Be '192.168.1.1'
        $topology.Nodes[0].Role | Should -Not -BeNullOrEmpty
        $topology.Nodes[0].Layer | Should -Not -BeNullOrEmpty
    }

    It 'Should handle invalid JSON gracefully' {
        $badJsonPath = Join-Path $script:TestDataPath 'bad.json'
        'This is not valid JSON' | Out-File -FilePath $badJsonPath -Force

        { Import-Inventory -Path $badJsonPath } | Should -Throw
    }
}

Describe 'Get-MACVendor' {
    It 'Should resolve a known OUI to its vendor' {
        $result = Get-MACVendor -MACAddress '00:1A:A0:12:34:56'
        $result.Vendor | Should -Be 'Dell'
        $result.OUI | Should -Be '00:1A:A0'
    }

    It 'Should normalize MAC formats to colon-delimited uppercase' {
        (Get-MACVendor -MACAddress '001aa0123456').MACAddress | Should -Be '00:1A:A0:12:34:56'
        (Get-MACVendor -MACAddress '00-1a-a0-12-34-56').MACAddress | Should -Be '00:1A:A0:12:34:56'
    }

    It 'Should report Unknown for an unmapped OUI' {
        (Get-MACVendor -MACAddress 'FF:FF:FF:FF:FF:FF').Vendor | Should -Be 'Unknown'
    }

    It 'Should flag a too-short MAC as invalid' {
        (Get-MACVendor -MACAddress '00:1A').Vendor | Should -Be 'Invalid MAC'
    }

    It 'Should accept pipeline input for multiple MACs' {
        $results = @('00:1A:A0:00:00:00', '00:50:56:00:00:00') | Get-MACVendor
        $results | Should -HaveCount 2
        $results[1].Vendor | Should -Be 'VMware'
    }
}

Describe 'Get-CommonSNMPStrings' {
    It 'Should return the common default community strings' {
        $strings = Get-CommonSNMPStrings
        $strings | Should -Contain 'public'
        $strings | Should -Contain 'private'
        $strings.Count | Should -BeGreaterThan 5
    }
}

Describe 'Resolve-IPHostname' {
    It 'Should return a failure object for an unresolvable address' {
        # 192.0.2.0/24 is TEST-NET-1 (RFC 5737) and never resolves
        $result = Resolve-IPHostname -IPAddress '192.0.2.1'
        $result.IPAddress | Should -Be '192.0.2.1'
        $result.Success | Should -Be $false
    }
}

Describe 'Invoke-SnmpWalk' {
    It 'Should throw a helpful error when the snmpwalk binary is missing' {
        Mock Get-Command { $null } -ModuleName 'NetDiagram-PS' -ParameterFilter { $Name -like 'snmpwalk*' }
        { Invoke-SnmpWalk -TargetIP '192.0.2.1' -Community 'public' } |
            Should -Throw -ExpectedMessage '*snmpwalk not found*'
    }
}

Describe 'Test-IPInSubnet (private helper)' {
    It 'Should match an IP inside its CIDR range' {
        InModuleScope 'NetDiagram-PS' {
            Test-IPInSubnet -IP '192.168.1.50' -CIDR '192.168.1.0/24' | Should -Be $true
        }
    }

    It 'Should reject an IP outside the CIDR range' {
        InModuleScope 'NetDiagram-PS' {
            Test-IPInSubnet -IP '192.168.2.50' -CIDR '192.168.1.0/24' | Should -Be $false
        }
    }

    It 'Should return false for a malformed CIDR' {
        InModuleScope 'NetDiagram-PS' {
            Test-IPInSubnet -IP '192.168.1.50' -CIDR 'not-a-cidr' | Should -Be $false
        }
    }
}

Describe 'Get-SnmpNeighbors node eligibility (#1 regression)' {
    BeforeEach {
        # Empty credential map is valid; -TryPublic supplies the community so no
        # SecretManagement dependency is needed for the test.
        $script:CredMapPath = Join-Path $script:TestDataPath 'credmap-empty.json'
        '{}' | Out-File -FilePath $script:CredMapPath -Force
    }

    It 'Queries nodes with unknown reachability (Reachable = $null) by default' {
        # Import-Inventory leaves Reachable = $null; these must still be queried.
        $topology = Import-Inventory -Path $script:TestInventoryPath
        Mock Invoke-SnmpWalk { @() } -ModuleName 'NetDiagram-PS'

        $null = $topology | Get-SnmpNeighbors -CredentialMapPath $script:CredMapPath -TryPublic -WarningAction SilentlyContinue

        Should -Invoke Invoke-SnmpWalk -ModuleName 'NetDiagram-PS' -Times 3 -Exactly
    }

    It 'Skips untested nodes when -OnlyReachable is specified' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        Mock Invoke-SnmpWalk { @() } -ModuleName 'NetDiagram-PS'

        $null = $topology | Get-SnmpNeighbors -CredentialMapPath $script:CredMapPath -TryPublic -OnlyReachable -WarningAction SilentlyContinue

        Should -Invoke Invoke-SnmpWalk -ModuleName 'NetDiagram-PS' -Times 0 -Exactly
    }

    It 'Does not query nodes explicitly marked unreachable' {
        $topology = Import-Inventory -Path $script:TestInventoryPath
        foreach ($n in $topology.Nodes) { $n.Reachable = $false }
        $topology.Nodes[0].Reachable = $true
        Mock Invoke-SnmpWalk { @() } -ModuleName 'NetDiagram-PS'

        $null = $topology | Get-SnmpNeighbors -CredentialMapPath $script:CredMapPath -TryPublic -WarningAction SilentlyContinue

        # Only the single reachable/unmarked node should be queried
        Should -Invoke Invoke-SnmpWalk -ModuleName 'NetDiagram-PS' -Times 1 -Exactly
    }
}

Describe 'Invoke-SnmpWalk parameter validation (#6 regression)' {
    It 'Rejects an invalid SNMP version' {
        { Invoke-SnmpWalk -TargetIP '192.0.2.1' -Community 'public' -Version 'v9' } | Should -Throw
    }

    It 'Rejects a TargetIP beginning with a dash (argument-injection guard)' {
        { Invoke-SnmpWalk -TargetIP '-oOutputFile' -Community 'public' } | Should -Throw
    }

    It 'Rejects a community beginning with a dash' {
        { Invoke-SnmpWalk -TargetIP '192.0.2.1' -Community '-c' } | Should -Throw
    }

    It 'Rejects a non-numeric OID' {
        { Invoke-SnmpWalk -TargetIP '192.0.2.1' -Community 'public' -OID 'not.an.oid' } | Should -Throw
    }

    It 'Accepts a valid FQDN target' {
        # Valid params get past binding; with the binary mocked away it throws the
        # "not found" error, which proves validation passed.
        Mock Get-Command { $null } -ModuleName 'NetDiagram-PS' -ParameterFilter { $Name -like 'snmpwalk*' }
        { Invoke-SnmpWalk -TargetIP 'switch01.example.com' -Community 'public' } |
            Should -Throw -ExpectedMessage '*snmpwalk not found*'
    }
}

Describe 'Invoke-PortScan parameter validation (#7 regression)' {
    It 'Rejects a port outside 1-65535' {
        { Invoke-PortScan -IPAddress '192.0.2.1' -Ports 70000 } | Should -Throw
    }

    It 'Rejects a timeout outside 1-60000 (guards against indefinite hang)' {
        { Invoke-PortScan -IPAddress '192.0.2.1' -TimeoutMs 0 } | Should -Throw
    }
}

Describe 'Export-DrawIO duplicate-IP handling (#8 regression)' {
    It 'Emits unique mxCell ids and de-duplicates nodes sharing an IP' {
        $topology = [pscustomobject]@{
            Nodes = @(
                [pscustomobject]@{ IP = '192.168.1.5'; Hostname = 'dup-a'; Role = 'switch'; Vendor = 'x'; OS = 'x'; Layer = 'Access'; Reachable = $true }
                [pscustomobject]@{ IP = '192.168.1.5'; Hostname = 'dup-b'; Role = 'switch'; Vendor = 'x'; OS = 'x'; Layer = 'Access'; Reachable = $true }
                [pscustomobject]@{ IP = '192.168.1.6'; Hostname = 'uniq';  Role = 'server'; Vendor = 'x'; OS = 'x'; Layer = 'Servers'; Reachable = $true }
            )
            Edges   = @()
            Subnets = @()
        }

        $drawioPath = Join-Path $script:TestDataPath 'dup-ip.drawio'
        $topology | Export-DrawIO -OutFile $drawioPath -WarningAction SilentlyContinue

        $xml = [xml](Get-Content -Path $drawioPath -Raw)
        $ids = @($xml.SelectNodes('//mxCell') | ForEach-Object { $_.id })

        # All mxCell ids must be unique
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count

        # Duplicate IP collapsed to a single node vertex (2 unique IPs)
        @($xml.SelectNodes("//mxCell[@vertex='1']")).Count | Should -Be 2
    }
}

Describe 'Export-DrawIO subnet container parenting (#9 regression)' {
    It 'Parents nodes into the matching subnet container instead of the root' {
        # Test inventory nodes live in 192.168.1.0/24 and there is a matching subnet.
        $topology = Import-Inventory -Path $script:TestInventoryPath
        $drawioPath = Join-Path $script:TestDataPath 'containers.drawio'
        $topology | Export-DrawIO -OutFile $drawioPath

        $xml = [xml](Get-Content -Path $drawioPath -Raw)
        $container = @($xml.SelectNodes("//mxCell[contains(@style,'swimlane')]"))[0]
        $container | Should -Not -BeNullOrEmpty

        $nodeCells = @($xml.SelectNodes("//mxCell[@vertex='1' and not(contains(@style,'swimlane'))]"))
        $nodeCells.Count | Should -Be 3
        foreach ($n in $nodeCells) {
            $n.parent | Should -Be $container.id
        }
    }
}

Describe 'Quick-start wizard CIDR math (#4 regression)' {
    BeforeAll {
        # Dot-source the example; the dot-source guard returns before the wizard body
        # runs, so only the pure CIDR helper functions get defined.
        $exampleScript = Join-Path $PSScriptRoot '..' 'examples' 'New-NetworkDiagram.ps1'
        . $exampleScript
    }

    It 'Computes the correct network address for a non-/24 prefix' {
        $ipValue = ConvertTo-UInt32Address '10.0.5.37'
        $mask    = Get-PrefixMask -PrefixLength 22
        $network = ConvertFrom-UInt32Address ([uint32]($ipValue -band $mask))
        $network | Should -Be '10.0.4.0'
    }

    It 'Round-trips an address through UInt32 conversion' {
        ConvertFrom-UInt32Address (ConvertTo-UInt32Address '192.168.1.200') | Should -Be '192.168.1.200'
    }

    It 'Enumerates all usable hosts of a /24 on Full depth' {
        $net = ConvertTo-UInt32Address '192.168.1.0'
        $bc  = ConvertTo-UInt32Address '192.168.1.255'
        $targets = @(Get-SubnetScanTarget -NetworkValue $net -BroadcastValue $bc -ScanDepth 'Full')
        $targets.Count | Should -Be 254
        (ConvertFrom-UInt32Address $targets[0])  | Should -Be '192.168.1.1'
        (ConvertFrom-UInt32Address $targets[-1]) | Should -Be '192.168.1.254'
    }

    It 'Caps a large subnet (/16) at a /22 worth of hosts on Full depth' {
        $net = ConvertTo-UInt32Address '10.1.0.0'
        $bc  = ConvertTo-UInt32Address '10.1.255.255'
        $targets = @(Get-SubnetScanTarget -NetworkValue $net -BroadcastValue $bc -ScanDepth 'Full' -MaxScanHosts 1022)
        $targets.Count | Should -Be 1022
    }

    It 'Samples at most 8 in-range hosts on Quick depth' {
        $net = ConvertTo-UInt32Address '192.168.1.0'
        $bc  = ConvertTo-UInt32Address '192.168.1.255'
        $targets = @(Get-SubnetScanTarget -NetworkValue $net -BroadcastValue $bc -ScanDepth 'Quick')
        $targets.Count | Should -BeLessOrEqual 8
        $targets.Count | Should -BeGreaterThan 0
        foreach ($t in $targets) {
            (ConvertTo-UInt32Address (ConvertFrom-UInt32Address $t)) | Should -BeGreaterThan $net
            (ConvertTo-UInt32Address (ConvertFrom-UInt32Address $t)) | Should -BeLessThan $bc
        }
    }

    It 'Returns no targets for a /31 point-to-point link' {
        $net = ConvertTo-UInt32Address '10.0.0.0'
        $bc  = ConvertTo-UInt32Address '10.0.0.1'
        $targets = @(Get-SubnetScanTarget -NetworkValue $net -BroadcastValue $bc -ScanDepth 'Full')
        $targets.Count | Should -Be 0
    }
}
