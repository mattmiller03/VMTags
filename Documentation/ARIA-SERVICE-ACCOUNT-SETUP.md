# Aria Operations Service Account Setup Guide

This guide explains how to configure service account credentials for VMTags automation in Aria Operations environments **without requiring interactive login** with the service account.

## 🎯 Problem Solved

**Before**: Had to interactively log in to PowerShell host as service account to create credential files
**After**: Deploy teams can configure service account credentials programmatically during deployment

## 🚀 Quick Start

### Step 1: Set Up Service Account Credentials

Run this **once during deployment** (as administrator):

```powershell
# Example for KLEB environment with encrypted environment variables
.\Set-AriaServiceCredentials.ps1 -Environment KLEB -Method EnvironmentVariables -ServiceAccountUser "svc-aria-vmtags@dla.mil" -ServiceAccountPassword (Read-Host -AsSecureString -Prompt "Service Account Password")
```

### Step 2: Test the Configuration

```powershell
# Test the service account credentials
.\Get-AriaServiceCredentials.ps1; Test-AriaServiceCredentials -Environment KLEB
```

### Step 3: Run VMTags as Normal

```powershell
# VMTags automation now works without interactive login
.\VM_TagPermissions_Launcher.ps1 -Environment KLEB -UseStoredCredentials
```

## 📋 Supported Methods

### Method 1: Environment Variables (Recommended)

**Best for**: Most environments, Docker containers, CI/CD pipelines

**Setup**:
```powershell
.\Set-AriaServiceCredentials.ps1 -Environment PROD -Method EnvironmentVariables -ServiceAccountUser "svc-vmtags@dla.mil" -ServiceAccountPassword $securePassword
```

**How it works**:
- Credentials encrypted with machine-specific key
- Stored in system environment variables
- Automatically decrypted during retrieval
- Survives reboots and user sessions

**Environment Variables Created**:
- `VMTAGS_PROD_VCENTER_USER` = [encrypted username]
- `VMTAGS_PROD_VCENTER_PASS` = [encrypted password]

### Method 2: Encrypted Files

**Best for**: Environments where environment variables aren't preferred

**Setup**:
```powershell
.\Set-AriaServiceCredentials.ps1 -Environment KLEB -Method EncryptedFile -ServiceAccountUser "svc-aria@dla.mil" -ServiceAccountPassword $securePassword
```

**How it works**:
- Credentials encrypted with machine-specific key
- Stored in `.\Credentials\ServiceAccounts\KLEB-ServiceAccount.json`
- File permissions restricted to current user
- Machine-bound encryption (won't work on different machines)

### Method 3: Windows Credential Manager (Limited)

**Best for**: Windows-specific environments with Credential Manager API access

**Setup**:
```powershell
.\Set-AriaServiceCredentials.ps1 -Environment DEV -Method CredentialManager -ServiceAccountUser "svc-test@dla.mil" -ServiceAccountPassword $securePassword
```

**Note**: Currently has limitations due to Credential Manager API restrictions. Use EnvironmentVariables or EncryptedFile instead.

## 🔧 Integration with VMTags

The launcher automatically detects Aria Operations execution and uses service account credentials:

### Aria Detection Criteria

The system detects Aria Operations when any of these environment variables are set:
- `ARIA_EXECUTION=1`
- `AUTOMATION_MODE=ARIA_OPERATIONS`
- `ARIA_NO_CREDENTIAL_INJECTION=1`
- `VRO_WORKFLOW_ID` (any value)
- `VRO_DEBUG=1` AND `ARIA_NO_CREDENTIAL_INJECTION=1`

### Credential Resolution Priority

1. **Aria Service Account** (when Aria execution detected)
2. **Regular Stored Credentials** (fallback)
3. **Interactive Prompt** (last resort, fails in automation)

### Example Workflow

```powershell
# When VMTags runs in Aria Operations:
.\VM_TagPermissions_Launcher.ps1 -Environment KLEB -UseStoredCredentials

# Log output:
# [INFO] Aria Operations execution detected via: ARIA_EXECUTION=1
# [INFO] Attempting to retrieve Aria service account credentials...
# [SUCCESS] Successfully retrieved Aria service account credentials for user: svc-aria-vmtags@dla.mil
# [INFO] Using Aria service account credentials for vCenter authentication
```

## 🔒 Security Features

### Machine-Specific Encryption
- Credentials encrypted using machine GUID + computer name
- Encrypted credentials won't work on different machines
- No shared secrets or passwords in configuration

### Access Control
- Environment variables stored at machine level (requires admin to set)
- Encrypted files have restrictive permissions (owner only)
- Credentials decrypted only in memory, never written to disk in plaintext

### Audit Trail
- All credential operations logged
- Failed attempts tracked and logged
- Service account usage clearly identified in logs

## 🧪 Testing and Validation

### Test Service Account Connectivity

```powershell
# Test specific environment
.\Get-AriaServiceCredentials.ps1; Test-AriaServiceCredentials -Environment KLEB

# Test with custom vCenter server
.\Get-AriaServiceCredentials.ps1; Test-AriaServiceCredentials -Environment PROD -VCenterServer "custom-vcenter.domain.com"
```

### Verify Credential Setup

```powershell
# Check which method is configured
$cred = Get-AriaServiceCredentials -Environment KLEB -Method Auto -Verbose

# Output will show detected method:
# VERBOSE: Auto-detected method: EnvironmentVariables
# VERBOSE: Retrieving credentials from environment variables
```

### Test VMTags Integration

```powershell
# Set Aria environment variable for testing
$env:ARIA_EXECUTION = "1"

# Run VMTags - should automatically use service account
.\VM_TagPermissions_Launcher.ps1 -Environment KLEB -UseStoredCredentials -ForceDebug
```

## 📖 Deployment Examples

### Example 1: Ansible Deployment

```yaml
- name: Configure VMTags service account for PROD
  win_shell: |
    $securePassword = ConvertTo-SecureString "{{ vault_service_account_password }}" -AsPlainText -Force
    .\Set-AriaServiceCredentials.ps1 -Environment PROD -Method EnvironmentVariables -ServiceAccountUser "{{ service_account_username }}" -ServiceAccountPassword $securePassword
  args:
    chdir: C:\VMTags-v2.0
```

### Example 2: PowerShell DSC

```powershell
Script SetVMTagsServiceAccount {
    GetScript = { @{ Result = "VMTags Service Account" } }
    TestScript = {
        $envVar = [System.Environment]::GetEnvironmentVariable("VMTAGS_PROD_VCENTER_USER", [System.EnvironmentVariableTarget]::Machine)
        return ($envVar -ne $null)
    }
    SetScript = {
        $securePassword = ConvertTo-SecureString $using:ServiceAccountPassword -AsPlainText -Force
        & "C:\VMTags-v2.0\Set-AriaServiceCredentials.ps1" -Environment PROD -Method EnvironmentVariables -ServiceAccountUser $using:ServiceAccountUser -ServiceAccountPassword $securePassword
    }
}
```

### Example 3: Docker Container

```dockerfile
# Set environment variables during container build
ENV VMTAGS_PROD_VCENTER_USER=encrypted_username_here
ENV VMTAGS_PROD_VCENTER_PASS=encrypted_password_here
ENV ARIA_EXECUTION=1
```

## 🔄 Migration from Interactive Method

### Current State Assessment

```powershell
# Check current credential files
Get-ChildItem ".\Credentials" -Recurse -Filter "*.credential"

# List current stored credentials
.\VM_TagPermissions_Launcher.ps1 -ListStoredCredentials
```

### Migration Steps

1. **Set up service account credentials**:
   ```powershell
   .\Set-AriaServiceCredentials.ps1 -Environment KLEB -Method EnvironmentVariables -ServiceAccountUser "svc-aria@dla.mil" -ServiceAccountPassword $password
   ```

2. **Test new method**:
   ```powershell
   $env:ARIA_EXECUTION = "1"
   .\VM_TagPermissions_Launcher.ps1 -Environment KLEB -UseStoredCredentials -DryRun
   ```

3. **Clean up old interactive credentials** (optional):
   ```powershell
   .\VM_TagPermissions_Launcher.ps1 -CleanupExpiredCredentials
   ```

## 🆘 Troubleshooting

### Issue: "No service account credentials found"

**Cause**: Service account credentials not properly configured

**Solution**:
```powershell
# Check if credentials exist
[System.Environment]::GetEnvironmentVariable("VMTAGS_KLEB_VCENTER_USER", [System.EnvironmentVariableTarget]::Machine)

# If null, run setup again:
.\Set-AriaServiceCredentials.ps1 -Environment KLEB -Method EnvironmentVariables -ServiceAccountUser "your-service-account" -ServiceAccountPassword $password
```

### Issue: "Failed to decrypt string"

**Cause**: Credentials were encrypted on a different machine

**Solution**: Re-run setup on the target machine:
```powershell
.\Set-AriaServiceCredentials.ps1 -Environment KLEB -Method EnvironmentVariables -ServiceAccountUser "service-account" -ServiceAccountPassword $password
```

### Issue: vCenter authentication fails

**Cause**: Service account credentials invalid or insufficient permissions

**Solution**:
```powershell
# Test credentials manually
.\Get-AriaServiceCredentials.ps1; Test-AriaServiceCredentials -Environment KLEB

# If fails, verify service account has proper vCenter permissions
```

### Issue: Script still prompts for credentials

**Cause**: Aria Operations environment not properly detected

**Solution**: Ensure environment variables are set:
```powershell
$env:ARIA_EXECUTION = "1"
$env:AUTOMATION_MODE = "ARIA_OPERATIONS"
```

## 📚 Additional Resources

- **Configuration**: See `VMTagsConfig.psd1` for environment-specific settings
- **Logging**: Enable debug logging with `-ForceDebug` for detailed troubleshooting
- **Security**: Review `Security` section in configuration for policy settings
- **Testing**: Use `Test-AriaServiceCredentials` for comprehensive validation

---

**✅ Result**: Aria Operations can now run VMTags automation with service account credentials without requiring interactive login on the PowerShell host!