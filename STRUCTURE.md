# PSNetMap - Folder Structure

This document describes the folder structure following PowerShell module best practices.

## Directory Layout

```
PSNetMap/
├── CHANGELOG.md                        # Release history
├── LICENSE                             # MIT License
├── README.md                           # Main documentation & quick start
├── STRUCTURE.md                        # This file
├── WHERE-TO-SAVE-FILES.txt             # Guidance on storing personal data
├── NetDiagram-PS/                      # PowerShell module root
│   ├── NetDiagram-PS.psd1              # Module manifest (exports cmdlets)
│   └── NetDiagram-PS.psm1              # Module implementation
├── examples/                           # Example files and helper scripts
│   ├── New-NetworkDiagram.ps1          # Quick-start wizard script
│   ├── credmap.json                    # Credential mapping template
│   └── inventory-template.json         # Inventory template
└── tests/                              # Pester test suite
    └── NetDiagram.Tests.ps1            # Tests for the module functions
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
- `README.md` - Quick start, usage, and repository layout
- `LICENSE` - MIT License
- `CHANGELOG.md` - Version history
- `STRUCTURE.md` - Supplemental structure reference
- `WHERE-TO-SAVE-FILES.txt` - Guidance for keeping generated data outside the repo

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

---

**Last Updated:** 2025-11-02
**Module Version:** 1.1.0
