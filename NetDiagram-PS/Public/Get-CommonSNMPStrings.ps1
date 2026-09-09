function Get-CommonSNMPStrings {
    <#
    .SYNOPSIS
        Returns a list of common default SNMP community strings
    .DESCRIPTION
        Provides the most commonly used default SNMP community strings
        for testing. For security research and authorized testing only.
    .EXAMPLE
        Get-CommonSNMPStrings

        Returns array of common strings
    #>
    [CmdletBinding()]
    param()

    @(
        'public'
        'private'
        'community'
        'snmp'
        'manager'
        'monitor'
        'cisco'
        'admin'
        'security'
        'default'
    )
}
