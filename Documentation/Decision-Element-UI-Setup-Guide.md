# Aria Orchestrator Decision Element UI Setup Guide

This guide provides step-by-step instructions for configuring the Decision Element in Aria Orchestrator for VMTags environment detection.

## 🎯 Overview

We're replacing JavaScript environment detection logic with a visual Decision Element that automatically determines the target environment (PROD, KLEB, OT, DEV) based on the VM's folder path.

## 📋 Prerequisites

- Aria Orchestrator Designer access
- VMTags workflow already created with input parameters
- First scriptable task ("Validate Input") completed and creates `folderPath` workflow attribute

## 🚀 Step-by-Step UI Configuration

### Step 1: Add Decision Element to Workflow

1. **Open Workflow in Designer**
   - Navigate to **Design → Workflows**
   - Open your **"VMTags - Update VM Permissions"** workflow
   - Switch to **Schema** tab

2. **Add Decision Element**
   - From the **General** palette on the left, drag a **"Decision"** element
   - Drop it between your **"Validate Input"** scriptable task and **"Execute PowerShell"** task
   - **Name**: `Determine Environment`
   - **Description**: `Auto-detect target environment from VM folder path`

### Step 2: Configure Decision Element Properties

3. **Select the Decision Element**
   - Click on the Decision Element in the schema
   - In the **Properties** tab (right panel), configure:

   **General Tab:**
   - **Name**: `Determine Environment`
   - **Description**: `Auto-detect target environment from VM folder path`
   - **Decision Type**: **UNCHECK "Simple"** ✅ (Use Advanced Mode)
   - **Exception Binding**: `(none)`

   **⚠️ IMPORTANT: Decision Type Configuration**
   - **Simple Mode** ❌ - Limited to basic equality comparisons
   - **Advanced Mode** ✅ - Supports complex JavaScript expressions like `indexOf()`

### Step 3: Configure Output Bindings for Validate Input Task

4. **CRITICAL: Configure Output Bindings**

   Before configuring the Decision Element, you MUST set up output bindings in the "Validate Input" task:

   1. **Select "Validate Input" scriptable task**
   2. **Properties Panel** → **"Binding"** tab
   3. **"Out Attributes" section** → Click **"Add"** for each variable:

   **Required Output Attributes:**
   ```
   Output Attribute 1:
   - Name: vmName
   - Type: string
   - Bind to: vmName
   - Description: VM name from input

   Output Attribute 2:
   - Name: action
   - Type: string
   - Bind to: action
   - Description: Action to perform

   Output Attribute 3:
   - Name: folderPath
   - Type: string
   - Bind to: folderPath
   - Description: VM folder path for environment detection

   Output Attribute 4:
   - Name: vmFolder
   - Type: VC:Folder
   - Bind to: vmFolder
   - Description: VM parent folder object
   ```

   **⚠️ Without Output Bindings, the Decision Element cannot access these variables!**

   **Verification:**
   - Check that all JavaScript variables (vmName, action, folderPath, vmFolder) have corresponding output bindings
   - Ensure "Bind to" field matches the JavaScript variable name exactly
   - Save the scriptable task before proceeding

### Step 4: Configure Decision Logic

5. **Switch to Decision Logic Tab**
   - In the Decision Element properties, click the **"Decision Logic"** tab
   - You'll see a table for configuring conditions

5. **Add Decision Conditions (in priority order)**

   **Condition 1: PROD Environment**
   - Click **"Add"** button
   - **Name**: `PROD Branch`
   - **Description**: `Production environment detection`
   - **Condition**: `folderPath.indexOf("prod") >= 0`
   - **Decision Result**: `PROD`
   - **Order**: `1` (highest priority)

   **Condition 2: KLEB Environment**
   - Click **"Add"** button
   - **Name**: `KLEB Branch`
   - **Description**: `KLEB environment detection`
   - **Condition**: `folderPath.indexOf("kleb") >= 0`
   - **Decision Result**: `KLEB`
   - **Order**: `2`

   **Condition 3: OT Environment**
   - Click **"Add"** button
   - **Name**: `OT Branch`
   - **Description**: `OT environment detection`
   - **Condition**: `folderPath.indexOf("ot") >= 0`
   - **Decision Result**: `OT`
   - **Order**: `3`

   **Condition 4: Default (DEV)**
   - Click **"Add"** button
   - **Name**: `DEV Branch (Default)`
   - **Description**: `Default to DEV environment`
   - **Condition**: `true`
   - **Decision Result**: `DEV`
   - **Order**: `4` (lowest priority - catch-all)

### Step 4: Configure Output Bindings

6. **Set Up Workflow Attribute Binding**
   - Still in Decision Element properties, go to **"Binding"** tab
   - **Out Attributes** section:
     - Click **"Add"**
     - **Attribute Name**: `targetEnvironment`
     - **Type**: `string`
     - **Bind to**: `Decision result`
     - **Description**: `Environment determined by decision logic`

### Step 5: Connect Decision Branches

7. **Create Connections in Schema**
   - **From "Validate Input" task** → **To "Determine Environment" decision**
   - **From "Determine Environment" decision** → **To "Execute PowerShell" task**

   **Important**: The Decision Element will have **four output arrows** (one for each condition result)

8. **Connect Each Decision Branch**

   **Option A: Single PowerShell Task (Recommended)**
   - Connect **all four decision outputs** to the **same** "Execute PowerShell" scriptable task
   - The `targetEnvironment` attribute will contain the environment value

   **Option B: Separate Tasks Per Environment**
   - Create **four separate** "Execute PowerShell" tasks (one per environment)
   - Connect each decision branch to its corresponding task:
     - **PROD Branch** → **"Execute PowerShell - PROD"** task
     - **KLEB Branch** → **"Execute PowerShell - KLEB"** task
     - **OT Branch** → **"Execute PowerShell - OT"** task
     - **DEV Branch** → **"Execute PowerShell - DEV"** task

### Step 6: Visual Verification

9. **Schema Layout Verification**
   ```
   [Start] → [Validate Input] → [Determine Environment] → [Execute PowerShell] → [End]
                                        ↓
                               ┌─── PROD ────┐
                               ├─── KLEB ────┤  → [Single PowerShell Task]
                               ├─── OT ──────┤     (receives targetEnvironment)
                               └─── DEV ─────┘
   ```

10. **Properties Summary Check**
    - **Decision Element Name**: `Determine Environment`
    - **4 Conditions configured** in priority order
    - **Output attribute**: `targetEnvironment` (string)
    - **All branches connected** to execution task(s)

## 🔧 Detailed UI Configuration Screenshots Guide

### Decision Logic Configuration Table

| Order | Name | Condition | Result | Description |
|-------|------|-----------|--------|-------------|
| 1 | PROD Branch | `folderPath.indexOf("prod") >= 0` | PROD | Production environment |
| 2 | KLEB Branch | `folderPath.indexOf("kleb") >= 0` | KLEB | KLEB environment |
| 3 | OT Branch | `folderPath.indexOf("ot") >= 0` | OT | OT environment |
| 4 | DEV Branch (Default) | `true` | DEV | Default environment |

### Binding Configuration

**Output Bindings:**
```
Attribute Name: targetEnvironment
Type: string
Bind to: Decision result
Value: [Automatically set based on decision logic]
```

### Input Bindings (from previous task)

**Required Input from "Validate Input" task:**
```
folderPath (string) - VM folder path in lowercase for environment detection
```

## 🎨 Visual Design Tips

### Schema Layout Best Practices

1. **Alignment**: Keep Decision Element centered between input and output tasks
2. **Spacing**: Provide adequate space for decision branch labels
3. **Colors**: Decision Elements typically show in **yellow/orange** in the schema
4. **Labels**: Ensure branch labels are clearly visible (PROD, KLEB, OT, DEV)

### Decision Branch Visualization

In the Aria Orchestrator Designer, you'll see:
- **Decision Element** as diamond shape
- **Four output connectors** (one per decision result)
- **Branch labels** showing the decision result (PROD, KLEB, etc.)
- **Green arrows** indicating successful path connections

## ⚙️ Decision Type: Simple vs Advanced Mode

### Why Use Advanced Mode (Simple = OFF)?

**For VMTags Environment Detection: Use ADVANCED Mode**

#### Simple Mode Limitations ❌
```
Simple Mode only supports basic comparisons:
- folderPath == "production"     ✅ (exact match only)
- folderPath != "development"    ✅ (basic inequality)
- folderPath > "a"               ✅ (basic comparison)

Simple Mode does NOT support:
- folderPath.indexOf("prod") >= 0  ❌ (method calls not allowed)
- folderPath.includes("kleb")      ❌ (method calls not allowed)
- folderPath.toLowerCase()         ❌ (method calls not allowed)
```

#### Advanced Mode Capabilities ✅
```
Advanced Mode supports full JavaScript expressions:
- folderPath.indexOf("prod") >= 0   ✅ (method calls allowed)
- folderPath.includes("kleb")       ✅ (built-in string methods)
- folderPath.match(/prod/i)         ✅ (regular expressions)
- folderPath.split("/").length > 2  ✅ (complex expressions)
```

### Configuration Comparison

| Feature | Simple Mode | Advanced Mode |
|---------|-------------|---------------|
| **Basic Equality** | `folderPath == "prod"` | `folderPath == "prod"` |
| **String Methods** | ❌ Not Supported | ✅ `folderPath.indexOf("prod") >= 0` |
| **Case Insensitive** | ❌ Manual conversion needed | ✅ Built-in methods |
| **Pattern Matching** | ❌ Exact match only | ✅ Partial string matching |
| **Complex Logic** | ❌ Limited operators | ✅ Full JavaScript expressions |

### VMTags Requirements

Our environment detection needs **Advanced Mode** because we use:

1. **String Method Calls**: `folderPath.indexOf("prod") >= 0`
2. **Partial String Matching**: Looking for environment names within folder paths
3. **Case-Insensitive Matching**: Folder paths are lowercase, need flexible matching
4. **Complex Expressions**: Multiple conditions with different operators

### UI Configuration Steps for Advanced Mode

1. **Select Decision Element** in workflow schema
2. **Properties Panel** → **General Tab**
3. **Decision Type section**:
   - **UNCHECK** the "Simple" checkbox ✅
   - This enables **Advanced Mode** with full JavaScript support

4. **Verify Advanced Mode** is active:
   - **Simple checkbox** = UNCHECKED ☐
   - **Decision Logic tab** shows JavaScript expression editor
   - **Conditions** can use method calls like `indexOf()`

### Validation in Decision Logic Tab

When **Advanced Mode** is enabled, you should see:
- ✅ **JavaScript expression editor** for conditions
- ✅ **Syntax highlighting** for JavaScript code
- ✅ **Support for complex expressions** like `indexOf()`, `includes()`
- ✅ **Method completion** for string operations

When **Simple Mode** is enabled, you'll see:
- ❌ **Basic comparison dropdowns** (equals, not equals, greater than)
- ❌ **Limited to simple value comparisons**
- ❌ **No method calls** or complex expressions allowed

## 🧪 Testing the Decision Element

### Step 7: Test Decision Logic

11. **Run Workflow in Test Mode**
    - Click **"Run"** button in workflow designer
    - Provide test inputs:
      - **VM**: Select a test VM from PROD folder
      - **Action**: `UpdatePermissions`

12. **Verify Decision Path**
    - In execution logs, look for:
      ```
      [INFO] VM Folder Path for decision: production/webservers/iis
      [INFO] Decision result: PROD
      [INFO] Environment determined: PROD
      ```

13. **Test Each Environment**
    - Test VMs from different folder paths:
      - **PROD path**: `/production/servers/web01` → Should select PROD
      - **KLEB path**: `/kleb/database/sql01` → Should select KLEB
      - **OT path**: `/ot/security/firewall01` → Should select OT
      - **Other path**: `/development/test/vm01` → Should select DEV (default)

## 🐛 Troubleshooting Decision Element

### Common Issues and Solutions

**Issue 1: "folderPath is undefined"**
```
Solution: Two-part fix required:

Part A: Ensure JavaScript variable is created in "Validate Input" task:
folderPath = pathParts.join("/").toLowerCase();

Part B: CRITICAL - Configure Output Binding:
1. Select "Validate Input" scriptable task
2. Properties → Binding tab → Out Attributes
3. Add output binding: Name=folderPath, Type=string, Bind to=folderPath

Without Part B, the Decision Element cannot access the variable!
```

**Issue 2: Decision always selects DEV**
```
Solution: Check condition order - more specific conditions (PROD, KLEB, OT) must be higher priority than the default (true) condition.
```

**Issue 3: Multiple conditions match**
```
Solution: Decision Elements use priority order. First matching condition wins. Ensure PROD is priority 1, KLEB is 2, etc.
```

**Issue 4: targetEnvironment is empty**
```
Solution: Verify Output Binding is configured:
- Attribute Name: targetEnvironment
- Bind to: Decision result
```

**Issue 5: "Method 'indexOf' not recognized" or "Syntax Error"**
```
Solution: Ensure Advanced Mode is enabled:
1. Select Decision Element
2. Properties → General Tab
3. UNCHECK "Simple" checkbox
4. Decision Type should show "Advanced"
5. Re-enter conditions with JavaScript syntax
```

**Issue 6: Conditions show dropdown menus instead of text editor**
```
Solution: You're in Simple Mode - switch to Advanced:
- Simple Mode: Shows dropdowns (equals, not equals, etc.)
- Advanced Mode: Shows JavaScript text editor
- UNCHECK "Simple" to enable Advanced Mode
```

## 📊 Decision Element Advantages

### Before (JavaScript Logic):
- ❌ Hidden logic in scriptable task code
- ❌ Hard to modify without touching JavaScript
- ❌ No visual indication of decision paths
- ❌ Difficult to debug which condition was triggered

### After (Decision Element):
- ✅ **Visual logic flow** in workflow schema
- ✅ **Easy modification** through UI configuration
- ✅ **Clear decision paths** with branch labels
- ✅ **Execution tracking** shows which branch was taken
- ✅ **Better performance** - optimized for conditional logic
- ✅ **Professional design** following Aria Orchestrator best practices

## 🚀 Final Workflow Structure

After completing this setup, your workflow will have:

```
Input Parameters:
├── vm (VC:VirtualMachine)
├── action (string)
└── environment (string) [optional - will be auto-detected]

Workflow Flow:
├── Start
├── Validate Input (Scriptable Task)
│   └── Creates: vmName, action, folderPath
├── Determine Environment (Decision Element)
│   ├── PROD Branch (folderPath contains "prod")
│   ├── KLEB Branch (folderPath contains "kleb")
│   ├── OT Branch (folderPath contains "ot")
│   └── DEV Branch (default)
│   └── Sets: targetEnvironment
├── Execute PowerShell (Scriptable Task)
│   └── Uses: vmName, action, targetEnvironment
└── End
```

This creates a **professional, maintainable workflow** that clearly shows the environment detection logic and can be easily modified through the Aria Orchestrator UI without touching any JavaScript code!

## 📝 Configuration Checklist

- [ ] Decision Element added to workflow schema
- [ ] Decision Element named "Determine Environment"
- [ ] Four conditions configured in priority order
- [ ] All conditions use correct folderPath.indexOf() syntax
- [ ] Decision results set: PROD, KLEB, OT, DEV
- [ ] Output binding configured: targetEnvironment (string)
- [ ] Input connection from "Validate Input" task
- [ ] Output connections to "Execute PowerShell" task(s)
- [ ] Workflow tested with VMs from different folder paths
- [ ] Execution logs confirm correct environment detection

**✅ Decision Element setup complete when all checklist items verified!**