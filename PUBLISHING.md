# Publishing NetDiagram-PS

This document describes how NetDiagram-PS is validated and published to the
[PowerShell Gallery](https://www.powershellgallery.com/).

## Prerequisites

- PowerShell 7.4+
- A PowerShell Gallery account and an **API key** (Account → API Keys)
- Modules used for validation/publishing:

  ```powershell
  Install-Module -Name Pester -MinimumVersion 5.0.0 -Force
  Install-Module -Name PSScriptAnalyzer -Force
  # PowerShellGet v2 ships with PowerShell; Publish-Module comes from it
  ```

## 1. Validate the manifest

```powershell
Test-ModuleManifest ./NetDiagram-PS/NetDiagram-PS.psd1
```

This must succeed with no errors. It confirms the manifest parses, the
`RootModule` resolves, and `FunctionsToExport` matches the module.

## 2. Lint

```powershell
Invoke-ScriptAnalyzer -Path ./NetDiagram-PS -Recurse -Severity Warning,Error
```

Resolve anything at `Error` severity before publishing. Warnings are advisory.

## 3. Run the test suite

On macOS or Linux:

```bash
./tests/run-tests.sh
```

Exit `2` is `CANNOT-RUN`, not a passing or failing suite. Install the named
prerequisite or run CI before publishing.

```powershell
./tests/run-tests.ps1
```

All tests must pass on the target platform(s).

## 4. Dry-run the publish

`Publish-Module` has no true `-WhatIf` for content, so verify what will be
packed by pointing at the module folder and confirming the version is new:

```powershell
$manifest = Import-PowerShellDataFile ./NetDiagram-PS/NetDiagram-PS.psd1
$manifest.ModuleVersion   # must be greater than the version already on the Gallery
Find-Module NetDiagram-PS -ErrorAction SilentlyContinue  # what's live now (if anything)
```

Bump `ModuleVersion` in `NetDiagram-PS.psd1` and add a `CHANGELOG.md` entry for
any release. The Gallery rejects re-publishing an existing version.

## 5. Publish

```powershell
$apiKey = '<your-powershell-gallery-api-key>'   # do NOT commit this
Publish-Module -Path ./NetDiagram-PS -NuGetApiKey $apiKey -Verbose
```

Notes:
- `-Path` points at the **module folder** (`NetDiagram-PS/`), not the repo root.
- The manifest's `PrivateData.PSData` already supplies `Tags`, `LicenseUri`,
  `ProjectUri`, and `ReleaseNotes`, which populate the Gallery listing.
- After publishing, confirm with `Find-Module NetDiagram-PS`.
- Use `Publish-Module` (PowerShellGet). Do not use `Publish-PSResource`; an empty
  `IconUri` in the manifest blocks `Publish-PSResource` validation, which is why
  commit `4a027ff` removed it.

## 6. Tag the release

```powershell
git tag v<version>
git push origin v<version>
```

## Release checklist

- [ ] `ModuleVersion` bumped in `NetDiagram-PS.psd1`
- [ ] `PrivateData.PSData.ReleaseNotes` updated
- [ ] `CHANGELOG.md` entry added
- [ ] `Test-ModuleManifest` passes
- [ ] `Invoke-ScriptAnalyzer` clean (no Errors)
- [ ] `Invoke-Pester` green
- [ ] `Publish-Module` succeeded and `Find-Module` shows the new version
- [ ] Git tag pushed
