1# PSNetMap - Folder Structure

This document describes the folder structure following PowerShell module best practices.

## Directory Layout

```
PSNetMap/
├── .gitignore                          # Git ignore rules
├── README.md                           # Main documentation
├── LICENSE                             # MIT License
├── CHANGELOG.md                        # Version history
├── STRUCTURE.md                        # This file
│
├── NetDiagram-PS/                      # PowerShell Module (Standard location)
│   ├── NetDiagram-PS.psd1             # Module manifest
│   └── NetDiagram-PS.psm1             # Module implementation
│
├── docs/                               # Extended documentation
│   ├── AUTO-DISCOVERY-RESEARCH.md     # Industry research on auto-discovery
│   └── DISCOVERY-QUICK-REF.md         # Quick reference guide
│
├── examples/                           # Example files and helper scripts
│   ├── inventory-template.json        # Template inventory file
│   ├── credmap.json                   # Credential mapping template
│   └── New-NetworkDiagram.ps1         # Quick-start wizard script
│
└── tests/                              # Pester test suite
    └── NetDiagram-PS.Tests.ps1        # Module tests
```

## Best Practices Implemented

### ✅ Standard PowerShell Module Layout
- Module files are in `NetDiagram-PS/` folder (matches module name)
- Module manifest (`.psd1`) and script (`.psm1`) are together
- Follows conventions used by PowerShell Gallery modules

### ✅ Clear Separation of Concerns
- **Module code**: `NetDiagram-PS/`
- **Examples & helpers**: `examples/`
- **Tests**: `tests/`
- **Documentation**: Root directory

### ✅ Proper Documentation
- `README.md` - User guide and quick start
- `LICENSE` - MIT License
- `CHANGELOG.md` - Version history
- `STRUCTURE.md` - This file

### ✅ Git Configuration
- `.gitignore` excludes:
  - User-specific files (my-network-inventory.json)
  - Build artifacts (*.nupkg)
  - IDE files (.vscode/, .idea/)
  - Secrets (*.key, credentials.json)

## Module Import

Import the module using:

```powershell
Import-Module .\NetDiagram-PS\NetDiagram-PS.psd1
```

Or for development, use `-Force` to reload:

```powershell
Import-Module .\NetDiagram-PS\NetDiagram-PS.psd1 -Force
```

## Quick Start

For the easiest experience, run the wizard:

```powershell
.\examples\New-NetworkDiagram.ps1
```

## Future Enhancements

Potential structure additions:

- `NetDiagram-PS/Public/` - Public function files
- `NetDiagram-PS/Private/` - Private helper functions
- `docs/` - Extended documentation
- `build/` - Build scripts for CI/CD
- `.github/` - GitHub Actions workflows

These are optional and can be added as the project grows.

---

**Last Updated:** 2025-01-25
**Module Version:** 0.1.0
