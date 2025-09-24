# VMTags Aria Orchestrator Workflows for vSphere Client Integration

This document provides the workflow definitions and setup instructions for integrating VMTags with the vSphere Client through Aria Orchestrator context menus.

## 🚀 Overview

The vSphere Client integration allows users to right-click on VMs and execute VMTags operations directly from context menus:

- **Update VM Permissions**: Apply all tag-based permissions to selected VM
- **Sync All VM Tags**: Synchronize all VM tags and apply permissions
- **Apply Container Permissions**: Apply permissions from folder/resource pool tags
- **Validate VM Permissions**: Check current permissions without making changes

## 📋 Prerequisites

### Aria Orchestrator Requirements
- VMware Aria Automation Orchestrator 8.x or later
- PowerShell plugin installed and configured
- vCenter Server plugin configured
- Network connectivity to PowerShell host running VMTags scripts

### VMTags Environment Setup
- VMTags-v2.0 scripts deployed on PowerShell host
- Service account credentials configured (using Set-AriaServiceCredentials.ps1)
- Environment-specific configuration files in place

## 🛠 Workflow Definitions

### 1. Main Workflow: "VMTags - Update VM Permissions"

**Workflow Name**: `VMTags - Update VM Permissions`
**Description**: Apply tag-based permissions to a VM from vSphere Client context menu
**Input Parameters**:
- `vm` (VC:VirtualMachine) - VM selected from vSphere Client
- `environment` (string) - Target environment (DEV, PROD, KLEB, OT)
- `action` (string) - Action to perform (default: "UpdatePermissions")

**Workflow Steps**:

1. **Input Validation**
   ```javascript
   // Validate VM object
   if (!vm) {
       throw "No VM selected. Please select a VM and try again.";
   }

   // Get VM name
   var vmName = vm.name;
   System.log("Processing VM: " + vmName);
   ```

2. **Environment Detection**
   ```javascript
   // Auto-detect environment if not provided
   if (!environment || environment === "") {
       // Logic to detect environment from VM location, tags, or vCenter
       environment = detectEnvironmentFromVM(vm);
   }

   System.log("Target Environment: " + environment);
   ```

3. **PowerShell Host Connection**
   ```javascript
   // Get the configured PowerShell host (must match name from inventory)
   var powerShellHost = System.getModule("com.vmware.library.powershell").getPowerShellHost("VMTags-PowerShell-Host");

   if (!powerShellHost) {
       throw "PowerShell host 'VMTags-PowerShell-Host' not found. Please verify:\n" +
             "1. PowerShell host is configured in Inventory → PowerShell\n" +
             "2. Host name matches exactly: 'VMTags-PowerShell-Host'\n" +
             "3. Connection status shows 'Connected'";
   }

   System.log("Using PowerShell host: " + powerShellHost.name + " (" + powerShellHost.hostName + ")");
   ```

4. **Execute VMTags Script**
   ```javascript
   // Prepare PowerShell script execution
   var scriptPath = "C:\\VMTags-v2.0\\Invoke-VMTagsFromvSphere.ps1";
   var scriptParams = [
       "-VMName", "'" + vmName + "'",
       "-Environment", environment,
       "-Action", action,
       "-EnableDebug"
   ];

   var command = scriptPath + " " + scriptParams.join(" ");
   System.log("Executing command: " + command);

   // Execute script
   var result = System.getModule("com.vmware.library.powershell").invokeScript(
       powerShellHost,
       command
   );
   ```

5. **Process Results**
   ```javascript
   // Parse execution results
   if (result.exitCode === 0) {
       System.log("VMTags execution successful");
       System.log("Output: " + result.output);

       return {
           success: true,
           vmName: vmName,
           environment: environment,
           action: action,
           message: "Permissions updated successfully for VM: " + vmName
       };
   } else {
       System.error("VMTags execution failed");
       System.error("Error: " + result.error);

       throw "Failed to update permissions for VM: " + vmName + ". Error: " + result.error;
   }
   ```

### 2. Helper Workflow: "VMTags - Detect Environment"

**Workflow Name**: `VMTags - Detect Environment`
**Description**: Auto-detect target environment from VM context
**Input Parameters**:
- `vm` (VC:VirtualMachine) - VM object

**Logic**:
```javascript
function detectEnvironmentFromVM(vm) {
    // Method 1: Check VM folder structure
    var folder = vm.parent;
    while (folder && folder.name !== "vm") {
        if (folder.name.toLowerCase().includes("prod")) {
            return "PROD";
        } else if (folder.name.toLowerCase().includes("dev")) {
            return "DEV";
        } else if (folder.name.toLowerCase().includes("kleb")) {
            return "KLEB";
        } else if (folder.name.toLowerCase().includes("ot")) {
            return "OT";
        }
        folder = folder.parent;
    }

    // Method 2: Check existing VM tags
    var tags = vm.tag;
    for (var i = 0; i < tags.length; i++) {
        var tagName = tags[i].name;
        if (tagName.includes("PROD")) return "PROD";
        if (tagName.includes("DEV")) return "DEV";
        if (tagName.includes("KLEB")) return "KLEB";
        if (tagName.includes("OT")) return "OT";
    }

    // Method 3: Check vCenter server (fallback)
    var vcenterName = vm.sdkConnection.host;
    if (vcenterName.includes("prod")) return "PROD";
    if (vcenterName.includes("dev")) return "DEV";
    if (vcenterName.includes("kleb")) return "KLEB";
    if (vcenterName.includes("ot")) return "OT";

    // Default to DEV if can't determine
    return "DEV";
}
```

### 3. Specialized Workflows

#### A. "VMTags - Sync All Tags"
- **Action Parameter**: "SyncAllTags"
- **Description**: Synchronize all VM tags and apply permissions
- **Use Case**: After manual tag changes in vSphere Client

#### B. "VMTags - Apply Container Permissions"
- **Action Parameter**: "ApplyContainerPermissions"
- **Description**: Apply permissions based on folder/resource pool tags
- **Additional Parameter**: `EnableHierarchicalInheritance = true`

#### C. "VMTags - Validate Permissions"
- **Action Parameter**: "ValidatePermissions"
- **Description**: Check current permissions without making changes
- **Additional Parameter**: `DryRun = true`

## 📁 Context Menu Assignment

### vSphere Client Integration Steps

1. **Create Workflow Actions**
   - In Aria Orchestrator, navigate to "Actions" → "New Action"
   - Create actions for each workflow
   - Configure input parameters and execution logic

2. **Assign to vCenter Context Menus**
   ```javascript
   // Context menu configuration
   var menuItems = [
       {
           name: "Update VM Permissions",
           workflow: "VMTags - Update VM Permissions",
           icon: "security",
           position: 1
       },
       {
           name: "Sync All Tags",
           workflow: "VMTags - Sync All Tags",
           icon: "tag",
           position: 2
       },
       {
           name: "Apply Container Permissions",
           workflow: "VMTags - Apply Container Permissions",
           icon: "folder",
           position: 3
       },
       {
           name: "Validate Permissions",
           workflow: "VMTags - Validate Permissions",
           icon: "check",
           position: 4
       }
   ];
   ```

3. **Configure Context Menu Visibility**
   ```javascript
   // Show menu items only for appropriate VMs
   function shouldShowMenuItem(vm) {
       // Don't show for system VMs
       if (vm.name.match(/^(vCLS|VLC|stCtlVM)/)) {
           return false;
       }

       // Show for all other VMs
       return true;
   }
   ```

## 🔧 Configuration

### PowerShell Host Setup

1. **Add PowerShell Host**
   - Navigate to Aria Orchestrator → Inventory → PowerShell
   - Add new PowerShell host: "VMTags-PowerShell-Host"
   - Configure connection details for VMTags script host

2. **Configure Authentication**
   ```powershell
   # On PowerShell host, ensure WinRM is configured
   Enable-PSRemoting -Force
   Set-Item WSMan:\localhost\Client\TrustedHosts -Value "aria-orchestrator-server" -Force

   # Configure service account for remote execution
   # Use same service account as configured for VMTags
   ```

### Environment Configuration

Create configuration mapping in Aria Orchestrator:

```javascript
var environmentConfig = {
    "PROD": {
        "vCenterServer": "daisv0pp241.dir.ad.dla.mil",
        "powerShellHost": "VMTags-PowerShell-Host-PROD"
    },
    "DEV": {
        "vCenterServer": "vcenter-dev.domain.mil",
        "powerShellHost": "VMTags-PowerShell-Host-DEV"
    },
    "KLEB": {
        "vCenterServer": "vcenter-kleb.domain.mil",
        "powerShellHost": "VMTags-PowerShell-Host-KLEB"
    },
    "OT": {
        "vCenterServer": "vcenter-ot.domain.mil",
        "powerShellHost": "VMTags-PowerShell-Host-OT"
    }
};
```

## 🔍 Monitoring and Logging

### Workflow Execution Logs
- Aria Orchestrator maintains execution logs for each workflow run
- PowerShell script logs are stored on the VMTags host
- vSphere Client shows execution status and results

### Error Handling
```javascript
// Comprehensive error handling in workflows
try {
    // Execute VMTags script
    var result = executeVMTagsScript(vm, environment, action);

    // Check results
    if (!result.success) {
        throw "VMTags execution failed: " + result.error;
    }

    // Return success
    return {
        success: true,
        message: result.message,
        logFile: result.logFile
    };

} catch (error) {
    System.error("Workflow execution failed: " + error);

    // Send notification to administrators
    System.getModule("com.vmware.library.notification").sendEmail(
        "vmtags-admins@domain.mil",
        "VMTags Workflow Failed",
        "Failed to execute VMTags workflow for VM: " + vm.name + "\nError: " + error
    );

    throw error;
}
```

## 🚦 Usage Instructions

### For vSphere Client Users

1. **Right-click on any VM** in vSphere Client inventory
2. **Select "Aria Orchestrator"** from context menu
3. **Choose VMTags action**:
   - "Update VM Permissions" - Apply all tag-based permissions
   - "Sync All Tags" - Synchronize tags and permissions
   - "Apply Container Permissions" - Inherit from folder/resource pool
   - "Validate Permissions" - Check without changes
4. **Monitor execution** in workflow status window
5. **Review results** and check logs if needed

### For Administrators

- **Monitor workflow executions** in Aria Orchestrator
- **Check PowerShell host logs** for detailed execution information
- **Review permission changes** in vCenter permissions tab
- **Validate automation results** using VMTags reports

## 🔧 Troubleshooting

### Common Issues

1. **PowerShell Host Connection Failed**
   - Check WinRM configuration
   - Verify service account permissions
   - Test PowerShell connectivity from Aria Orchestrator

2. **VMTags Script Not Found**
   - Verify script path in workflow configuration
   - Check PowerShell host file system access
   - Ensure VMTags scripts are deployed correctly

3. **Permission Assignment Failed**
   - Check service account vCenter permissions
   - Verify CSV configuration files exist
   - Review VMTags script logs for detailed errors

4. **Environment Detection Failed**
   - Manually specify environment parameter
   - Check VM folder structure and naming
   - Review environment detection logic

### Debug Mode

Enable debug logging in workflows:
```javascript
// Enable detailed logging
System.debug = true;
System.log("Debug mode enabled for VMTags workflow");

// Add debug output for all major steps
System.log("Step 1: VM validation - " + JSON.stringify(vm));
System.log("Step 2: Environment detection - " + environment);
System.log("Step 3: PowerShell execution - " + command);
System.log("Step 4: Result processing - " + JSON.stringify(result));
```

## 📈 Performance Considerations

- **Single VM processing** is optimized for vSphere Client integration
- **Execution time** typically 30-60 seconds per VM
- **Parallel processing** is disabled for single VM operations
- **Resource impact** is minimal for individual VM operations

## 🔐 Security Notes

- **Service account credentials** are managed through VMTags credential system
- **PowerShell remoting** uses secure authentication
- **Workflow execution** is logged and audited
- **Permission changes** are tracked in vCenter audit logs