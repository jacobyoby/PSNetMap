#!/usr/bin/env bash
# Idempotent repository bootstrap for the NetDiagram-PS Cloud Agent environment.
# Ensures the PowerShell modules required to run the test suite (Pester 5+) and
# the linter (PSScriptAnalyzer) are available for the current user. Safe to run
# repeatedly: modules are only installed when missing.
set -euo pipefail

pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    $hasPester = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge [version]"5.0.0" }
    if (-not $hasPester) {
        Write-Host "Installing Pester (>= 5.0.0)..."
        Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser -SkipPublisherCheck
    } else {
        Write-Host "Pester already present: $((($hasPester | Sort-Object Version -Descending)[0]).Version)"
    }

    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
        Write-Host "Installing PSScriptAnalyzer..."
        Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
    } else {
        Write-Host "PSScriptAnalyzer already present: $((Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending)[0].Version)"
    }

    Write-Host "Validating module manifest..."
    Test-ModuleManifest ./NetDiagram-PS/NetDiagram-PS.psd1 | Out-Null
    Write-Host "NetDiagram-PS environment bootstrap complete."
'
