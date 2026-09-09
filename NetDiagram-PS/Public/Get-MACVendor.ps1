function Get-MACVendor {
    <#
    .SYNOPSIS
        Looks up vendor information from MAC address OUI
    .DESCRIPTION
        Identifies the manufacturer of a network device based on its MAC address
        using the Organizationally Unique Identifier (OUI) lookup.
        No credentials required. The built-in table is a 31-prefix sample; for
        full coverage download the IEEE oui.csv and use -OuiDatabasePath.

        Example to fetch the full registry:
          Invoke-WebRequest -Uri https://standards-oui.ieee.org/oui/oui.csv -OutFile ./oui.csv
          Get-MACVendor -MACAddress '00:1A:A0:12:34:56' -OuiDatabasePath ./oui.csv
    .PARAMETER MACAddress
        MAC address in any common format (AA:BB:CC:DD:EE:FF, AA-BB-CC-DD-EE-FF, AABBCCDDEEFF)
    .EXAMPLE
        Get-MACVendor -MACAddress '00:1A:A0:12:34:56'

        Returns vendor information for the MAC address
    .EXAMPLE
        Get-LocalARPTable | ForEach-Object { Get-MACVendor -MACAddress $_.MACAddress }

        Get vendor info for all devices in ARP table
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$MACAddress,

        [Parameter()]
        [string]$OuiDatabasePath
    )

    begin {
        # Common OUI prefix database (top vendors) — 31-prefix sample
        $ouiDatabase = @{
            '00:1A:A0' = 'Dell'
            '00:50:56' = 'VMware'
            '00:0C:29' = 'VMware'
            '00:05:69' = 'VMware'
            '08:00:27' = 'Oracle VirtualBox'
            '52:54:00' = 'QEMU/KVM'
            '00:15:5D' = 'Microsoft Hyper-V'
            '00:03:FF' = 'Microsoft'
            'DC:A6:32' = 'Raspberry Pi'
            'B8:27:EB' = 'Raspberry Pi'
            'E4:5F:01' = 'Raspberry Pi'
            '00:0A:95' = 'Apple'
            'AC:DE:48' = 'Apple'
            '00:1B:63' = 'Apple'
            '00:25:00' = 'Apple'
            '28:6A:BA' = 'Apple'
            '00:23:12' = 'Cisco'
            '00:1E:14' = 'Cisco'
            '00:26:0A' = 'Cisco'
            'D0:D0:FD' = 'Cisco'
            '00:04:96' = 'Cisco'
            '00:E0:4C' = 'Realtek'
            '00:27:22' = 'TP-Link'
            '50:C7:BF' = 'TP-Link'
            '00:50:F2' = 'Microsoft'
            '00:12:3F' = 'Dell'
            '00:14:22' = 'Dell'
            '00:1E:C9' = 'HP'
            '00:21:5A' = 'HP'
            '00:30:6E' = 'Netgear'
            '00:09:5B' = 'Netgear'
        }

        # Optionally load full IEEE oui.csv (Assignment, Organization Name)
        if ($OuiDatabasePath) {
            if (-not (Test-Path -LiteralPath $OuiDatabasePath)) {
                throw "OUI database file not found: '$OuiDatabasePath'"
            }
            try {
                $rows = Import-Csv -LiteralPath $OuiDatabasePath
                if ($rows.Count -eq 0 -or -not $rows[0].PSObject.Properties['Assignment'] -or -not $rows[0].PSObject.Properties['Organization Name']) {
                    throw "OUI CSV missing required columns 'Assignment' and 'Organization Name'"
                }
                foreach ($r in $rows) {
                    $assignment = ([string]$r.Assignment -replace '[^0-9A-Fa-f]', '').ToUpper()
                    if ($assignment.Length -ge 6) {
                        $prefix = $assignment.Substring(0, 2) + ':' + $assignment.Substring(2, 2) + ':' + $assignment.Substring(4, 2)
                        $ouiDatabase[$prefix] = [string]$r.'Organization Name'
                    }
                }
            }
            catch {
                throw "Failed to load OUI database '$OuiDatabasePath': $_"
            }
        }
    }

    process {
        foreach ($mac in $MACAddress) {
            if ([string]::IsNullOrWhiteSpace($mac)) {
                continue
            }

            $oui = $null
            $vendor = 'Unknown'

            # Remove non-hex characters and normalize to AA:BB:CC:DD:EE:FF
            $hexOnly = ($mac -replace '[^0-9A-Fa-f]', '').ToUpper()

            if ($hexOnly.Length -ge 12) {
                $hexOnly = $hexOnly.Substring(0, 12)

                $octets = for ($i = 0; $i -lt 12; $i += 2) {
                    $hexOnly.Substring($i, 2)
                }

                $normalizedMAC = ($octets -join ':')
                $oui = ($octets[0..2] -join ':')

                if ($ouiDatabase.ContainsKey($oui)) {
                    $vendor = $ouiDatabase[$oui]
                }
            }
            else {
                $normalizedMAC = $mac.ToUpper()
                $vendor = 'Invalid MAC'
            }

            [pscustomobject]@{
                MACAddress = $normalizedMAC
                OUI        = $oui
                Vendor     = $vendor
            }
        }
    }
}
