# Windows Credential Manager Integration for VMTags
<#
.SYNOPSIS
    Retrieves stored credentials from Windows Credential Manager

.DESCRIPTION
    This script provides integration with Windows Credential Manager to securely
    retrieve stored credentials for network share access and other authentication needs.

.PARAMETER Target
    The target name/key for the stored credential in Credential Manager

.PARAMETER Type
    The type of credential (Generic, DomainPassword, DomainCertificate, DomainVisiblePassword)
    Default: Generic

.EXAMPLE
    $cred = Get-StoredCredential -Target "VMTags-FileServer"

.EXAMPLE
    $cred = Get-StoredCredential -Target "VMTags-vCenter-PROD" -Type DomainPassword
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Target name for the stored credential")]
    [string]$Target,

    [Parameter(Mandatory = $false, HelpMessage = "Credential type")]
    [ValidateSet('Generic', 'DomainPassword', 'DomainCertificate', 'DomainVisiblePassword')]
    [string]$Type = "Generic"
)

function Write-CredentialLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] [CredentialManager] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN"  { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage -ForegroundColor White }
    }
}

# Check if CredentialManager module is available
$credManagerAvailable = $false
try {
    if (Get-Module -ListAvailable -Name CredentialManager) {
        Import-Module CredentialManager -ErrorAction Stop
        $credManagerAvailable = $true
        Write-CredentialLog "CredentialManager module loaded successfully" "SUCCESS"
    }
}
catch {
    Write-CredentialLog "CredentialManager module not available, using fallback method" "WARN"
}

if ($credManagerAvailable) {
    # Use CredentialManager module
    try {
        Write-CredentialLog "Retrieving credential for target: $Target" "INFO"
        $credential = Get-StoredCredential -Target $Target -Type $Type -ErrorAction Stop

        if ($credential) {
            Write-CredentialLog "Successfully retrieved credential for user: $($credential.UserName)" "SUCCESS"
            return $credential
        } else {
            throw "No credential found for target: $Target"
        }
    }
    catch {
        Write-CredentialLog "Failed to retrieve credential: $($_.Exception.Message)" "ERROR"
        throw
    }
} else {
    # Fallback to native Windows API calls
    Write-CredentialLog "Using native Windows API for credential retrieval" "INFO"

    try {
        # Define Windows API structures and functions
        Add-Type -TypeDefinition @"
            using System;
            using System.Runtime.InteropServices;
            using System.Text;

            public class CredentialManager
            {
                [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
                public struct CREDENTIAL
                {
                    public UInt32 Flags;
                    public UInt32 Type;
                    [MarshalAs(UnmanagedType.LPWStr)]
                    public string TargetName;
                    [MarshalAs(UnmanagedType.LPWStr)]
                    public string Comment;
                    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
                    public UInt32 CredentialBlobSize;
                    public IntPtr CredentialBlob;
                    public UInt32 Persist;
                    public UInt32 AttributeCount;
                    public IntPtr Attributes;
                    [MarshalAs(UnmanagedType.LPWStr)]
                    public string TargetAlias;
                    [MarshalAs(UnmanagedType.LPWStr)]
                    public string UserName;
                }

                [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
                public static extern bool CredRead(string target, UInt32 type, UInt32 reservedFlag, out IntPtr CredentialPtr);

                [DllImport("Advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
                public static extern bool CredFree(IntPtr cred);

                public static CREDENTIAL? GetCredential(string target, UInt32 type)
                {
                    IntPtr credPtr;
                    if (CredRead(target, type, 0, out credPtr))
                    {
                        var credential = Marshal.PtrToStructure<CREDENTIAL>(credPtr);
                        CredFree(credPtr);
                        return credential;
                    }
                    return null;
                }
            }
"@

        # Convert credential type to numeric value
        $typeValue = switch ($Type) {
            'Generic' { 1 }
            'DomainPassword' { 2 }
            'DomainCertificate' { 3 }
            'DomainVisiblePassword' { 4 }
            default { 1 }
        }

        # Retrieve credential from Windows Credential Manager
        $cred = [CredentialManager]::GetCredential($Target, $typeValue)

        if ($cred) {
            # Convert password from IntPtr to SecureString
            $passwordBytes = New-Object byte[] $cred.CredentialBlobSize
            [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $passwordBytes, 0, $cred.CredentialBlobSize)
            $passwordString = [System.Text.Encoding]::Unicode.GetString($passwordBytes)
            $securePassword = ConvertTo-SecureString -String $passwordString -AsPlainText -Force

            # Create PSCredential object
            $psCredential = New-Object System.Management.Automation.PSCredential($cred.UserName, $securePassword)

            Write-CredentialLog "Successfully retrieved credential for user: $($cred.UserName)" "SUCCESS"
            return $psCredential
        } else {
            throw "No credential found for target: $Target"
        }
    }
    catch {
        Write-CredentialLog "Failed to retrieve credential using native API: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# If we get here, something went wrong
throw "Unable to retrieve credential for target: $Target"