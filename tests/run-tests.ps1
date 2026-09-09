#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$minimumPester = [version]'5.0.0'
$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge $minimumPester } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    [Console]::Error.WriteLine(
        "CANNOT-RUN: Pester $minimumPester or newer is not installed; suite not executed."
    )
    exit 2
}

try {
    Import-Module Pester -MinimumVersion $minimumPester -ErrorAction Stop
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $PSScriptRoot 'NetDiagram.Tests.ps1'
    $config.Run.PassThru = $true
    $config.Run.Exit = $false
    $config.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $config

    if ($null -eq $result -or $result.TotalCount -eq 0) {
        [Console]::Error.WriteLine('FAILED: Pester discovered zero tests.')
        exit 1
    }
    if ($result.FailedCount -gt 0) {
        [Console]::Error.WriteLine("FAILED: $($result.FailedCount) Pester test(s) failed.")
        exit 1
    }

    Write-Host "PASS: $($result.PassedCount) Pester test(s) passed."
    exit 0
}
catch {
    [Console]::Error.WriteLine("FAILED: Pester runner error: $($_.Exception.Message)")
    exit 1
}
