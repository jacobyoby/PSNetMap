Import-Module -Name (Join-Path $PSScriptRoot '..' 'src' 'NetDiagram-PS.psd1') -Force

Describe 'Export-DrawIO' {
    It 'writes required mxCell parents and all nodes' {
        $topology = [pscustomobject]@{
            Nodes = @(
                [pscustomobject]@{ IP='10.0.0.1'; Hostname='core01'; Layer='Core' },
                [pscustomobject]@{ IP='10.0.1.5'; Hostname='srv01'; Layer='Servers' }
            )
            Edges = @()
            Subnets = @()
        }
        $tempFile = New-TemporaryFile
        try {
            $null = $topology | Export-DrawIO -OutFile $tempFile.FullName
            $xml = Get-Content -LiteralPath $tempFile.FullName -Raw
            $xml | Should -Match '<mxCell id="0"/>'
            $xml | Should -Match '<mxCell id="1" parent="0"/>'
            ([regex]::Matches($xml, 'vertex="1" parent="1"').Count) | Should -Be $topology.Nodes.Count
        } finally {
            Remove-Item $tempFile.FullName -ErrorAction SilentlyContinue
        }
    }

    It 'connects edges to existing nodes' {
        $topology = [pscustomobject]@{
            Nodes = @(
                [pscustomobject]@{ IP='10.0.0.1'; Hostname='core01'; Layer='Core' },
                [pscustomobject]@{ IP='10.0.0.2'; Hostname='core02'; Layer='Core' }
            )
            Edges = @(
                [pscustomobject]@{ SourceIP='10.0.0.1'; TargetIP='10.0.0.2'; Label='Link'; Source='Manual' }
            )
            Subnets = @()
        }
        $tempFile = New-TemporaryFile
        try {
            $null = $topology | Export-DrawIO -OutFile $tempFile.FullName
            $xml = Get-Content -LiteralPath $tempFile.FullName -Raw
            $nodeIds = [regex]::Matches($xml, 'id="(n\d+)" value') | ForEach-Object { $_.Groups[1].Value }
            $edgeMatch = [regex]::Match($xml, 'edge="1" parent="1" source="(?<src>[^"]+)" target="(?<tgt>[^"]+)"')
            $nodeIds | Should -Contain $edgeMatch.Groups['src'].Value
            $nodeIds | Should -Contain $edgeMatch.Groups['tgt'].Value
        } finally {
            Remove-Item $tempFile.FullName -ErrorAction SilentlyContinue
        }
    }

    It 'allows draw.io round-trip basic checks' {
        $topology = [pscustomobject]@{
            Nodes = @(
                [pscustomobject]@{ IP='10.0.0.1'; Hostname='core01'; Layer='Core' },
                [pscustomobject]@{ IP='10.0.0.2'; Hostname='dist01'; Layer='Dist' },
                [pscustomobject]@{ IP='10.0.0.3'; Hostname='srv01'; Layer='Servers' }
            )
            Edges = @(
                [pscustomobject]@{ SourceIP='10.0.0.1'; TargetIP='10.0.0.2'; Label='Uplink'; Source='Manual' },
                [pscustomobject]@{ SourceIP='10.0.0.2'; TargetIP='10.0.0.3'; Label='Access'; Source='Manual' }
            )
            Subnets = @()
        }
        $tempFile = New-TemporaryFile
        try {
            $null = $topology | Export-DrawIO -OutFile $tempFile.FullName
            $content = Get-Content -LiteralPath $tempFile.FullName
            ($content | Where-Object { $_ -match '<mxCell id="n' }).Count | Should -Be $topology.Nodes.Count
        } finally {
            Remove-Item $tempFile.FullName -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Merge-Edges' {
    It 'deduplicates and prefers SNMP confidence' {
        $edges = @(
            [pscustomobject]@{ SourceIP='10.0.0.1'; TargetIP='10.0.0.2'; Label=''; Source='Manual'; Confidence='L3-Inferred' },
            [pscustomobject]@{ SourceIP='10.0.0.2'; TargetIP='10.0.0.1'; Label='Gi0/1'; Source='SNMP'; Confidence='L2-SNMP' }
        )
        $merged = $edges | Merge-Edges
        $merged.Count | Should -Be 1
        $merged[0].Confidence | Should -Be 'L2-SNMP'
        $merged[0].Label | Should -Be 'Gi0/1'
    }
}

Describe 'Test-DeviceReachability' {
    It 'marks nodes reachable based on custom ping script' {
        $topology = [pscustomobject]@{
            Nodes = @(
                [pscustomobject]@{ IP='10.0.0.1'; Hostname='core01'; Layer='Core'; Reachable=$false },
                [pscustomobject]@{ IP='10.0.0.5'; Hostname='srv01'; Layer='Servers'; Reachable=$false }
            )
            Edges = @()
            Subnets = @()
        }
        $pingScript = { param($ip) return ($ip -eq '10.0.0.1') }
        $result = $topology | Test-DeviceReachability -PingScript $pingScript -MaxParallel 2
        ($result.Nodes | Where-Object { $_.IP -eq '10.0.0.1' }).Reachable | Should -BeTrue
        ($result.Nodes | Where-Object { $_.IP -eq '10.0.0.5' }).Reachable | Should -BeFalse
    }
}
