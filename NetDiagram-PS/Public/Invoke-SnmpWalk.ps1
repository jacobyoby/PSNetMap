function Invoke-SnmpWalk {
    <#
    .SYNOPSIS
        Invokes the net-snmp snmpwalk binary against a target device
    .DESCRIPTION
        Calls snmpwalk directly (must be in PATH) with specified OID and credentials.
        Resolves 'snmpwalk' on macOS/Linux and 'snmpwalk.exe' on Windows.
        Returns raw output lines.

        SECURITY - PROCESS LIST EXPOSURE (known limitation): snmpwalk receives the
        community string as a command-line argument ('-c <community>'). While it runs,
        the community is visible to any local user who can list processes (ps, Get-Process
        with command-line access, /proc). This is inherent to shelling out to net-snmp and
        cannot be avoided without a native SNMP client. Verbose logging in this function
        redacts the community (prints '-c ****'), but the process arguments themselves are
        not redacted. Treat SNMP v1/v2c community strings as low-secrecy and prefer SNMPv3
        with authentication for anything sensitive.
    .PARAMETER TargetIP
        IP address (IPv4 or IPv6) or hostname (FQDN) to query. Must not begin with '-'.
    .PARAMETER Community
        SNMP community string. Must not begin with '-' (argument-injection guard).
    .PARAMETER OID
        OID to walk (default: LLDP remote table). Digits and dots only.
    .PARAMETER Version
        SNMP version: v1, v2c, or v3 (default: v2c)
    .PARAMETER TimeoutSeconds
        Timeout in seconds (default: 2)
    .EXAMPLE
        Invoke-SnmpWalk -TargetIP '10.66.1.1' -Community 'public'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({
            if ($_ -match '^-') { throw "TargetIP must not begin with '-'." }
            $ip = $null
            if (-not [System.Net.IPAddress]::TryParse($_, [ref]$ip)) {
                if ($_ -notmatch '^[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?)*$') {
                    throw "TargetIP '$_' is not a valid IPv4, IPv6, or hostname."
                }
            }
            $true
        })]
        [string]$TargetIP,

        [Parameter(Mandatory)]
        [ValidateScript({
            if ($_ -match '^-') { throw "Community must not begin with '-' (argument-injection guard)." }
            $true
        })]
        [string]$Community,

        [Parameter()]
        [ValidatePattern('^\d+(\.\d+)*$')]
        [string]$OID = '1.0.8802.1.1.2.1.4',

        [Parameter()]
        [ValidateSet('v1', 'v2c', 'v3')]
        [string]$Version = 'v2c',

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 2
    )

    # Locate the snmpwalk binary. It is 'snmpwalk.exe' on Windows and 'snmpwalk'
    # on macOS/Linux, so probe for both rather than assuming the Windows name.
    # Restrict to Application so a same-named function/alias/script cannot be invoked.
    $snmpWalkCmd = $null
    foreach ($candidate in @('snmpwalk', 'snmpwalk.exe')) {
        $found = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $snmpWalkCmd = $found.Source
            break
        }
    }
    if (-not $snmpWalkCmd) {
        throw "snmpwalk not found in PATH. Please install net-snmp tools (brew install net-snmp, apt install snmp, or choco install net-snmp)."
    }

    try {
        $arguments = @(
            '-' + $Version.ToLower()
            '-c', $Community
            '-t', $TimeoutSeconds.ToString()
            $TargetIP
            $OID
        )

        # Never emit the community string in verbose output. Redact '-c <community>'
        # to '-c ****'. (The community is still visible in the process argument list
        # while snmpwalk runs - see the SECURITY note in the function help.)
        $redactedArgs = @(
            '-' + $Version.ToLower()
            '-c', '****'
            '-t', $TimeoutSeconds.ToString()
            $TargetIP
            $OID
        )
        Write-Verbose "Running: $snmpWalkCmd $($redactedArgs -join ' ')"

        $output = & $snmpWalkCmd @arguments 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "snmpwalk failed for $TargetIP with exit code $LASTEXITCODE"
            return @()
        }

        return $output
    }
    catch {
        Write-Warning "Failed to execute snmpwalk for ${TargetIP}: $_"
        return @()
    }
}
