# Network Share Credential Setup for VMTags
<#
.SYNOPSIS
    Sets up network share credentials for VMTags centralized CSV file access

.DESCRIPTION
    This script helps configure network share credentials for accessing centralized
    VMTags CSV files. It supports multiple credential storage methods.

.PARAMETER SharePath
    The network share path (e.g., \\orgaze\DCC\VirtualTeam\Scripts\vRA_PSH\Datasource)

.PARAMETER CredentialName
    Name to store in Windows Credential Manager (default: VMTags-FileServer)

.PARAMETER Username
    Username for network share access (e.g., DOMAIN\username)

.PARAMETER TestAccess
    Test access to network share after setting credentials

.EXAMPLE
    .\Set-NetworkShareCredentials.ps1 -SharePath "\\orgaze\DCC\VirtualTeam\Scripts\vRA_PSH\Datasource"

.EXAMPLE
    .\Set-NetworkShareCredentials.ps1 -SharePath "\\fileserver\VMTags" -CredentialName "MyCustomTarget" -Username "DOMAIN\serviceaccount"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Network share path")]
    [string]$SharePath,

    [Parameter(Mandatory = $false, HelpMessage = "Credential manager target name")]
    [string]$CredentialName = "VMTags-FileServer",

    [Parameter(Mandatory = $false, HelpMessage = "Username for share access")]
    [string]$Username,

    [Parameter(Mandatory = $false, HelpMessage = "Test access after setup")]
    [switch]$TestAccess
)

function Write-CredSetupLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

try {
    Write-CredSetupLog "=== VMTags Network Share Credential Setup ===" "INFO"
    Write-CredSetupLog "Share Path: $SharePath" "INFO"
    Write-CredSetupLog "Credential Name: $CredentialName" "INFO"

    # Get username if not provided
    if (-not $Username) {
        $Username = Read-Host "Enter username for network share access (e.g., DOMAIN\username or username@domain.com)"
    }

    Write-CredSetupLog "Username: $Username" "INFO"

    # Get password securely
    Write-Host ""
    Write-Host "Enter password for $Username:" -ForegroundColor Yellow
    $SecurePassword = Read-Host -AsSecureString

    if (-not $SecurePassword) {
        throw "Password is required"
    }

    # Store credentials using cmdkey (most reliable method)
    Write-CredSetupLog "Storing credentials in Windows Credential Manager..." "INFO"

    # Extract server name from UNC path for cmdkey
    $serverName = $SharePath -replace '^\\\\([^\\]+).*', '$1'
    Write-CredSetupLog "Server name extracted: $serverName" "INFO"

    # Convert SecureString to plain text for cmdkey
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

    try {
        # Store with specific target name for VMTags
        $cmdkeyResult1 = cmd /c "cmdkey /add:$CredentialName /user:$Username /pass:$PlainPassword" 2>&1
        Write-CredSetupLog "Credential stored with target '$CredentialName': $cmdkeyResult1" "SUCCESS"

        # Also store with server name for general access
        $cmdkeyResult2 = cmd /c "cmdkey /add:$serverName /user:$Username /pass:$PlainPassword" 2>&1
        Write-CredSetupLog "Credential stored with target '$serverName': $cmdkeyResult2" "SUCCESS"

        # Store generic UNC path credential
        $cmdkeyResult3 = cmd /c "cmdkey /add:$SharePath /user:$Username /pass:$PlainPassword" 2>&1
        Write-CredSetupLog "Credential stored with target '$SharePath': $cmdkeyResult3" "SUCCESS"
    }
    finally {
        # Clear password from memory
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        $PlainPassword = $null
    }

    Write-CredSetupLog "Credentials successfully stored!" "SUCCESS"

    # List stored credentials for verification
    Write-CredSetupLog "Verifying stored credentials..." "INFO"
    $storedCreds = cmd /c "cmdkey /list" | Select-String -Pattern $CredentialName, $serverName
    if ($storedCreds) {
        Write-CredSetupLog "Found stored credentials:" "SUCCESS"
        $storedCreds | ForEach-Object { Write-CredSetupLog "  $_" "INFO" }
    }

    # Test access if requested
    if ($TestAccess) {
        Write-CredSetupLog "Testing network share access..." "INFO"

        # Test basic connectivity
        try {
            $accessible = Test-Path $SharePath -ErrorAction Stop
            if ($accessible) {
                Write-CredSetupLog "Network share is accessible!" "SUCCESS"

                # Try to list contents
                try {
                    $contents = Get-ChildItem $SharePath -ErrorAction Stop | Select-Object -First 5
                    Write-CredSetupLog "Share contents (first 5 items):" "INFO"
                    $contents | ForEach-Object { Write-CredSetupLog "  $($_.Name)" "INFO" }
                }
                catch {
                    Write-CredSetupLog "Can access share but cannot list contents: $($_.Exception.Message)" "WARN"
                }
            } else {
                Write-CredSetupLog "Network share path exists but may need credentials" "WARN"
            }
        }
        catch {
            Write-CredSetupLog "Cannot access network share: $($_.Exception.Message)" "ERROR"
            Write-CredSetupLog "This might be normal - credentials may be used on first actual file access" "INFO"
        }
    }

    # Provide usage instructions
    Write-CredSetupLog "" "INFO"
    Write-CredSetupLog "=== Next Steps ===" "INFO"
    Write-CredSetupLog "1. Your credentials are now stored for VMTags network share access" "INFO"
    Write-CredSetupLog "2. Run your VMTags script normally - it will automatically use stored credentials" "INFO"
    Write-CredSetupLog "3. If you need to update credentials, run this script again" "INFO"
    Write-CredSetupLog "" "INFO"
    Write-CredSetupLog "Example VMTags command:" "INFO"
    Write-CredSetupLog "  .\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials" "INFO"

}
catch {
    Write-CredSetupLog "Failed to set up credentials: $($_.Exception.Message)" "ERROR"
    Write-CredSetupLog "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}

Write-CredSetupLog "=== Credential Setup Complete ===" "SUCCESS"