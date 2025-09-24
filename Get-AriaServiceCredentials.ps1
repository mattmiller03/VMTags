<#
.SYNOPSIS
    Retrieves service account credentials for Aria Operations integration

.DESCRIPTION
    This module provides functions to retrieve service account credentials
    that were set up using Set-AriaServiceCredentials.ps1, eliminating the
    need for interactive login with service accounts.

.PARAMETER Environment
    Target environment (DEV, PROD, KLEB, OT)

.PARAMETER Method
    Credential retrieval method to use

.EXAMPLE
    $cred = Get-AriaServiceCredentials -Environment KLEB -Method EnvironmentVariables
#>

function Decrypt-StringWithMachineKey {
    param([string]$EncryptedString)

    if ([string]::IsNullOrEmpty($EncryptedString)) {
        throw "Encrypted string is null or empty"
    }

    try {
        # Get the same machine key used for encryption
        $machineGuid = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid).MachineGuid
        $machineName = $env:COMPUTERNAME
        $keyString = "$machineGuid-$machineName-VMTags"

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $keyBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($keyString))
        $sha256.Dispose()

        # Decode base64
        $encryptedBytes = [System.Convert]::FromBase64String($EncryptedString)

        # Extract IV (first 16 bytes) and encrypted data
        $iv = $encryptedBytes[0..15]
        $encrypted = $encryptedBytes[16..($encryptedBytes.Length - 1)]

        $aes = [System.Security.Cryptography.AesManaged]::new()
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Key = $keyBytes
        $aes.IV = $iv

        $decryptor = $aes.CreateDecryptor()
        $decryptedBytes = $decryptor.TransformFinalBlock($encrypted, 0, $encrypted.Length)

        $plainText = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        $aes.Dispose()

        return $plainText
    } catch {
        throw "Failed to decrypt string: $_"
    }
}

function Get-AriaServiceCredentials {
    <#
    .SYNOPSIS
        Retrieves service account credentials for Aria Operations

    .PARAMETER Environment
        Target environment

    .PARAMETER Method
        Credential retrieval method (auto-detects if not specified)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
        [string]$Environment,

        [Parameter(Mandatory = $false)]
        [ValidateSet('EnvironmentVariables', 'CredentialManager', 'EncryptedFile', 'Auto')]
        [string]$Method = 'Auto'
    )

    Write-Verbose "Retrieving Aria service account credentials for environment: $Environment"

    # Auto-detect available credential methods
    if ($Method -eq 'Auto') {
        # Check environment variables first
        $envVarUser = "VMTAGS_${Environment}_VCENTER_USER"
        if ([System.Environment]::GetEnvironmentVariable($envVarUser, [System.EnvironmentVariableTarget]::Machine)) {
            $Method = 'EnvironmentVariables'
            Write-Verbose "Auto-detected method: EnvironmentVariables"
        }
        # Check encrypted file
        elseif (Test-Path ".\Credentials\ServiceAccounts\$Environment-ServiceAccount.json") {
            $Method = 'EncryptedFile'
            Write-Verbose "Auto-detected method: EncryptedFile"
        }
        # Check credential manager
        else {
            $targetName = "VMTags-$Environment-vCenter"
            $cmdResult = cmd /c "cmdkey /list:$targetName" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $Method = 'CredentialManager'
                Write-Verbose "Auto-detected method: CredentialManager"
            } else {
                throw "No service account credentials found for environment '$Environment'. Please run Set-AriaServiceCredentials.ps1 first."
            }
        }
    }

    try {
        switch ($Method) {
            'EnvironmentVariables' {
                Write-Verbose "Retrieving credentials from environment variables"

                $envVarUser = "VMTAGS_${Environment}_VCENTER_USER"
                $envVarPass = "VMTAGS_${Environment}_VCENTER_PASS"

                $encryptedUser = [System.Environment]::GetEnvironmentVariable($envVarUser, [System.EnvironmentVariableTarget]::Machine)
                $encryptedPassword = [System.Environment]::GetEnvironmentVariable($envVarPass, [System.EnvironmentVariableTarget]::Machine)

                if (-not $encryptedUser -or -not $encryptedPassword) {
                    throw "Environment variables not found for $Environment. Expected: $envVarUser, $envVarPass"
                }

                $username = Decrypt-StringWithMachineKey -EncryptedString $encryptedUser
                $plaintextPassword = Decrypt-StringWithMachineKey -EncryptedString $encryptedPassword

                $securePassword = ConvertTo-SecureString -String $plaintextPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)

                # Clear plaintext password from memory
                $plaintextPassword = $null

                return $credential
            }

            'CredentialManager' {
                Write-Verbose "Retrieving credentials from Windows Credential Manager"

                $targetName = "VMTags-$Environment-vCenter"

                # Use PowerShell to retrieve stored credential
                try {
                    # Try using Windows API via PowerShell
                    Add-Type -AssemblyName System.Web
                    $cred = [System.Web.Security.Membership]::GeneratePassword(1,0) # Dummy call to load assembly

                    # Use cmdkey to list and parse the credential
                    $cmdResult = cmd /c "cmdkey /list:$targetName" 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Credential not found in Credential Manager: $targetName"
                    }

                    # Extract username from cmdkey output
                    $username = ($cmdResult | Where-Object { $_ -match "User:" }).Split(':')[1].Trim()

                    if (-not $username) {
                        throw "Could not extract username from Credential Manager"
                    }

                    # For security, we cannot retrieve the actual password from Credential Manager via cmdkey
                    # This method requires the credential to be accessible to the current user context
                    throw "Credential Manager method requires integration with Windows Credential Management APIs. Please use EnvironmentVariables or EncryptedFile methods instead."

                } catch {
                    throw "Failed to retrieve credential from Credential Manager: $_"
                }
            }

            'EncryptedFile' {
                Write-Verbose "Retrieving credentials from encrypted file"

                $credentialFile = ".\Credentials\ServiceAccounts\$Environment-ServiceAccount.json"

                if (-not (Test-Path $credentialFile)) {
                    throw "Encrypted credential file not found: $credentialFile"
                }

                $credentialData = Get-Content -Path $credentialFile -Raw | ConvertFrom-Json

                if ($credentialData.Environment -ne $Environment) {
                    throw "Credential file environment mismatch. Expected: $Environment, Found: $($credentialData.Environment)"
                }

                $username = Decrypt-StringWithMachineKey -EncryptedString $credentialData.Username
                $plaintextPassword = Decrypt-StringWithMachineKey -EncryptedString $credentialData.Password

                $securePassword = ConvertTo-SecureString -String $plaintextPassword -AsPlainText -Force
                $credential = New-Object System.Management.Automation.PSCredential($username, $securePassword)

                # Clear plaintext password from memory
                $plaintextPassword = $null

                Write-Verbose "Successfully retrieved service account credential from encrypted file"
                return $credential
            }

            default {
                throw "Unknown credential method: $Method"
            }
        }
    } catch {
        Write-Error "Failed to retrieve Aria service account credentials: $_"
        throw
    }
}

function Test-AriaServiceCredentials {
    <#
    .SYNOPSIS
        Tests service account credentials against vCenter

    .PARAMETER Environment
        Target environment to test

    .PARAMETER VCenterServer
        Optional vCenter server override
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $false)]
        [string]$VCenterServer
    )

    try {
        Write-Host "Testing Aria service account credentials for $Environment..." -ForegroundColor Cyan

        # Get service account credentials
        $credential = Get-AriaServiceCredentials -Environment $Environment

        # Load vCenter server if not provided
        if (-not $VCenterServer) {
            $configPath = ".\ConfigFiles\VMTagsConfig.psd1"
            if (Test-Path $configPath) {
                $config = Import-PowerShellDataFile $configPath
                $VCenterServer = $config.Environments.$Environment.vCenterServer
            }

            if (-not $VCenterServer) {
                throw "Could not determine vCenter server for environment $Environment"
            }
        }

        # Test connection
        Import-Module VMware.PowerCLI -Force -ErrorAction SilentlyContinue
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

        Write-Host "Connecting to vCenter: $VCenterServer" -ForegroundColor Yellow
        $connection = Connect-VIServer -Server $VCenterServer -Credential $credential -ErrorAction Stop

        Write-Host "✓ Successfully authenticated with service account: $($credential.UserName)" -ForegroundColor Green
        Write-Host "✓ Connected to vCenter: $($connection.Name) (Version: $($connection.Version))" -ForegroundColor Green

        # Test basic permissions
        $vmCount = @(Get-VM -ErrorAction SilentlyContinue).Count
        Write-Host "✓ Service account can query VMs: $vmCount VMs found" -ForegroundColor Green

        $tagCount = @(Get-Tag -ErrorAction SilentlyContinue).Count
        Write-Host "✓ Service account can query tags: $tagCount tags found" -ForegroundColor Green

        Disconnect-VIServer -Server $connection -Confirm:$false -Force

        Write-Host "✓ Service account credentials are valid and functional!" -ForegroundColor Green
        return $true

    } catch {
        Write-Host "✗ Service account credential test failed: $_" -ForegroundColor Red
        return $false
    }
}

# Functions are available when script is dot-sourced