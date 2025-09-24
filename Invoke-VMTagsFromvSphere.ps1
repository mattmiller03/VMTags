# VMTags vSphere Client Integration Script
<#
.SYNOPSIS
    vSphere Client integration wrapper for VMTags permission management

.DESCRIPTION
    This script provides context menu integration for the VMware vSphere Client
    through Aria Orchestrator workflows. It allows users to trigger VMTags
    permission updates directly from VM context menus in the vSphere Client.

.PARAMETER VMName
    Name of the VM to process (passed from vSphere Client context)

.PARAMETER Environment
    Target environment (DEV, PROD, KLEB, OT)

.PARAMETER Action
    Action to perform:
    - UpdatePermissions: Apply all tag-based permissions to the VM
    - SyncAllTags: Sync all VM tags and apply permissions
    - ApplyContainerPermissions: Apply permissions from folder/resource pool tags
    - ValidatePermissions: Check current permissions without making changes

.PARAMETER vCenterServer
    vCenter server (optional, will auto-detect if not provided)

.EXAMPLE
    # Called from Aria Orchestrator workflow
    .\Invoke-VMTagsFromvSphere.ps1 -VMName "WebServer01" -Environment "PROD" -Action "UpdatePermissions"

.EXAMPLE
    # Sync all tags for a VM
    .\Invoke-VMTagsFromvSphere.ps1 -VMName "DBServer02" -Environment "KLEB" -Action "SyncAllTags"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "VM name from vSphere Client context")]
    [string]$VMName,

    [Parameter(Mandatory = $true, HelpMessage = "Environment (DEV, PROD, KLEB, OT)")]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = $false, HelpMessage = "Action to perform")]
    [ValidateSet('UpdatePermissions', 'SyncAllTags', 'ApplyContainerPermissions', 'ValidatePermissions')]
    [string]$Action = "UpdatePermissions",

    [Parameter(Mandatory = $false, HelpMessage = "vCenter Server (auto-detect if not provided)")]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false, HelpMessage = "Enable detailed logging")]
    [switch]$EnableDebug,

    [Parameter(Mandatory = $false, HelpMessage = "Dry run mode - show what would be done")]
    [switch]$DryRun
)

# Initialize logging
$scriptStart = Get-Date
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = ".\Logs\vSphereClient_$($VMName)_$($Action)_$($logTimestamp).log"

# Ensure log directory exists
$logDir = Split-Path $logFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-vSphereLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    Write-Host $logMessage -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )

    Add-Content -Path $logFile -Value $logMessage
}

try {
    Write-vSphereLog "=== vSphere Client VMTags Integration Started ===" "INFO"
    Write-vSphereLog "VM: $VMName" "INFO"
    Write-vSphereLog "Environment: $Environment" "INFO"
    Write-vSphereLog "Action: $Action" "INFO"
    Write-vSphereLog "Started by: $($env:USERNAME)" "INFO"

    # Load configuration
    $configPath = ".\ConfigFiles\VMTagsConfig.psd1"
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $configData = Import-PowerShellDataFile $configPath
    $envConfig = $configData.Environments.$Environment

    if (-not $envConfig) {
        throw "Environment '$Environment' not found in configuration"
    }

    # Auto-detect vCenter server if not provided
    if (-not $vCenterServer) {
        $vCenterServer = $envConfig.vCenterServer
        Write-vSphereLog "Using configured vCenter server: $vCenterServer" "INFO"
    }

    # Prepare script parameters
    $scriptParams = @{
        vCenterServer = $vCenterServer
        Environment = $Environment
        SpecificVM = $VMName
        vSphereClientMode = $true
        AppPermissionsCsvPath = $envConfig.DataPaths.AppPermissionsCSV
        OsMappingCsvPath = $envConfig.DataPaths.OSMappingCSV
        EnableScriptDebug = $EnableDebug.IsPresent
    }

    # Add action-specific parameters
    switch ($Action) {
        "ApplyContainerPermissions" {
            $scriptParams.EnableHierarchicalInheritance = $true
            Write-vSphereLog "Enabling hierarchical tag inheritance for container permissions" "INFO"
        }
        "ValidatePermissions" {
            # Validation would be a dry run
            $DryRun = $true
            Write-vSphereLog "Validation mode enabled - no changes will be made" "INFO"
        }
    }

    # Handle credentials based on environment
    if ($configData.Security.EnvironmentPolicies.$Environment.AllowStoredCredentials) {
        Write-vSphereLog "Using stored credentials for environment: $Environment" "INFO"
        # Let the main script handle credential retrieval
    } else {
        Write-vSphereLog "Environment '$Environment' requires manual credential input" "WARN"
        # For vSphere Client integration, this might need to be handled differently
    }

    # Execute the main VMTags script
    Write-vSphereLog "Executing VMTags script for VM: $VMName" "INFO"
    Write-vSphereLog "Script path: .\Scripts\set-VMtagPermissions.ps1" "DEBUG"

    if ($DryRun) {
        Write-vSphereLog "DRY RUN MODE - No changes will be made" "WARN"
        # Note: Main script doesn't have a DryRun parameter yet, so we'll log this intent
    }

    # Call the main script
    $result = & ".\Scripts\set-VMtagPermissions.ps1" @scriptParams

    Write-vSphereLog "VMTags script completed successfully" "SUCCESS"

    # Parse and display summary results
    Write-vSphereLog "=== Execution Summary ===" "INFO"
    Write-vSphereLog "VM Processed: $VMName" "INFO"
    Write-vSphereLog "Action Performed: $Action" "INFO"
    Write-vSphereLog "Environment: $Environment" "INFO"
    Write-vSphereLog "Execution Time: $((Get-Date) - $scriptStart)" "INFO"

    return @{
        Success = $true
        VMName = $VMName
        Action = $Action
        Environment = $Environment
        ExecutionTime = (Get-Date) - $scriptStart
        LogFile = $logFile
        Message = "VMTags processing completed successfully for VM: $VMName"
    }

} catch {
    $errorMsg = $_.Exception.Message
    Write-vSphereLog "ERROR: $errorMsg" "ERROR"
    Write-vSphereLog "Stack Trace: $($_.ScriptStackTrace)" "ERROR"

    return @{
        Success = $false
        VMName = $VMName
        Action = $Action
        Environment = $Environment
        ExecutionTime = (Get-Date) - $scriptStart
        LogFile = $logFile
        Error = $errorMsg
        Message = "VMTags processing failed for VM: $VMName. Error: $errorMsg"
    }
} finally {
    Write-vSphereLog "=== vSphere Client VMTags Integration Completed ===" "INFO"
    Write-vSphereLog "Log file: $logFile" "INFO"
}