<#
.SYNOPSIS
    Sets up service account credentials for Aria Operations integration without interactive login

.DESCRIPTION
    This utility script allows deployment teams to configure service account credentials
    for VMTags automation in Aria Operations environments without requiring interactive
    login with the service account.

    Supports multiple credential storage methods:
    1. Encrypted environment variables
    2. Windows Credential Manager
    3. Encrypted files with machine-specific keys

.PARAMETER Environment
    Target environment (DEV, PROD, KLEB, OT)

.PARAMETER Method
    Credential storage method to use

.PARAMETER ServiceAccountUser
    Service account username (e.g., svc-aria-vmtags@domain.com)

.PARAMETER ServiceAccountPassword
    Service account password (will be encrypted)

.PARAMETER VaultName
    For external vault integration (future enhancement)

.EXAMPLE
    # Set up encrypted environment variables for KLEB
    .\Set-AriaServiceCredentials.ps1 -Environment KLEB -Method EnvironmentVariables -ServiceAccountUser "svc-vmtags@dla.mil" -ServiceAccountPassword "SecurePass123"

.EXAMPLE
    # Set up Windows Credential Manager entry
    .\Set-AriaServiceCredentials.ps1 -Environment PROD -Method CredentialManager -ServiceAccountUser "svc-aria@dla.mil" -ServiceAccountPassword "SecurePass456"

.EXAMPLE
    # Set up encrypted file with machine key
    .\Set-AriaServiceCredentials.ps1 -Environment DEV -Method EncryptedFile -ServiceAccountUser "svc-test@dla.mil" -ServiceAccountPassword "TestPass789"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = $true)]
    [ValidateSet('EnvironmentVariables', 'CredentialManager', 'EncryptedFile')]
    [string]$Method,

    [Parameter(Mandatory = $true)]
    [string]$ServiceAccountUser,

    [Parameter(Mandatory = $true)]
    [SecureString]$ServiceAccountPassword,

    [Parameter(Mandatory = $false)]
    [switch]$TestCredentials
)

#region Helper Functions
function Write-AriaSetupLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-MachineKey {
    # Generate a machine-specific encryption key
    $machineGuid = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid).MachineGuid
    $machineName = $env:COMPUTERNAME
    $keyString = "$machineGuid-$machineName-VMTags"

    # Convert to secure key
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $keyBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($keyString))
    $sha256.Dispose()

    return $keyBytes
}

function Encrypt-StringWithMachineKey {
    param([string]$PlainText)

    $machineKey = Get-MachineKey
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)

    $aes = [System.Security.Cryptography.AesManaged]::new()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Key = $machineKey
    $aes.GenerateIV()

    $encryptor = $aes.CreateEncryptor()
    $encryptedBytes = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)

    # Combine IV and encrypted data
    $result = $aes.IV + $encryptedBytes
    $encryptedString = [System.Convert]::ToBase64String($result)

    $aes.Dispose()
    return $encryptedString
}
#endregion

Write-AriaSetupLog "Starting Aria Operations service account credential setup" "INFO"
Write-AriaSetupLog "Environment: $Environment" "INFO"
Write-AriaSetupLog "Method: $Method" "INFO"
Write-AriaSetupLog "Service Account: $ServiceAccountUser" "INFO"

try {
    # Convert SecureString to plain text for processing
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServiceAccountPassword)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

    switch ($Method) {
        "EnvironmentVariables" {
            Write-AriaSetupLog "Setting up encrypted environment variables..." "INFO"

            # Encrypt credentials with machine-specific key
            $encryptedUser = Encrypt-StringWithMachineKey -PlainText $ServiceAccountUser
            $encryptedPassword = Encrypt-StringWithMachineKey -PlainText $plainPassword

            # Set system environment variables
            $envVarUser = "VMTAGS_${Environment}_VCENTER_USER"
            $envVarPass = "VMTAGS_${Environment}_VCENTER_PASS"

            [System.Environment]::SetEnvironmentVariable($envVarUser, $encryptedUser, [System.EnvironmentVariableTarget]::Machine)
            [System.Environment]::SetEnvironmentVariable($envVarPass, $encryptedPassword, [System.EnvironmentVariableTarget]::Machine)

            Write-AriaSetupLog "Environment variables set:" "SUCCESS"
            Write-AriaSetupLog "  $envVarUser = [ENCRYPTED]" "INFO"
            Write-AriaSetupLog "  $envVarPass = [ENCRYPTED]" "INFO"
        }

        "CredentialManager" {
            Write-AriaSetupLog "Setting up Windows Credential Manager entry..." "INFO"

            $targetName = "VMTags-$Environment-vCenter"

            # Use cmdkey to store credentials
            $cmdkeyArgs = @("/add:$targetName", "/user:$ServiceAccountUser", "/pass:$plainPassword")
            $result = Start-Process -FilePath "cmdkey.exe" -ArgumentList $cmdkeyArgs -Wait -NoNewWindow -PassThru

            if ($result.ExitCode -eq 0) {
                Write-AriaSetupLog "Credential Manager entry created: $targetName" "SUCCESS"
            } else {
                throw "Failed to create Credential Manager entry. Exit code: $($result.ExitCode)"
            }
        }

        "EncryptedFile" {
            Write-AriaSetupLog "Setting up encrypted credential file..." "INFO"

            $credentialFolder = ".\Credentials\ServiceAccounts"
            if (-not (Test-Path $credentialFolder)) {
                New-Item -Path $credentialFolder -ItemType Directory -Force | Out-Null
                Write-AriaSetupLog "Created credential directory: $credentialFolder" "INFO"
            }

            $encryptedUser = Encrypt-StringWithMachineKey -PlainText $ServiceAccountUser
            $encryptedPassword = Encrypt-StringWithMachineKey -PlainText $plainPassword

            $credentialData = @{
                Environment = $Environment
                Username = $encryptedUser
                Password = $encryptedPassword
                Created = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Machine = $env:COMPUTERNAME
                Method = "MachineKeyEncryption"
            }

            $credentialFile = Join-Path $credentialFolder "$Environment-ServiceAccount.json"
            $credentialData | ConvertTo-Json -Depth 10 | Set-Content -Path $credentialFile -Encoding UTF8

            # Set restrictive permissions on the file
            $acl = Get-Acl $credentialFile
            $acl.SetAccessRuleProtection($true, $false)  # Remove inheritance
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $env:USERNAME, "FullControl", "Allow"
            )
            $acl.AddAccessRule($accessRule)
            $acl | Set-Acl $credentialFile

            Write-AriaSetupLog "Encrypted credential file created: $credentialFile" "SUCCESS"
        }
    }

    # Test credentials if requested
    if ($TestCredentials) {
        Write-AriaSetupLog "Testing service account credentials..." "INFO"

        # Load configuration to get vCenter server
        $configPath = ".\ConfigFiles\VMTagsConfig.psd1"
        if (Test-Path $configPath) {
            $config = Import-PowerShellDataFile $configPath
            $vCenterServer = $config.Environments.$Environment.vCenterServer

            if ($vCenterServer) {
                try {
                    # Test connection
                    Import-Module VMware.PowerCLI -Force -ErrorAction SilentlyContinue
                    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

                    $testCred = New-Object System.Management.Automation.PSCredential($ServiceAccountUser, $ServiceAccountPassword)
                    $connection = Connect-VIServer -Server $vCenterServer -Credential $testCred -ErrorAction Stop

                    Write-AriaSetupLog "✓ Successfully connected to vCenter: $($connection.Name)" "SUCCESS"
                    Write-AriaSetupLog "✓ Service account authentication verified" "SUCCESS"

                    Disconnect-VIServer -Server $connection -Confirm:$false -Force
                } catch {
                    Write-AriaSetupLog "✗ Failed to connect to vCenter: $_" "ERROR"
                    throw "Service account credential test failed"
                }
            } else {
                Write-AriaSetupLog "Could not determine vCenter server for testing" "WARNING"
            }
        }
    }

    Write-AriaSetupLog "Aria Operations service account setup completed successfully!" "SUCCESS"
    Write-AriaSetupLog "The VMTags automation script can now retrieve service account credentials without interactive login." "INFO"

} catch {
    Write-AriaSetupLog "Error during credential setup: $_" "ERROR"
    exit 1
} finally {
    # Clear sensitive data from memory
    if ($plainPassword) {
        $plainPassword = $null
    }
}