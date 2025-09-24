# VMTags Workflow Inputs/Outputs Configuration Guide

This document defines the **main workflow interface** configuration for the VMTags vSphere Client integration workflows.

## 🎯 Overview

The **Inputs/Outputs** tab of the main workflow defines the **workflow interface** - what parameters the workflow accepts and what it returns. This is separate from individual task bindings.

## 📋 Workflow Interface Configuration

### **Main Workflow: "VMTags - Update VM Permissions"**

**To Configure:**
1. **Select the main workflow** (not any individual element)
2. **Properties Panel** → **"Inputs/Outputs"** tab
3. **Configure workflow parameters**

## 🔧 Input Parameters Configuration

### **Required Inputs:**

**Input Parameter 1: VM Object**
```
Name: vm
Type: VC:VirtualMachine
Description: VM selected from vSphere Client context menu
Required: Yes
Default Value: (none)
```

**Input Parameter 2: Environment (Optional)**
```
Name: environment
Type: string
Description: Target environment (PROD, KLEB, OT, DEV) - auto-detected if empty
Required: No
Default Value: "" (empty string)
Validation: RegExp - ^(PROD|KLEB|OT|DEV)?$
```

**Input Parameter 3: Action Type**
```
Name: action
Type: string
Description: Type of VMTags action to perform
Required: No
Default Value: "UpdatePermissions"
Predefined Values:
- UpdatePermissions
- SyncAllTags
- ApplyContainerPermissions
- ValidatePermissions
```

## 📤 Output Parameters Configuration

### **Workflow Results:**

**Output Parameter 1: Execution Result**
```
Name: result
Type: Properties
Description: Detailed execution result object with all status information
Required: Yes
```

**Output Parameter 2: Success Flag**
```
Name: success
Type: boolean
Description: Whether the VMTags operation completed successfully
Required: Yes
Default Value: false
```

**Output Parameter 3: Result Message**
```
Name: message
Type: string
Description: Human-readable result message for display
Required: Yes
Default Value: "Workflow execution status unknown"
```

**Output Parameter 4: Environment Detected**
```
Name: detectedEnvironment
Type: string
Description: The environment that was detected/used for processing
Required: Yes
Default Value: "UNKNOWN"
```

**Output Parameter 5: VM Information**
```
Name: vmInfo
Type: Properties
Description: Information about the processed VM
Required: No
```

**Output Parameter 6: Execution Duration**
```
Name: executionTime
Type: Date
Description: Timestamp when the workflow completed
Required: No
```

## 🎨 UI Configuration Steps

### **Step 1: Access Workflow Inputs/Outputs**

1. **Open workflow** in Aria Orchestrator Designer
2. **Click in empty space** of the workflow schema (not on any element)
3. **Properties Panel** → **"Inputs/Outputs"** tab
4. **You should see workflow-level configuration** (not element-specific)

### **Step 2: Configure Input Parameters**

**Add Input Parameters:**
1. **"Inputs" section** → **"Add"** button
2. **For each required input:**
   - Enter **Name** (vm, environment, action)
   - Select **Type** from dropdown
   - Add **Description**
   - Set **Required** flag
   - Configure **Default Value** if applicable

**Input Parameter Details:**

**VM Parameter:**
- **Name**: `vm`
- **Type**: `VC:VirtualMachine` (from vCenter plugin types)
- **Description**: `VM selected from vSphere Client context menu`
- **Required**: ☑️ **Checked**

**Environment Parameter:**
- **Name**: `environment`
- **Type**: `string`
- **Description**: `Target environment (auto-detected if empty)`
- **Required**: ☐ **Unchecked**
- **Default Value**: `""` (empty string)

**Action Parameter:**
- **Name**: `action`
- **Type**: `string`
- **Description**: `Type of VMTags action to perform`
- **Required**: ☐ **Unchecked**
- **Default Value**: `"UpdatePermissions"`
- **Predefined Values**: Configure dropdown with action options

### **Step 3: Configure Output Parameters**

**Add Output Parameters:**
1. **"Outputs" section** → **"Add"** button
2. **For each output parameter:**
   - Enter **Name** (result, success, message, etc.)
   - Select **Type**
   - Add **Description**
   - Set as **Required** for essential outputs

## 📊 Data Flow Architecture

```
vSphere Client Context Menu
          ↓
[Workflow Input Parameters]
├── vm: VC:VirtualMachine (from right-click selection)
├── environment: string (optional, auto-detect)
└── action: string (default: "UpdatePermissions")
          ↓
[Workflow Processing]
├── Validate Input Task
├── Decision Element (Environment Detection)
├── Execute PowerShell Task
└── Result Processing
          ↓
[Workflow Output Parameters]
├── result: Properties (detailed results)
├── success: boolean (true/false)
├── message: string (user-friendly status)
├── detectedEnvironment: string (PROD/KLEB/OT/DEV)
├── vmInfo: Properties (VM details)
└── executionTime: Date (completion timestamp)
          ↓
vSphere Client Result Display
```

## 🔄 Parameter vs Attribute vs Binding

### **Understanding the Hierarchy:**

**1. Workflow Input/Output Parameters** ⬅️ **This guide**
- **Level**: Main workflow interface
- **Purpose**: External contract - what the workflow accepts/returns
- **Configuration**: Workflow Properties → Inputs/Outputs tab
- **Example**: `vm` (VC:VirtualMachine) input parameter

**2. Workflow Attributes**
- **Level**: Internal workflow data
- **Purpose**: Data passing between workflow elements
- **Configuration**: Created automatically from task output bindings
- **Example**: `folderPath` attribute from Validate Input to Decision Element

**3. Task Bindings**
- **Level**: Individual task data mapping
- **Purpose**: Map workflow attributes to/from task variables
- **Configuration**: Each task Properties → Binding tab
- **Example**: Validate Input output binding creates `folderPath` attribute

## 🎯 Context Menu Integration

### **How vSphere Client Passes Parameters:**

When users right-click a VM in vSphere Client:

1. **vSphere Client** → **Aria Orchestrator Plugin**
2. **Plugin** → **Workflow Input Parameters:**
   ```
   vm = [Selected VM Object]
   environment = "" (empty - triggers auto-detection)
   action = "UpdatePermissions" (default)
   ```
3. **Workflow Executes** → **Returns Output Parameters:**
   ```
   success = true
   message = "Permissions updated successfully for VM: WebServer01"
   detectedEnvironment = "PROD"
   result = { vmName: "WebServer01", environment: "PROD", ... }
   ```
4. **vSphere Client** displays success/failure message to user

## 🚀 Specialized Workflow Variations

### **Different Actions, Same Interface:**

**"VMTags - Sync All Tags" Workflow:**
- **Same Input Parameters**: vm, environment, action
- **Action Default**: `"SyncAllTags"`
- **Same Output Parameters**: result, success, message

**"VMTags - Apply Container Permissions" Workflow:**
- **Same Input Parameters**: vm, environment, action
- **Action Default**: `"ApplyContainerPermissions"`
- **Same Output Parameters**: result, success, message

**"VMTags - Validate Permissions" Workflow:**
- **Same Input Parameters**: vm, environment, action
- **Action Default**: `"ValidatePermissions"`
- **Same Output Parameters**: result, success, message

## 📋 Configuration Checklist

### **Workflow Input Parameters:**
- [ ] `vm` (VC:VirtualMachine, Required)
- [ ] `environment` (string, Optional, Default: "")
- [ ] `action` (string, Optional, Default: "UpdatePermissions")

### **Workflow Output Parameters:**
- [ ] `result` (Properties, Required)
- [ ] `success` (boolean, Required)
- [ ] `message` (string, Required)
- [ ] `detectedEnvironment` (string, Required)
- [ ] `vmInfo` (Properties, Optional)
- [ ] `executionTime` (Date, Optional)

### **Parameter Validation:**
- [ ] Input parameters have appropriate types
- [ ] Required parameters are marked as required
- [ ] Default values are set for optional parameters
- [ ] Output parameters cover all necessary result information

### **vSphere Client Integration:**
- [ ] Input parameters match context menu expectations
- [ ] Output parameters provide meaningful user feedback
- [ ] Error handling returns appropriate failure messages
- [ ] Success messages are user-friendly and informative

## 🐛 Troubleshooting

### **Common Issues:**

**Issue: "Required parameter 'vm' not provided"**
```
Solution: Verify vSphere Client context menu integration
- Ensure workflow is properly assigned to VM context menu
- Check that VM selection is being passed correctly
```

**Issue: "Workflow returns no output"**
```
Solution: Configure output parameters
1. Select main workflow (not individual tasks)
2. Properties → Inputs/Outputs → Outputs section
3. Add required output parameters (result, success, message)
```

**Issue: "Environment parameter ignored"**
```
Solution: Verify parameter binding in first task
- Check that workflow input 'environment' maps to task variable
- Ensure auto-detection logic handles empty environment parameter
```

## 📈 Advanced Configuration

### **Enhanced Input Validation:**

**Environment Parameter with Predefined Values:**
```
Name: environment
Type: string
Predefined Values:
- "" (empty - auto-detect)
- "PROD"
- "KLEB"
- "OT"
- "DEV"
```

**Action Parameter with Descriptions:**
```
Name: action
Type: string
Predefined Values:
- UpdatePermissions (Apply all tag-based permissions)
- SyncAllTags (Synchronize tags and permissions)
- ApplyContainerPermissions (Inherit from folder/resource pool)
- ValidatePermissions (Check without making changes)
```

This workflow interface configuration ensures proper integration with vSphere Client context menus and provides clear, structured results for users! 🚀✅