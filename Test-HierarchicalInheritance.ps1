<#
.SYNOPSIS
    Test script for hierarchical tag inheritance functionality
.DESCRIPTION
    This script tests the hierarchical tag inheritance feature that automatically
    applies tags from parent containers (folders and resource pools) to VMs.

    Use this script to validate inheritance behavior before enabling it in production.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$vCenterServer = "",

    [Parameter(Mandatory = $false)]
    [switch]$DryRunOnly,

    [Parameter(Mandatory = $false)]
    [string]$TestVMName = "*",

    [Parameter(Mandatory = $false)]
    [string]$TestCategories = "App"
)

Write-Host "`n=== Hierarchical Tag Inheritance Test ===" -ForegroundColor Cyan
Write-Host "Environment: $Environment" -ForegroundColor White
Write-Host "Test VM Pattern: $TestVMName" -ForegroundColor White
Write-Host "Test Categories: $TestCategories" -ForegroundColor White

try {
    # Load configuration
    $configPath = Join-Path $PSScriptRoot "ConfigFiles\VMTagsConfig.psd1"
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $configData = Import-PowerShellDataFile -Path $configPath
    $envConfig = $configData.Environments[$Environment]

    if (-not $envConfig) {
        throw "Environment '$Environment' not found in configuration"
    }

    # Determine vCenter server
    if ([string]::IsNullOrEmpty($vCenterServer)) {
        if ($envConfig.vCenterServers -and $envConfig.vCenterServers.Count -gt 0) {
            $vCenterServer = $envConfig.vCenterServers[0].Server
        } else {
            $vCenterServer = $envConfig.vCenterServer
        }
    }

    Write-Host "`nvCenter Server: $vCenterServer" -ForegroundColor White

    # Check current inheritance configuration
    Write-Host "`n=== Current Inheritance Configuration ===" -ForegroundColor Yellow

    if ($configData.HierarchicalInheritance) {
        $inheritConfig = $configData.HierarchicalInheritance
        Write-Host "Inheritance Enabled: $($inheritConfig.Enabled)" -ForegroundColor White
        Write-Host "Inheritable Categories: $($inheritConfig.InheritableCategories -join ', ')" -ForegroundColor White
        Write-Host "Inherit From Folders: $($inheritConfig.InheritFromFolders)" -ForegroundColor White
        Write-Host "Inherit From Resource Pools: $($inheritConfig.InheritFromResourcePools)" -ForegroundColor White
    } else {
        Write-Host "Hierarchical inheritance configuration not found" -ForegroundColor Red
    }

    # Test launcher execution
    Write-Host "`n=== Testing Launcher Execution ===" -ForegroundColor Yellow

    if ($DryRunOnly) {
        Write-Host "Testing launcher dry run mode..." -ForegroundColor White

        $launcherArgs = @{
            Environment = $Environment
            DryRun = $true
            UseStoredCredentials = $true
            ForceDebug = $true
        }

        if (-not [string]::IsNullOrEmpty($vCenterServer)) {
            $launcherArgs.OverrideVCenter = $vCenterServer
        }

        Write-Host "Launcher arguments:" -ForegroundColor Gray
        $launcherArgs.GetEnumerator() | ForEach-Object {
            Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor Gray
        }

        Write-Host "`nExecuting launcher in dry run mode..." -ForegroundColor White
        try {
            & "$PSScriptRoot\VM_TagPermissions_Launcher.ps1" @launcherArgs
            Write-Host "Launcher dry run completed successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "Launcher dry run failed: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Use -DryRunOnly switch to test launcher execution" -ForegroundColor Yellow
    }

    # Show usage examples
    Write-Host "`n=== Usage Examples ===" -ForegroundColor Yellow
    Write-Host "1. Enable inheritance in configuration:" -ForegroundColor White
    Write-Host @"
# In ConfigFiles/VMTagsConfig.psd1:
HierarchicalInheritance = @{
    Enabled = `$true
    InheritableCategories = @("App", "Function")
    InheritFromFolders = `$true
    InheritFromResourcePools = `$true
}
"@ -ForegroundColor Gray

    Write-Host "`n2. Test inheritance with dry run:" -ForegroundColor White
    Write-Host ".\VM_TagPermissions_Launcher.ps1 -Environment $Environment -UseStoredCredentials -DryRun" -ForegroundColor Gray

    Write-Host "`n3. Run inheritance with specific categories:" -ForegroundColor White
    Write-Host ".\Scripts\set-VMtagPermissions.ps1 -vCenterServer $vCenterServer -Environment $Environment -EnableHierarchicalInheritance -InheritanceCategories `"App,Function`" -InheritanceDryRun" -ForegroundColor Gray

    Write-Host "`n4. Full execution with inheritance:" -ForegroundColor White
    Write-Host ".\VM_TagPermissions_Launcher.ps1 -Environment $Environment -UseStoredCredentials" -ForegroundColor Gray

    # Show inheritance workflow
    Write-Host "`n=== Hierarchical Inheritance Workflow ===" -ForegroundColor Yellow
    Write-Host "1. Tag a VM folder or resource pool with an app-admins tag" -ForegroundColor White
    Write-Host "2. Enable hierarchical inheritance in configuration" -ForegroundColor White
    Write-Host "3. Run the script with inheritance enabled" -ForegroundColor White
    Write-Host "4. All VMs in that folder/resource pool automatically get the tag" -ForegroundColor White
    Write-Host "5. Permissions are then applied based on the inherited tags" -ForegroundColor White

    Write-Host "`n=== Inheritance Rules ===" -ForegroundColor Yellow
    Write-Host "• VMs inherit tags from their immediate and parent folders" -ForegroundColor Green
    Write-Host "• VMs inherit tags from their resource pool hierarchy" -ForegroundColor Green
    Write-Host "• Only specified categories are inherited (default: App tags)" -ForegroundColor Green
    Write-Host "• Existing VM tags are not overwritten" -ForegroundColor Green
    Write-Host "• VMs with existing tags in the same category skip inheritance" -ForegroundColor Green
    Write-Host "• Inheritance is processed before permission assignment" -ForegroundColor Green

    Write-Host "`n=== Test Complete ===" -ForegroundColor Green
    Write-Host "Use the examples above to test hierarchical tag inheritance in your environment." -ForegroundColor White

} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}