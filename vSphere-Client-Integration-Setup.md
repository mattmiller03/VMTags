# VMTags vSphere Client Integration - Complete Setup Guide

This guide provides step-by-step instructions for deploying VMTags integration with the vSphere Client through Aria Orchestrator context menus.

## 🎯 Overview

After deployment, users can right-click on any VM in vSphere Client and execute VMTags operations:

- **Update VM Permissions** - Apply all tag-based permissions to selected VM
- **Sync All Tags** - Synchronize all VM tags and apply permissions
- **Apply Container Permissions** - Apply permissions from folder/resource pool tags
- **Validate Permissions** - Check current permissions without making changes

## 📋 Prerequisites

### Infrastructure Requirements
- ✅ **VMware vSphere Client** 8.0 or later
- ✅ **VMware Aria Automation Orchestrator** 8.x or later
- ✅ **PowerShell host** with VMTags-v2.0 scripts deployed
- ✅ **Network connectivity** between all components

### VMTags Environment
- ✅ **VMTags-v2.0 scripts** deployed and tested
- ✅ **Service account credentials** configured (Set-AriaServiceCredentials.ps1)
- ✅ **Environment configurations** validated (VMTagsConfig.psd1)
- ✅ **CSV data files** in place for each environment

## 🚀 Deployment Steps

### Step 1: Prepare VMTags Environment

#### 1.1 Verify VMTags Scripts
```powershell
# Test VMTags functionality
cd C:\VMTags-v2.0
.\VM_TagPermissions_Launcher.ps1 -Environment DEV -UseStoredCredentials -DryRun

# Verify single VM processing works
.\Scripts\set-VMtagPermissions.ps1 -SpecificVM "TestVM01" -Environment DEV -vCenterServer "vcenter-dev.domain.mil" -vSphereClientMode
```

#### 1.2 Configure Service Account Credentials
```powershell
# Set up service account for each environment
.\Set-AriaServiceCredentials.ps1 -Environment PROD -Method EnvironmentVariables -ServiceAccountUser "svc-vmtags@domain.mil" -ServiceAccountPassword (Read-Host -AsSecureString)
.\Set-AriaServiceCredentials.ps1 -Environment DEV -Method EnvironmentVariables -ServiceAccountUser "svc-vmtags@domain.mil" -ServiceAccountPassword (Read-Host -AsSecureString)
.\Set-AriaServiceCredentials.ps1 -Environment KLEB -Method EnvironmentVariables -ServiceAccountUser "svc-vmtags@domain.mil" -ServiceAccountPassword (Read-Host -AsSecureString)

# Test service account credentials
.\Get-AriaServiceCredentials.ps1; Test-AriaServiceCredentials -Environment PROD
```

#### 1.3 Configure PowerShell Remoting
```powershell
# On VMTags PowerShell host - Run as Administrator
Enable-PSRemoting -Force

# Configure WinRM service
winrm quickconfig -force

# Configure trusted hosts for Aria Orchestrator
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "aria-orchestrator.domain.mil" -Force

# Enable Kerberos authentication (recommended for domain environments)
Set-Item WSMan:\localhost\Service\Auth\Kerberos -Value $true

# Configure WinRM listeners
winrm create winrm/config/Listener?Address=*+Transport=HTTP
# For HTTPS (optional but recommended):
# winrm create winrm/config/Listener?Address=*+Transport=HTTPS

# Test WinRM connectivity from Aria Orchestrator server
Test-WSMan -ComputerName "vmtags-host.domain.mil" -Credential (Get-Credential)

# Verify service account can execute PowerShell remotely
$credential = Get-Credential -UserName "svc-vmtags@domain.mil"
Invoke-Command -ComputerName "vmtags-host.domain.mil" -Credential $credential -ScriptBlock { Get-Location }
```

### Step 2: Install Aria Orchestrator Plugin

#### 2.1 Install vSphere Client Plugin

1. **Download Plugin**
   - Navigate to VMware Customer Connect
   - Download "Aria Automation Orchestrator Plugin for vSphere Client"
   - Extract to temporary directory

2. **Deploy to vSphere Client**
   ```bash
   # Install plugin on vCenter Server
   # Method varies by vCenter version - consult VMware documentation
   ```

3. **Verify Plugin Installation**
   - Login to vSphere Client
   - Right-click on any VM
   - Verify "Aria Orchestrator" appears in context menu

#### 2.2 Configure Orchestrator Connection

1. **Add vCenter to Orchestrator Inventory**
   - Open Aria Orchestrator Designer
   - Navigate to Inventory → vCenter
   - Run "Add a vCenter Server Instance" workflow
   - Provide vCenter details and credentials

2. **Add PowerShell Host**

   **Step 2a: Configure PowerShell Host in Orchestrator**
   - Navigate to **Inventory → PowerShell** in Aria Orchestrator
   - Run **"Add a PowerShell Host"** workflow
   - Provide the following details:
     ```
     Name: VMTags-PowerShell-Host
     Host/IP: vmtags-host.domain.mil (your VMTags server)
     Port: 5985 (HTTP) or 5986 (HTTPS)
     Authentication: Kerberos or Basic
     Username: svc-vmtags@domain.mil (service account)
     Password: [service account password]
     ```

   **Step 2b: Test PowerShell Host Connection**
   - Navigate to **Inventory → PowerShell → VMTags-PowerShell-Host**
   - Right-click and select **"Test Connection"**
   - Verify connection shows **"Connected"** status
   - Run test command: `Get-Location` to verify PowerShell execution

   **Step 2c: Verify VMTags Scripts Access**
   - Execute test command: `Test-Path "C:\VMTags-v2.0\Invoke-VMTagsFromvSphere.ps1"`
   - Should return `True` indicating scripts are accessible
   - Test script execution: `Get-Help "C:\VMTags-v2.0\Invoke-VMTagsFromvSphere.ps1"`

### Step 3: Create Orchestrator Workflows

#### 3.1 Import Workflow Library

Create the following workflows in Aria Orchestrator:

**Main Workflow: "VMTags - Update VM Permissions"**

1. **Create New Workflow**
   - Name: `VMTags - Update VM Permissions`
   - Description: `Apply tag-based permissions to VM from vSphere Client`

2. **Define Input Parameters**

   Create these input parameters in the workflow:
   - `vm` (Type: VC:VirtualMachine) - VM selected from vSphere Client
   - `environment` (Type: string) - Target environment (optional, auto-detected if empty)
   - `action` (Type: string) - Action to perform (default: "UpdatePermissions")

3. **Workflow Schema - Scriptable Task Code**

   **Scriptable Task 1: "Validate Input and Prepare"**
   ```javascript
   // Validate VM input
   if (!vm) {
       throw "No VM selected. Please select a VM and try again.";
   }

   var vmName = vm.name;
   System.log("Processing VM: " + vmName);

   // Set default action if not provided
   if (!action || action === "") {
       action = "UpdatePermissions";
   }

   // Auto-detect environment if not provided
   if (!environment || environment === "") {
       // Simple environment detection from VM folder or datacenter
       var folder = vm.parent;
       var envDetected = "DEV"; // default

       // Check folder hierarchy for environment indicators
       while (folder && folder.name !== "vm") {
           var folderName = folder.name.toLowerCase();
           if (folderName.indexOf("prod") >= 0) {
               envDetected = "PROD";
               break;
           } else if (folderName.indexOf("kleb") >= 0) {
               envDetected = "KLEB";
               break;
           } else if (folderName.indexOf("ot") >= 0) {
               envDetected = "OT";
               break;
           }
           folder = folder.parent;
       }
       environment = envDetected;
   }

   System.log("Target Environment: " + environment);
   System.log("Action: " + action);
   ```

   **Scriptable Task 2: "Execute PowerShell Script"**
   ```javascript
   // Get PowerShell hosts from inventory
   var powerShellHosts = Server.findAllForType("PowerShell:PowerShellHost");
   var powerShellHost = null;

   // Find the specific PowerShell host
   for (var i = 0; i < powerShellHosts.length; i++) {
       if (powerShellHosts[i].name === "VMTags-PowerShell-Host") {
           powerShellHost = powerShellHosts[i];
           break;
       }
   }

   if (!powerShellHost) {
       throw "PowerShell host 'VMTags-PowerShell-Host' not found in inventory.\n" +
             "Please verify:\n" +
             "1. PowerShell host is configured in Inventory → PowerShell\n" +
             "2. Host name matches exactly: 'VMTags-PowerShell-Host'\n" +
             "3. Connection status shows 'Connected'";
   }

   System.log("Using PowerShell host: " + powerShellHost.name + " (" + powerShellHost.hostName + ")");

   // Build PowerShell command
   var scriptPath = "C:\\VMTags-v2.0\\Invoke-VMTagsFromvSphere.ps1";
   var psCommand = "& '" + scriptPath + "' -VMName '" + vmName + "' -Environment " + environment + " -Action " + action + " -EnableDebug";

   System.log("Executing PowerShell command: " + psCommand);

   // Execute PowerShell script
   var psResult = powerShellHost.invokeScript(psCommand);

   if (!psResult) {
       throw "PowerShell execution returned null result";
   }

   System.log("PowerShell execution completed");
   System.log("Exit Code: " + psResult.exitCode);
   System.log("Output: " + psResult.invocationResult);

   if (psResult.exitCode !== 0) {
       var errorMsg = "VMTags execution failed with exit code: " + psResult.exitCode;
       if (psResult.invocationResult) {
           errorMsg += "\nOutput: " + psResult.invocationResult;
       }
       throw errorMsg;
   }

   // Return success result
   var result = {
       success: true,
       vmName: vmName,
       environment: environment,
       action: action,
       output: psResult.invocationResult,
       message: "VMTags processing completed successfully for VM: " + vmName
   };

   System.log("VMTags workflow completed successfully for VM: " + vmName);
   ```

#### 3.2 Create Specialized Workflows

Create additional workflows for specific actions:

1. **"VMTags - Sync All Tags"** (Action: SyncAllTags)
2. **"VMTags - Apply Container Permissions"** (Action: ApplyContainerPermissions)
3. **"VMTags - Validate Permissions"** (Action: ValidatePermissions)

### Step 4: Configure Context Menu Integration

#### 4.1 Create Workflow Actions

1. **Navigate to Actions in Orchestrator**
   - Go to Design → Actions
   - Create new action for each workflow

2. **Configure Action Properties**
   ```javascript
   // Action Configuration
   Name: "Update VM Permissions"
   Resource Type: "VirtualMachine"
   Workflow: "VMTags - Update VM Permissions"
   Icon: "security"
   ```

#### 4.2 Deploy Actions to vSphere Client

1. **Export Actions**
   - Export actions as package (.package file)
   - Include all related workflows and dependencies

2. **Deploy to vSphere Client**
   - Import package to Aria Orchestrator server
   - Verify actions appear in vSphere Client context menus

### Step 5: Testing and Validation

#### 5.1 Basic Functionality Test

1. **Test Context Menu**
   - Right-click on test VM in vSphere Client
   - Verify "Aria Orchestrator" menu appears
   - Check all VMTags actions are listed

2. **Execute Test Workflow**
   - Select "Update VM Permissions"
   - Monitor workflow execution
   - Verify completion and check logs

3. **Validate Results**
   ```powershell
   # Check VM permissions were applied
   Get-VM "TestVM" | Get-VIPermission

   # Review execution logs
   Get-Content "C:\VMTags-v2.0\Logs\vSphereClient_TestVM_UpdatePermissions_*.log"
   ```

#### 5.2 Multi-Environment Testing

Test integration with each environment:

```powershell
# Test PROD environment
# Right-click VM → Aria Orchestrator → Update VM Permissions
# Verify environment auto-detection works

# Test DEV environment
# Right-click VM → Aria Orchestrator → Sync All Tags
# Verify tag synchronization

# Test KLEB environment
# Right-click VM → Aria Orchestrator → Apply Container Permissions
# Verify hierarchical inheritance works
```

### Step 6: User Training and Documentation

#### 6.1 Create User Guide

Document for end users:

```markdown
# VMTags vSphere Client Integration - User Guide

## How to Update VM Permissions

1. **Select VM** in vSphere Client inventory
2. **Right-click** on the VM
3. **Choose** "Aria Orchestrator" → "Update VM Permissions"
4. **Monitor** workflow execution progress
5. **Review** results in execution window

## Available Actions

- **Update VM Permissions**: Apply all tag-based permissions
- **Sync All Tags**: Refresh tags and permissions
- **Apply Container Permissions**: Inherit from folder/resource pool
- **Validate Permissions**: Check without making changes

## When to Use Each Action

- **After manually tagging VMs**: Use "Update VM Permissions"
- **After moving VMs to folders**: Use "Apply Container Permissions"
- **For troubleshooting**: Use "Validate Permissions"
- **For complete refresh**: Use "Sync All Tags"
```

#### 6.2 Administrator Training

- **Workflow monitoring** in Aria Orchestrator
- **Troubleshooting** failed executions
- **Log file locations** and review procedures
- **Performance monitoring** and optimization

## 🔧 Configuration Options

### Environment-Specific Settings

```javascript
// Configure different settings per environment
var environmentConfig = {
    "PROD": {
        "requireApproval": true,
        "enableAuditing": true,
        "maxConcurrentExecutions": 5
    },
    "DEV": {
        "requireApproval": false,
        "enableAuditing": false,
        "maxConcurrentExecutions": 10
    }
};
```

### Custom Action Parameters

```javascript
// Add custom parameters to workflows
var customActions = {
    "Emergency Permission Reset": {
        "action": "UpdatePermissions",
        "clearExisting": true,
        "forceExecution": true
    },
    "Compliance Check": {
        "action": "ValidatePermissions",
        "generateReport": true,
        "emailResults": true
    }
};
```

## 🔍 Monitoring and Maintenance

### Regular Maintenance Tasks

1. **Weekly**: Review workflow execution logs
2. **Monthly**: Update service account credentials if needed
3. **Quarterly**: Test all workflow actions across environments
4. **Annually**: Review and update workflow logic

### Performance Monitoring

```powershell
# Monitor workflow execution times
$logs = Get-ChildItem "C:\VMTags-v2.0\Logs\vSphereClient_*.log"
$execTimes = $logs | ForEach-Object {
    $content = Get-Content $_.FullName
    $start = ($content | Where-Object { $_ -match "Integration Started" })[0]
    $end = ($content | Where-Object { $_ -match "Integration Completed" })[0]
    # Calculate execution time
}
```

### Health Checks

```powershell
# Daily health check script
function Test-vSphereIntegrationHealth {
    # Test PowerShell connectivity
    Test-WSMan -ComputerName "vmtags-host.domain.mil"

    # Test service account credentials
    .\Get-AriaServiceCredentials.ps1; Test-AriaServiceCredentials -Environment PROD

    # Test workflow execution
    # Invoke test workflow with dummy VM

    # Check disk space on log directory
    Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" | Select FreeSpace
}
```

## 🚨 Troubleshooting

### Common Issues and Solutions

1. **"PowerShell Host Not Found" Error**
   ```
   Error: PowerShell host 'VMTags-PowerShell-Host' not found

   Solution Steps:
   1. Navigate to Aria Orchestrator → Inventory → PowerShell
   2. Verify host exists with exact name: "VMTags-PowerShell-Host"
   3. Check connection status - should show "Connected"
   4. If disconnected, right-click → "Test Connection"
   5. Verify credentials and network connectivity
   6. Ensure WinRM is enabled on target host

   Test Commands:
   - In Orchestrator: Test-Connection vmtags-host.domain.mil
   - On VMTags host: Test-WSMan -ComputerName "localhost"
   - Check service: Get-Service WinRM
   ```

2. **"VM Not Found" Error**
   ```
   Solution: Check VM name spelling and vCenter connectivity
   Verify: VM exists and is visible in current vCenter session
   ```

3. **"Credential Authentication Failed"**
   ```
   Solution: Update service account credentials
   Run: .\Set-AriaServiceCredentials.ps1 with new password
   ```

4. **"Permission Assignment Failed"**
   ```
   Solution: Check service account vCenter permissions
   Verify: Account has required role assignment privileges
   ```

### Debug Mode Activation

```javascript
// Enable debug logging in workflows
System.debug = true;
System.log("Debug mode activated for troubleshooting");

// Add detailed logging for each step
System.log("VM Object: " + JSON.stringify(vm));
System.log("Environment: " + environment);
System.log("Action: " + action);
System.log("PowerShell Command: " + command);
System.log("Execution Result: " + JSON.stringify(result));
```

## 📞 Support and Contacts

### Technical Support
- **VMTags Scripts**: Internal IT Team
- **Aria Orchestrator**: VMware Support
- **vSphere Client**: VMware Support

### Emergency Procedures
- **Service Account Issues**: Reset credentials using Set-AriaServiceCredentials.ps1
- **Workflow Failures**: Check PowerShell host connectivity and restart services
- **Mass Permission Issues**: Run bulk VMTags processing outside of vSphere Client

---

## ✅ Deployment Checklist

### PowerShell Host Configuration
- [ ] WinRM enabled on VMTags host (`Enable-PSRemoting -Force`)
- [ ] WinRM listeners configured (HTTP port 5985, optionally HTTPS port 5986)
- [ ] Trusted hosts configured for Aria Orchestrator server
- [ ] Service account credentials validated for remote PowerShell execution
- [ ] Network connectivity verified between Aria Orchestrator and VMTags host

### VMTags Environment
- [ ] VMTags scripts tested and validated
- [ ] Service account credentials configured for all environments (`Set-AriaServiceCredentials.ps1`)
- [ ] Single VM processing tested (`-SpecificVM` parameter)
- [ ] vSphere Client wrapper script tested (`Invoke-VMTagsFromvSphere.ps1`)

### Aria Orchestrator Integration
- [ ] Aria Orchestrator plugin installed in vSphere Client
- [ ] vCenter Server added to Orchestrator inventory
- [ ] **PowerShell host added to Orchestrator inventory with name "VMTags-PowerShell-Host"**
- [ ] **PowerShell host connection tested and shows "Connected" status**
- [ ] **VMTags scripts accessibility verified from Orchestrator**

### Workflow Deployment
- [ ] Main workflow created: "VMTags - Update VM Permissions"
- [ ] Specialized workflows created (SyncAllTags, ApplyContainerPermissions, ValidatePermissions)
- [ ] Workflow actions configured for context menus
- [ ] Context menu actions deployed to vSphere Client

### Testing and Validation
- [ ] Integration tested with sample VMs from each environment
- [ ] PowerShell host connectivity verified from workflows
- [ ] Error handling tested (invalid VMs, connection failures)
- [ ] Logging and monitoring validated

### Documentation and Training
- [ ] User documentation created and distributed
- [ ] Administrator training completed
- [ ] Monitoring and maintenance procedures established

**Deployment complete when all checklist items are verified! 🎉**

---

## 📖 Quick Reference: PowerShell Host Setup

### Critical Configuration Steps
```powershell
# 1. Enable PowerShell remoting on VMTags host
Enable-PSRemoting -Force
winrm quickconfig -force

# 2. Add Aria Orchestrator to trusted hosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "aria-orchestrator.domain.mil" -Force

# 3. Test connectivity from Orchestrator server
Test-WSMan -ComputerName "vmtags-host.domain.mil"
Invoke-Command -ComputerName "vmtags-host.domain.mil" -Credential $cred -ScriptBlock { Get-Location }
```

### Aria Orchestrator Configuration
```
Navigate to: Inventory → PowerShell → Add a PowerShell Host
Name: VMTags-PowerShell-Host (exact name required)
Host: vmtags-host.domain.mil
Port: 5985 (HTTP) or 5986 (HTTPS)
Authentication: Kerberos (domain) or Basic
Username: svc-vmtags@domain.mil
Password: [service account password]
```

### Workflow PowerShell Host Reference
```javascript
// In workflow JavaScript, reference the host by exact name:
var powerShellHost = System.getModule("com.vmware.library.powershell").getPowerShellHost("VMTags-PowerShell-Host");
```

### Common Issues
- ❌ **Host name mismatch**: Ensure exact name "VMTags-PowerShell-Host"
- ❌ **WinRM not enabled**: Run `Enable-PSRemoting -Force`
- ❌ **Network connectivity**: Check ports 5985/5986 are open
- ❌ **Authentication failure**: Verify service account permissions
- ❌ **Script path**: Ensure C:\VMTags-v2.0\ is accessible on target host