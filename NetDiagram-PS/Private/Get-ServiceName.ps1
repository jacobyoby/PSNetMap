function Get-ServiceName {
    <#
    .SYNOPSIS
        Maps port numbers to common service names
    #>
    param([int]$Port)

    $services = @{
        21   = 'FTP'
        22   = 'SSH'
        23   = 'Telnet'
        25   = 'SMTP'
        53   = 'DNS'
        80   = 'HTTP'
        110  = 'POP3'
        143  = 'IMAP'
        161  = 'SNMP'
        443  = 'HTTPS'
        445  = 'SMB'
        3389 = 'RDP'
        8080 = 'HTTP-ALT'
        8443 = 'HTTPS-ALT'
    }

    if ($services.ContainsKey($Port)) {
        return $services[$Port]
    }
    return "Unknown"
}
