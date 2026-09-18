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
$local:ErrorActionPreference = 'Stop'

# Module-level variables
$script:ModuleVersion = '1.4.1'

# Dot-source private helpers first (so public functions can call them),
# then public commands. Fail fast if directories are missing — SilentlyContinue
# would hide a broken install as a half-loaded module.
$Private = @(Get-ChildItem -Path "$PSScriptRoot/Private/*.ps1" -ErrorAction Stop)
$Public  = @(Get-ChildItem -Path "$PSScriptRoot/Public/*.ps1" -ErrorAction Stop)
if ($Private.Count -eq 0) { throw "NetDiagram-PS: no Private/*.ps1 files found under $PSScriptRoot" }
if ($Public.Count -eq 0) { throw "NetDiagram-PS: no Public/*.ps1 files found under $PSScriptRoot" }

foreach ($file in @($Private + $Public)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import $($file.FullName): $_"
    }
}

Export-ModuleMember -Function $Public.BaseName
