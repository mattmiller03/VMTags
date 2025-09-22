<#
.SYNOPSIS
    Test script for validating folder and resource pool based permission propagation functionality

.DESCRIPTION
    This script provides validation steps to ensure the folder and resource pool based permission
    propagation feature is working correctly. Run this after implementing the
    solution to verify that permissions are being applied to VMs based on
    folder and resource pool tags.

.PARAMETER Environment
    Environment to test (DEV, PROD, KLEB, OT)

.PARAMETER DryRun
    Run in validation mode without making changes

.EXAMPLE
    .\Test-FolderBasedPermissions.ps1 -Environment DEV -DryRun
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("DEV", "PROD", "KLEB", "OT")]
    [string]$Environment,

    [switch]$DryRun
)

Write-Host "`n=== Folder and Resource Pool Based Permission Propagation Test ===" -ForegroundColor Cyan

try {
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

    Write-Host "`n=== Environment Configuration ===" -ForegroundColor Yellow
    Write-Host "Environment: $Environment" -ForegroundColor White
    Write-Host "vCenter Server: $($envConfig.vCenterServer)" -ForegroundColor White
    Write-Host "App Tag Category: $($envConfig.TagCategories.App)" -ForegroundColor White

    # Test prerequisites
    Write-Host "`n=== Prerequisites Check ===" -ForegroundColor Yellow

    # Check if PowerCLI is available
    try {
        Get-Module VMware.PowerCLI -ListAvailable | Out-Null
        Write-Host "✓ PowerCLI module available" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ PowerCLI module not found" -ForegroundColor Red
        return
    }

    # Check configuration files
    $appPermissionsCsv = $envConfig.DataPaths.AppPermissionsCSV
    if (Test-Path $appPermissionsCsv) {
        Write-Host "✓ App permissions CSV found: $appPermissionsCsv" -ForegroundColor Green
    }
    else {
        Write-Host "✗ App permissions CSV not found: $appPermissionsCsv" -ForegroundColor Red
    }

    # Validation instructions
    Write-Host "`n=== Validation Steps ===" -ForegroundColor Yellow
    Write-Host "To validate folder and resource pool based permission propagation:" -ForegroundColor White
    Write-Host ""
    Write-Host "1A. SETUP FOLDER TEST: Create a test folder with application tags:" -ForegroundColor White
    Write-Host "    • Create a VM folder named 'TestAppFolder'" -ForegroundColor Gray
    Write-Host "    • Apply an application admin tag to the folder (e.g., 'Exchange-admins')" -ForegroundColor Gray
    Write-Host "    • Place one or more test VMs in this folder" -ForegroundColor Gray
    Write-Host ""
    Write-Host "1B. SETUP RESOURCE POOL TEST: Create a test resource pool with application tags:" -ForegroundColor White
    Write-Host "    • Create a resource pool named 'TestAppResourcePool'" -ForegroundColor Gray
    Write-Host "    • Apply an application admin tag to the resource pool (e.g., 'ACAS-Admins')" -ForegroundColor Gray
    Write-Host "    • Place one or more test VMs in this resource pool" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. BEFORE: Check existing permissions on test VMs:" -ForegroundColor White
    Write-Host "   Get-VM -Location 'TestAppFolder' | Get-VIPermission" -ForegroundColor Gray
    Write-Host "   Get-VM -Location 'TestAppResourcePool' | Get-VIPermission" -ForegroundColor Gray
    Write-Host ""
    Write-Host "3. EXECUTE: Run the main script with container processing:" -ForegroundColor White
    Write-Host "   .\VM_TagPermissions_Launcher.ps1 -Environment $Environment -UseStoredCredentials -ForceDebug" -ForegroundColor Gray
    Write-Host ""
    Write-Host "4. VERIFY: Check if permissions were applied:" -ForegroundColor White
    Write-Host "   Get-VM -Location 'TestAppFolder' | Get-VIPermission | Where-Object {`$_.Principal -like '*Exchange*'}" -ForegroundColor Gray
    Write-Host "   Get-VM -Location 'TestAppResourcePool' | Get-VIPermission | Where-Object {`$_.Principal -like '*ACAS*'}" -ForegroundColor Gray
    Write-Host ""
    Write-Host "5. LOG REVIEW: Check the execution logs for:" -ForegroundColor White
    Write-Host "   • 'Processing Folder and Resource Pool Based Permission Propagation'" -ForegroundColor Gray
    Write-Host "   • 'Folder 'TestAppFolder': Found X app tags'" -ForegroundColor Gray
    Write-Host "   • 'Resource Pool 'TestAppResourcePool': Found X app tags'" -ForegroundColor Gray
    Write-Host "   • 'Applied permission to VM 'VMName' for tag 'Exchange-admins''" -ForegroundColor Gray
    Write-Host ""

    # Expected behavior
    Write-Host "`n=== Expected Behavior ===" -ForegroundColor Yellow
    Write-Host "✓ Script should find folders with application tags" -ForegroundColor Green
    Write-Host "✓ Script should find resource pools with application tags" -ForegroundColor Green
    Write-Host "✓ Script should identify VMs within folders and resource pools" -ForegroundColor Green
    Write-Host "✓ Script should apply permissions to VMs based on container tags" -ForegroundColor Green
    Write-Host "✓ Script should report folder and resource pool processing statistics" -ForegroundColor Green
    Write-Host "✓ Script should handle VMs that already have permissions" -ForegroundColor Green
    Write-Host ""

    # Troubleshooting
    Write-Host "`n=== Troubleshooting ===" -ForegroundColor Yellow
    Write-Host "If container-based permissions are not working:" -ForegroundColor White
    Write-Host ""
    Write-Host "1. VERIFY CONTAINER TAGS:" -ForegroundColor White
    Write-Host "   Get-Folder 'TestAppFolder' | Get-TagAssignment" -ForegroundColor Gray
    Write-Host "   Get-ResourcePool 'TestAppResourcePool' | Get-TagAssignment" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. CHECK CSV MAPPING:" -ForegroundColor White
    Write-Host "   Import-Csv '$appPermissionsCsv' | Where-Object {`$_.TagName -eq 'Exchange-admins'}" -ForegroundColor Gray
    Write-Host ""
    Write-Host "3. VALIDATE SSO GROUP:" -ForegroundColor White
    Write-Host "   Ensure the security group exists in the SSO domain" -ForegroundColor Gray
    Write-Host ""
    Write-Host "4. CHECK PERMISSIONS:" -ForegroundColor White
    Write-Host "   Ensure the executing user has permission to assign permissions" -ForegroundColor Gray
    Write-Host ""

    # Command examples
    Write-Host "`n=== Quick Test Commands ===" -ForegroundColor Yellow
    Write-Host "# Create test folder with tag:" -ForegroundColor White
    Write-Host "`$folder = New-Folder -Name 'TestAppFolder' -Location (Get-Datacenter)" -ForegroundColor Gray
    Write-Host "`$folderTag = Get-Tag -Name 'Exchange-admins' -Category '$($envConfig.TagCategories.App)'" -ForegroundColor Gray
    Write-Host "New-TagAssignment -Entity `$folder -Tag `$folderTag" -ForegroundColor Gray
    Write-Host ""
    Write-Host "# Create test resource pool with tag:" -ForegroundColor White
    Write-Host "`$cluster = Get-Cluster | Select-Object -First 1" -ForegroundColor Gray
    Write-Host "`$resourcePool = New-ResourcePool -Name 'TestAppResourcePool' -Location `$cluster" -ForegroundColor Gray
    Write-Host "`$rpTag = Get-Tag -Name 'ACAS-Admins' -Category '$($envConfig.TagCategories.App)'" -ForegroundColor Gray
    Write-Host "New-TagAssignment -Entity `$resourcePool -Tag `$rpTag" -ForegroundColor Gray
    Write-Host ""
    Write-Host "# Check VMs in containers:" -ForegroundColor White
    Write-Host "Get-VM -Location 'TestAppFolder'" -ForegroundColor Gray
    Write-Host "Get-VM -Location 'TestAppResourcePool'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "# Check container tags:" -ForegroundColor White
    Write-Host "Get-Folder 'TestAppFolder' | Get-TagAssignment" -ForegroundColor Gray
    Write-Host "Get-ResourcePool 'TestAppResourcePool' | Get-TagAssignment" -ForegroundColor Gray
    Write-Host ""

    Write-Host "`n=== Success Criteria ===" -ForegroundColor Yellow
    Write-Host "The test is successful when:" -ForegroundColor White
    Write-Host "• Folder processing statistics show > 0 folders processed" -ForegroundColor Green
    Write-Host "• Folder processing statistics show > 0 folder tags found" -ForegroundColor Green
    Write-Host "• Resource pool processing statistics show > 0 resource pools processed" -ForegroundColor Green
    Write-Host "• Resource pool processing statistics show > 0 resource pool tags found" -ForegroundColor Green
    Write-Host "• VM permissions are successfully applied from container tags" -ForegroundColor Green
    Write-Host "• Log files contain detailed container processing information" -ForegroundColor Green
    Write-Host "• No errors in container processing section of logs" -ForegroundColor Green

}
catch {
    Write-Host "Error during validation setup: $_" -ForegroundColor Red
}

Write-Host "`nRun the main script with -ForceDebug to see detailed folder processing logs." -ForegroundColor White