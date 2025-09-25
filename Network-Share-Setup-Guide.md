# VMTags Network Share Configuration Guide

This document provides comprehensive instructions for setting up centralized CSV file management using network shares for VMTags automation.

## 🎯 Overview

The network share functionality allows you to store VMTags CSV configuration files (App Permissions and OS Mappings) on a central network location, enabling:

- **Centralized Management**: Single source of truth for all environment configurations
- **Automated Synchronization**: Scripts automatically pull latest CSV files from network share
- **Local Fallback**: Seamless fallback to local files when network is unavailable
- **Caching**: Local caching for improved performance and offline capability
- **Security**: Integration with Windows Credential Manager for secure authentication

## 📋 Architecture

```
Central File Server (\\fileserver\VMTags\Config\)
├── DEV\
│   ├── AppTagPermissions_DEV.csv
│   └── OS-Mappings_DEV.csv
├── PROD\
│   ├── App-Permissions-PROD.csv
│   └── OS-Mappings-PROD.csv
├── KLEB\
│   ├── AppTagPermissions_KLE.csv
│   └── OS-Mappings_KLE.csv
└── OT\
    ├── App-Permissions-OT.csv
    └── OS-Mappings-OT.csv

VMTags Execution Hosts
├── Local Cache (%TEMP%\VMTags_NetworkShare_Cache\)
├── Local Fallback (.\Data\[ENV]\)
└── Scripts\ (Network share functionality)
```

## 🛠 Prerequisites

### Network Infrastructure
- **File Server**: Windows Server with SMB/CIFS file sharing enabled
- **Network Connectivity**: All VMTags execution hosts must have network access to file server
- **DNS Resolution**: File server must be resolvable by FQDN or NetBIOS name
- **Firewall Rules**: SMB ports (445/TCP, 139/TCP) open between hosts and file server

### Security Requirements
- **Service Account**: Dedicated service account for VMTags file access
- **Share Permissions**: Read access to network share for VMTags service account
- **NTFS Permissions**: Read access to CSV files and directories
- **Credential Management**: Windows Credential Manager or alternative secure storage

### PowerShell Requirements
- **PowerShell 5.1+** on all VMTags execution hosts
- **CredentialManager Module** (optional but recommended)
  ```powershell
  Install-Module -Name CredentialManager -Scope AllUsers
  ```

## 📁 File Server Setup

### Step 1: Create Directory Structure

On your file server, create the VMTags directory structure:

```powershell
# On file server
$vmTagsRoot = "D:\Shares\VMTags\Config"
$environments = @("DEV", "PROD", "KLEB", "OT")

foreach ($env in $environments) {
    $envPath = Join-Path $vmTagsRoot $env
    New-Item -ItemType Directory -Path $envPath -Force
    Write-Host "Created: $envPath"
}
```

### Step 2: Configure SMB Share

Create the network share with appropriate permissions:

```powershell
# Create SMB share
New-SmbShare -Name "VMTags" -Path "D:\Shares\VMTags" -Description "VMTags Centralized Configuration Files"

# Set share permissions (adjust security group as needed)
Grant-SmbShareAccess -Name "VMTags" -AccountName "DOMAIN\VMTags-Service" -AccessRight Read -Force
Grant-SmbShareAccess -Name "VMTags" -AccountName "DOMAIN\VMTags-Admins" -AccessRight Full -Force

# Remove default permissions
Revoke-SmbShareAccess -Name "VMTags" -AccountName "Everyone" -Force
```

### Step 3: Set NTFS Permissions

Configure file system permissions:

```powershell
# Set NTFS permissions
$vmTagsPath = "D:\Shares\VMTags"
$acl = Get-Acl $vmTagsPath

# Add VMTags service account with Read access
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("DOMAIN\VMTags-Service", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($accessRule)

# Add VMTags admins with Full Control
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("DOMAIN\VMTags-Admins", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($adminRule)

Set-Acl -Path $vmTagsPath -AclObject $acl
```

### Step 4: Deploy CSV Files

Copy your environment-specific CSV files to the appropriate directories:

```
\\fileserver\VMTags\Config\
├── DEV\
│   ├── AppTagPermissions_DEV.csv
│   └── OS-Mappings_DEV.csv
├── PROD\
│   ├── App-Permissions-PROD.csv
│   └── OS-Mappings-PROD.csv
├── KLEB\
│   ├── AppTagPermissions_KLE.csv
│   └── OS-Mappings_KLE.csv
└── OT\
    ├── App-Permissions-OT.csv
    └── OS-Mappings-OT.csv
```

## 🔐 Credential Configuration

### Option 1: Windows Credential Manager (Recommended)

Store network share credentials securely in Windows Credential Manager on each VMTags execution host:

```powershell
# On each VMTags execution host
cmdkey /add:fileserver /user:DOMAIN\VMTags-Service /pass:YourSecurePassword

# Or using PowerShell with CredentialManager module
$credential = Get-Credential -UserName "DOMAIN\VMTags-Service" -Message "Enter VMTags service account password"
New-StoredCredential -Target "VMTags-FileServer" -UserName $credential.UserName -Password $credential.Password -Type Generic
```

### Option 2: Group Managed Service Account (GMSA)

For enhanced security in domain environments:

```powershell
# Create GMSA (on domain controller)
New-ADServiceAccount -Name "VMTags-GMSA" -DNSHostName "vmtags-gmsa.domain.local" -PrincipalsAllowedToRetrieveManagedPassword "VMTags-Servers"

# Install on VMTags execution hosts
Install-ADServiceAccount -Identity "VMTags-GMSA"

# Configure VMTags to run under GMSA context
```

## ⚙️ VMTags Configuration

### Step 1: Update Configuration File

Modify `ConfigFiles\VMTagsConfig.psd1` for each environment:

```powershell
# Example for PROD environment
PROD = @{
    # ... existing configuration ...

    DataPaths = @{
        AppPermissionsCSV   = ".\Data\PROD\App-Permissions-PROD.csv"
        OSMappingCSV        = ".\Data\PROD\OS-Mappings-PROD.csv"
        LogDirectory        = ".\Logs\PROD"
        BackupDirectory     = ".\Backup\PROD"

        # Network share configuration
        NetworkSharePath            = "\\fileserver\VMTags\Config\PROD"
        NetworkShareCredentialName  = "VMTags-FileServer"  # Name in Credential Manager
        EnableNetworkShare          = $true                # Enable network share
        CacheNetworkFiles           = $true                # Enable local caching
        CacheExpiryHours           = 2                     # Cache expiry (shorter for PROD)
    }
}
```

### Step 2: Configure Per Environment

**DEV Environment** (Development/Testing):
```powershell
EnableNetworkShare = $false    # Optional for dev
CacheExpiryHours = 4          # Longer cache for development
```

**PROD Environment** (Production):
```powershell
EnableNetworkShare = $true     # Always use network share
CacheExpiryHours = 2          # Shorter cache for latest updates
```

**KLEB Environment** (Balanced):
```powershell
EnableNetworkShare = $true     # Use network share
CacheExpiryHours = 3          # Balanced cache duration
```

**OT Environment** (High Security):
```powershell
EnableNetworkShare = $false    # Local files only for security
CacheNetworkFiles = $false    # No caching for security
```

## 🧪 Testing Configuration

### Step 1: Test Network Connectivity

```powershell
# Test basic connectivity to file server
Test-NetConnection -ComputerName "fileserver" -Port 445

# Test SMB share access
Test-Path "\\fileserver\VMTags\Config"

# List available files
Get-ChildItem "\\fileserver\VMTags\Config\PROD"
```

### Step 2: Test Credential Access

```powershell
# Test credential retrieval
.\Scripts\Get-StoredCredential.ps1 -Target "VMTags-FileServer"

# Test with explicit credentials
$cred = Get-Credential
Test-Path "\\fileserver\VMTags\Config\PROD" -Credential $cred
```

### Step 3: Run Network Share Tests

Use the provided test script to validate configuration:

```powershell
# Test all functionality for PROD environment
.\Test-NetworkShare.ps1 -Environment PROD

# Test specific components
.\Test-NetworkShare.ps1 -Environment PROD -TestConnectivity
.\Test-NetworkShare.ps1 -Environment PROD -TestCredentials
.\Test-NetworkShare.ps1 -Environment PROD -TestCaching

# Force refresh from network (bypass cache)
.\Test-NetworkShare.ps1 -Environment PROD -ForceRefresh
```

### Step 4: Validate CSV Retrieval

Test the main script with network share functionality:

```powershell
# Test with network share enabled
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials -ForceDebug

# Check logs for network share activity
Get-Content ".\Logs\PROD\VM_TagPermissions_*.log" | Select-String "Network"
```

## 🔄 Operational Procedures

### Daily Operations

**CSV File Updates:**
1. Update CSV files on central file server
2. VMTags scripts automatically detect and use updated files
3. Local cache refreshes based on expiry settings
4. No changes needed on execution hosts

**Monitoring:**
- Check VMTags logs for network share access status
- Monitor file server SMB logs for access patterns
- Validate cache performance and hit rates

### Maintenance

**Cache Management:**
```powershell
# Clear all cached files (forces refresh)
Remove-Item "$env:TEMP\VMTags_NetworkShare_Cache" -Recurse -Force

# Check cache usage
Get-ChildItem "$env:TEMP\VMTags_NetworkShare_Cache" -Recurse | Measure-Object -Property Length -Sum
```

**Credential Updates:**
```powershell
# Update stored credentials
Remove-StoredCredential -Target "VMTags-FileServer"
$newCred = Get-Credential -UserName "DOMAIN\VMTags-Service"
New-StoredCredential -Target "VMTags-FileServer" -UserName $newCred.UserName -Password $newCred.Password -Type Generic
```

## 🚨 Troubleshooting

### Common Issues

**Issue 1: "Network share not accessible"**
```
Symptoms: Scripts fall back to local files
Causes: Network connectivity, DNS resolution, firewall
Solutions:
1. Test-NetConnection -ComputerName fileserver -Port 445
2. nslookup fileserver
3. Check firewall rules for SMB traffic
```

**Issue 2: "Access is denied to network share"**
```
Symptoms: Authentication failures in logs
Causes: Incorrect credentials, expired passwords, permission issues
Solutions:
1. Verify credentials: .\Scripts\Get-StoredCredential.ps1 -Target "VMTags-FileServer"
2. Test manual access: net use \\fileserver\VMTags /user:DOMAIN\VMTags-Service
3. Check share and NTFS permissions
```

**Issue 3: "CSV files are outdated"**
```
Symptoms: Scripts use old cached files
Causes: Caching issues, clock synchronization
Solutions:
1. Force refresh: .\Test-NetworkShare.ps1 -Environment PROD -ForceRefresh
2. Clear cache: Remove-Item "$env:TEMP\VMTags_NetworkShare_Cache" -Recurse
3. Check time synchronization between hosts
```

**Issue 4: "Credential retrieval fails"**
```
Symptoms: Scripts prompt for credentials
Causes: Missing or corrupted stored credentials
Solutions:
1. Re-create credentials: cmdkey /add:fileserver /user:DOMAIN\VMTags-Service
2. Test credential access: cmdkey /list | findstr fileserver
3. Use alternative authentication method
```

### Debug Mode

Enable detailed logging for troubleshooting:

```powershell
# Run with debug logging
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials -ForceDebug

# Check network share specific logs
Get-Content ".\Logs\PROD\VM_TagPermissions_*.log" | Select-String -Pattern "Network|Share|Cache"
```

### Log Analysis

**Network Share Success:**
```
[INFO ] [NetworkShare] Network share enabled for environment: PROD
[SUCCESS] [NetworkShare] Successfully copied file from network share
[SUCCESS] Loaded App Permissions CSV from Network: 150 rows
[SUCCESS] Loaded OS Mapping CSV from Cache: 75 rows
```

**Network Share Failure:**
```
[WARN ] [NetworkShare] Network share access test failed
[WARN ] Network share loading failed, falling back to local file
[INFO ] Loaded App Permissions CSV from local file: 150 rows
```

## 📊 Performance Considerations

### Caching Strategy

**Environment-Specific Cache Settings:**
- **DEV**: 4 hours (longer for stability during development)
- **PROD**: 2 hours (shorter for faster updates)
- **KLEB**: 3 hours (balanced approach)
- **OT**: 1 hour or disabled (security preference)

### Network Optimization

**File Size Management:**
- Keep CSV files optimized (remove unnecessary columns)
- Use compression if supported by file server
- Monitor network bandwidth usage during peak operations

**Connection Pooling:**
- Share credentials across multiple CSV retrievals
- Reuse network connections where possible
- Implement connection timeouts for reliability

## 🔐 Security Best Practices

### Access Control
- Use least privilege principle for service accounts
- Regular audit of share permissions and access logs
- Implement network segmentation where appropriate

### Credential Management
- Rotate service account passwords regularly
- Use Group Managed Service Accounts where possible
- Monitor credential usage and access patterns

### Monitoring
- Enable SMB audit logging on file server
- Monitor failed authentication attempts
- Set up alerts for unusual access patterns

## 📈 Advanced Configuration

### Multiple File Servers

For redundancy, configure multiple file servers:

```powershell
DataPaths = @{
    # Primary network share
    NetworkSharePath = "\\fileserver1\VMTags\Config\PROD"

    # Fallback network shares
    NetworkShareFallbacks = @(
        "\\fileserver2\VMTags\Config\PROD"
        "\\fileserver3\VMTags\Config\PROD"
    )

    EnableNetworkShare = $true
    CacheNetworkFiles = $true
}
```

### Environment-Specific Shares

Use different shares per environment for isolation:

```powershell
# PROD environment
NetworkSharePath = "\\fileserver-prod\VMTags\Config"

# DEV environment
NetworkSharePath = "\\fileserver-dev\VMTags\Config"
```

### Automated CSV Deployment

Set up automated deployment from version control:

```powershell
# Example deployment script
$sourceRepo = "\\git-server\VMTags-Config"
$targetShare = "\\fileserver\VMTags\Config"

# Copy latest CSV files from repository to network share
robocopy "$sourceRepo\PROD" "$targetShare\PROD" *.csv /MIR /LOG:deployment.log
```

This network share configuration provides a robust, centralized solution for managing VMTags CSV files across your environment while maintaining security, performance, and reliability! 🚀