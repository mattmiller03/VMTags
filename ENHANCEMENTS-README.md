# VMTags v2.0 - Inventory Visibility & Container Permissions Enhancements

## Overview

Two major enhancements have been added to address user visibility issues and tag propagation concerns:

1. **Inventory Visibility**: Allows users to navigate the entire vCenter inventory structure while only having actual permissions on their assigned VMs
2. **Container Permissions**: Ensures that when tags are assigned to folders/resource pools, permissions are also assigned on those containers

## Problem Statements

### Issue 1: Users Cannot See Inventory Structure

**Problem**: Users (especially OS admins) could only see VMs they had permissions on, but couldn't navigate folders, resource pools, clusters, or datacenters in the vCenter web client. This made it difficult to locate VMs and understand the organizational structure.

**Root Cause**: vCenter requires permissions on parent objects to navigate the inventory tree. Without Read-Only access on containers, users only see a flat list of VMs.

### Issue 2: Tags on Containers Don't Show Assigned Permissions

**Problem**: When administrators tag a folder or resource pool, the tag inheritance feature propagates the tag to child VMs and assigns permissions on those VMs. However, the folder/resource pool itself doesn't get permissions assigned, which can be confusing when reviewing permission structure.

**Expected Behavior**: When a folder or resource pool is tagged, both the container AND the child VMs should have appropriate permissions assigned.

## Solutions Implemented

### Feature 1: Inventory Visibility

**New Function**: `Grant-InventoryVisibility`

This function grants non-propagating **Read-Only** permissions on all inventory containers (Datacenters, Clusters, Folders, Resource Pools) to **OS admin security groups only**.

**Key Characteristics**:
- Grants Read-Only role (built-in vCenter role) **at vCenter root level**
- Permission **propagates** to all child objects (`Propagate:$true`)
- **Single operation per OS admin group** - extremely efficient
- Users can navigate the entire inventory tree
- Users only have actual role permissions on their specific VMs
- **Only applies to OS admin groups** (from OS Mappings CSV)
- **App admin groups are excluded** - they only see their assigned VMs and tagged containers
- No need to handle system objects - propagation handles everything automatically

**Usage**:
```powershell
# Enable inventory visibility (via Launcher - Recommended)
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials -EnableInventoryVisibility

# Direct script execution
.\Scripts\set-VMtagPermissions.ps1 `
    -vCenterServer "vcenter.domain.com" `
    -Credential $cred `
    -Environment "PROD" `
    -AppPermissionsCsvPath ".\Data\PROD\AppTagPermissions.csv" `
    -OsMappingCsvPath ".\Data\PROD\OS-Mappings.csv" `
    -EnableInventoryVisibility
```

**What It Does**:
1. Collects unique security groups **from OS Mappings CSV ONLY** (OS admins)
   - **App admin groups are NOT included** - they only see their assigned VMs/containers
2. For each OS admin security group, grants **single Read-Only permission at vCenter root** with propagation
   - **Single operation per group** - extremely fast and efficient
   - Automatically applies to ALL child objects in the inventory hierarchy
   - No need to iterate through hundreds/thousands of containers
3. Propagation automatically covers:
   - All Datacenters
   - All Clusters
   - All VM Folders
   - All Resource Pools
   - All VMs
4. Skips groups that already have Read-Only at root level

**Example Results**:
```
=== Granting Inventory Visibility at vCenter Root ===
Security groups to process: 3
Method: Single Read-Only permission at root with propagation (efficient approach)
vCenter Server: vcenter.domain.com
Granting inventory visibility to: DLA-Prod\Windows-Admins
Successfully granted Read-Only permission at root to DLA-Prod\Windows-Admins (propagates to all objects)
Granting inventory visibility to: DLA-Prod\Linux-Admins
Successfully granted Read-Only permission at root to DLA-Prod\Linux-Admins (propagates to all objects)
Granting inventory visibility to: DLA-Prod\Unix-Admins
Successfully granted Read-Only permission at root to DLA-Prod\Unix-Admins (propagates to all objects)

=== Inventory Visibility Results ===
Root-Level Permissions Granted: 3
Visibility Grants Skipped (already exist): 0
Visibility Grant Errors: 0
Note: Root permissions propagate to all child objects (datacenters, clusters, folders, resource pools, VMs)
```

**Efficiency Benefits**:
- **Before**: Hundreds/thousands of individual permission grants (slow, error-prone)
- **After**: One permission grant per OS admin group (fast, clean, simple)
- **Example**: 3 OS groups × 1 permission each = 3 operations (instead of 3 groups × 200+ objects = 600+ operations)

**Who Gets Inventory Visibility**:
- ✅ **OS Admin Groups** (from OS-Mappings CSV) - Full inventory navigation via root-level Read-Only
- ❌ **App Admin Groups** (from AppPermissions CSV) - Only their assigned VMs/containers

### Feature 2: Container Permissions

**New Function**: `Assign-ContainerPermission`

This function assigns permissions on folders and resource pools when those containers have tags assigned, ensuring permissions exist on both the container and child VMs.

**Key Characteristics**:
- Assigns the same role on the container as is assigned on child VMs
- Permissions are **non-propagating** by default (`Propagate:$false`)
- Ensures administrators can see who has access to a container
- Makes permission auditing clearer
- **Enabled by default** (use `-EnableContainerPermissions:$false` to disable)

**Modified Function**: `Process-FolderBasedPermissions`

Enhanced to assign permissions on folders and resource pools before processing child VMs.

**Usage**:
```powershell
# Container permissions are ENABLED by default (via Launcher - Recommended)
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials

# Explicitly enable
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials -EnableContainerPermissions

# Disable if you only want VM permissions
.\VM_TagPermissions_Launcher.ps1 -Environment PROD -UseStoredCredentials -EnableContainerPermissions:$false

# Direct script execution
.\Scripts\set-VMtagPermissions.ps1 `
    -vCenterServer "vcenter.domain.com" `
    -Credential $cred `
    -Environment "PROD" `
    -AppPermissionsCsvPath ".\Data\PROD\AppTagPermissions.csv" `
    -OsMappingCsvPath ".\Data\PROD\OS-Mappings.csv" `
    -EnableContainerPermissions
```

**What It Does**:
1. Scans all folders and resource pools for application tags
2. For each tagged container:
   - Assigns the corresponding role to the security group on the **container itself**
   - Then assigns the same role to the security group on all **child VMs**
3. Permissions are non-propagating so they must be explicitly assigned on each object
4. Logs all container permission assignments for auditing

**Example Log Output**:
```
Folder 'Production/WebServers': Assigning permissions on the folder container itself
Folder 'Production/WebServers': Assigned Support-Admin-WebTeam permission to DLA-PROD\WebServerAdmins on container
Folder 'Production/WebServers': Found 45 VMs to process
Folder 'Production/WebServers': Applied permission to VM 'web01' for tag 'WebTeam' (role: Support-Admin-WebTeam)
```

## New Script Parameters

### set-VMtagPermissions.ps1

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-EnableInventoryVisibility` | Switch | `$false` | Grant Read-Only permissions on all inventory containers to security groups |
| `-EnableContainerPermissions` | Switch | `$true` | Assign permissions on tagged folders/resource pools (not just VMs) |

### VM_TagPermissions_Launcher.ps1

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-EnableInventoryVisibility` | Switch | `$false` | Grant Read-Only permissions on all inventory containers to security groups |
| `-EnableContainerPermissions` | Switch | `$true` | Assign permissions on tagged folders/resource pools (not just VMs) |

## Permissions Architecture

### Without Enhancements (Original Behavior)
```
Datacenter (no permissions)
├── Folder: Production (no permissions)
│   └── VM: web01 (Support-Admin-WebTeam: Full permissions)
└── ResourcePool: WebServers (no permissions)
    └── VM: web02 (Support-Admin-WebTeam: Full permissions)

User Experience: Users see web01 and web02 in a flat list, cannot navigate folder structure
```

### With Inventory Visibility Only
```
Datacenter (WebServerAdmins: Read-Only, no propagation)
├── Folder: Production (WebServerAdmins: Read-Only, no propagation)
│   └── VM: web01 (Support-Admin-WebTeam: Full permissions)
└── ResourcePool: WebServers (WebServerAdmins: Read-Only, no propagation)
    └── VM: web02 (Support-Admin-WebTeam: Full permissions)

User Experience: Users can navigate entire tree, but only have full permissions on their VMs
```

### With Container Permissions Only
```
Datacenter (no permissions)
├── Folder: Production [Tagged: WebTeam] (Support-Admin-WebTeam: Full permissions, no propagation)
│   └── VM: web01 (Support-Admin-WebTeam: Full permissions)
└── ResourcePool: WebServers [Tagged: WebTeam] (Support-Admin-WebTeam: Full permissions, no propagation)
    └── VM: web02 (Support-Admin-WebTeam: Full permissions)

User Experience: Users see their VMs, and permissions are visible on tagged containers
```

### With Both Features Enabled (Recommended)
```
Datacenter (WindowsAdmins: Read-Only, no propagation)  [OS Admin group gets visibility]
├── Folder: Production [Tagged: WebTeam] (Support-Admin-WebTeam: Full permissions, no propagation)
│   └── VM: web01 (Support-Admin-WebTeam: Full permissions)
└── ResourcePool: WebServers [Tagged: WebTeam] (Support-Admin-WebTeam: Full permissions, no propagation)
    └── VM: web02 (Support-Admin-WebTeam: Full permissions)

User Experience:
- OS Admins: Can navigate entire tree, see all organizational structure
- App Admins: See their assigned containers and VMs only, have full permissions on those objects
```

**Important**: Inventory visibility is granted to **OS admin groups ONLY** (from OS-Mappings CSV), not app admin groups (from AppPermissions CSV). This ensures:
- OS administrators can see and navigate the entire inventory for their administrative duties
- Application administrators only see the VMs and containers they manage
- Security principle of least privilege is maintained

## Recommended Configuration

### For Production Environments
```powershell
.\VM_TagPermissions_Launcher.ps1 `
    -Environment PROD `
    -UseStoredCredentials `
    -EnableInventoryVisibility `
    -EnableContainerPermissions
```

### For Testing/Development
```powershell
.\VM_TagPermissions_Launcher.ps1 `
    -Environment DEV `
    -UseStoredCredentials `
    -EnableInventoryVisibility `
    -EnableContainerPermissions `
    -ForceDebug
```

## Performance Considerations

### Inventory Visibility
- **One-time operation per security group**: After initial execution, subsequent runs skip existing permissions
- **Impact**: Minimal - grants are fast and only process unique security groups
- **Recommended**: Run with every execution to ensure new security groups get visibility

### Container Permissions
- **Operation per tagged container**: Assigns permissions on folders/resource pools with tags
- **Impact**: Low - only processes containers that have application tags
- **Recommended**: Enabled by default, disable only if you have a specific reason

## Troubleshooting

### Users Still Cannot See Inventory

**Check 1**: Verify inventory visibility was enabled
```powershell
# Look for this in logs
=== Granting Inventory Visibility to Security Groups ===
Found X unique security groups to grant inventory visibility
```

**Check 2**: Verify permissions were assigned
```powershell
# In vCenter, check permissions on a folder
# Should see: DOMAIN\GroupName with Read-Only role (This object only)
```

**Check 3**: Users may need to log out and log back in to vCenter for permissions to take effect

### No Errors About System Objects!

**Previous Approach** (individual container grants):
- Generated errors/warnings for system folders and resource pools
- Required complex filtering logic
- Slow due to iterating through hundreds of objects

**Current Approach** (root-level grant with propagation):
- No system object errors - propagation handles everything automatically
- Fast - single permission grant per group
- Simple - no special handling needed

**You should NOT see**:
- ❌ Warnings about system folders
- ❌ Warnings about Resources pool
- ❌ Warnings about vCLS objects

**You SHOULD see**:
- ✅ Clean execution with 3-5 permission grants total
- ✅ "Root-Level Permissions Granted: X" message
- ✅ "Note: Root permissions propagate to all child objects"

### Container Permissions Not Showing

**Check 1**: Verify feature is enabled (it's enabled by default)
```powershell
# Look for this in logs (if you see this, it's disabled)
Folder 'FolderName': Container permissions disabled (use -EnableContainerPermissions)
```

**Check 2**: Verify containers have tags
```powershell
# Look for this in logs
Folder 'FolderName': Found X app tags
```

**Check 3**: Check permission assignment logs
```powershell
# Look for this in logs
Folder 'FolderName': Assigned RoleName permission to DOMAIN\GroupName on container
```

## Security Considerations

1. **Read-Only role is low privilege**: The built-in Read-Only role has minimal permissions (View only, no modifications)
2. **Non-propagating permissions**: Permissions don't cascade to child objects, providing fine-grained control
3. **No elevated access**: These enhancements don't grant additional access to VMs, only improve navigation
4. **Audit trail**: All permission assignments are logged for compliance review

## Migration Guide

### Existing Deployments

1. **Test in DEV first**: Run with both features enabled in a development environment
2. **Review permission changes**: Use ForceDebug to see detailed permission assignment logs
3. **Verify user experience**: Have test users log in and confirm they can navigate inventory
4. **Roll out to production**: Enable features in production after successful testing

### Disabling Features

If you need to revert to original behavior:

```powershell
# Disable both features
.\VM_TagPermissions_Launcher.ps1 `
    -Environment PROD `
    -UseStoredCredentials `
    -EnableInventoryVisibility:$false `
    -EnableContainerPermissions:$false
```

**Note**: This prevents NEW permissions from being assigned. To remove existing permissions, you'd need to manually remove them in vCenter or use `Remove-VIPermission` cmdlets.

## Summary

These enhancements significantly improve the user experience by:

1. **Fixing navigation issues**: Users can now see the entire vCenter inventory structure
2. **Improving permission clarity**: Permissions are visible on tagged containers, not just VMs
3. **Maintaining security**: Read-Only access for navigation, full role permissions only on assigned objects
4. **Preserving existing behavior**: Container permissions enabled by default, inventory visibility opt-in

Both features are designed to work together but can be used independently based on your requirements.
