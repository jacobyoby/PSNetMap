#Requires -Version 7.4

<#
.SYNOPSIS
    NetDiagram-PS - Network discovery and diagram generation module
.DESCRIPTION
    Discovers network nodes/links and emits valid .drawio files with SNMP support.
    This loader dot-sources Private/*.ps1 (internal helpers) and Public/*.ps1
    (exported commands) so each function lives in its own file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-level variables
$script:ModuleVersion = '1.3.0'

# Dot-source private helpers first (so public functions can call them),
# then public commands.
$Private = @(Get-ChildItem -Path "$PSScriptRoot/Private/*.ps1" -ErrorAction SilentlyContinue)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot/Public/*.ps1"  -ErrorAction SilentlyContinue)

foreach ($file in @($Private + $Public)) {
    try {
        . $file.FullName
    }
    catch {
        Write-Error "Failed to import $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $Public.BaseName
