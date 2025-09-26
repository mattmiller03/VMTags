# Test OS Tag and Permission Processing
<#
.SYNOPSIS
    Test script to diagnose OS tag recreation and permission application issues

.DESCRIPTION
    This script helps diagnose why OS tags are being recreated but permissions
    are not being applied to VMs. It provides detailed debugging output.

.PARAMETER VMName
    Specific VM name to test (optional)

.PARAMETER Environment
    Environment to test (DEV, PROD, KLEB, OT)

.PARAMETER OSPattern
    Test specific OS pattern matching (optional)

.EXAMPLE
    .\Test-OSTagPermissions.ps1 -Environment PROD -VMName "WebServer01"

.EXAMPLE
    .\Test-OSTagPermissions.ps1 -Environment DEV -OSPattern "Windows Server"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = false, HelpMessage = "VM name to test")]
    [string]$VMName,

    [Parameter(Mandatory = true, HelpMessage = "Environment to test")]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = false, HelpMessage = "OS pattern to test")]
    [string]$OSPattern
)

function Write-TestLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG" { "Cyan" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

try {
    Write-TestLog "=== OS Tag and Permission Test ===" "INFO"
    Write-TestLog "Environment: $Environment" "INFO"
    if ($VMName) { Write-TestLog "Target VM: $VMName" "INFO" }
    if ($OSPattern) { Write-TestLog "OS Pattern: $OSPattern" "INFO" }

    # Load configuration
    $configPath = Join-Path $PSScriptRoot "ConfigFiles\VMTagsConfig.psd1"
    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $config = Import-PowerShellDataFile -Path $configPath
    $envConfig = $config.Environments.$Environment

    if (-not $envConfig) {
        throw "Environment '$Environment' not found in configuration"
    }

    # Get category names
    $osCategoryName = $envConfig.TagCategories.OS
    $appCategoryName = $envConfig.TagCategories.App
    $functionCategoryName = $envConfig.TagCategories.Function

    Write-TestLog "OS Category: $osCategoryName" "INFO"
    Write-TestLog "App Category: $appCategoryName" "INFO"
    Write-TestLog "Function Category: $functionCategoryName" "INFO"

    # Test PowerCLI connection
    if (-not (Get-PowerCLIVersion -ErrorAction SilentlyContinue)) {
        throw "PowerCLI not found. Please install VMware PowerCLI."
    }

    # Check if connected to vCenter
    $viConnection = $global:DefaultVIServers
    if (-not $viConnection -or $viConnection.Count -eq 0) {
        Write-TestLog "Not connected to vCenter. Please connect first with Connect-VIServer" "ERROR"
        return
    }

    Write-TestLog "Connected to vCenter: $($viConnection.Name)" "SUCCESS"

    # Check tag categories
    Write-TestLog "=== Checking Tag Categories ===" "INFO"

    $osCategory = Get-TagCategory -Name $osCategoryName -ErrorAction SilentlyContinue
    if ($osCategory) {
        Write-TestLog "OS Category '$osCategoryName' found" "SUCCESS"
        Write-TestLog "  Entity Types: $($osCategory.EntityType -join ', ')" "INFO"
    } else {
        Write-TestLog "OS Category '$osCategoryName' NOT found" "ERROR"
    }

    $appCategory = Get-TagCategory -Name $appCategoryName -ErrorAction SilentlyContinue
    if ($appCategory) {
        Write-TestLog "App Category '$appCategoryName' found" "SUCCESS"
    } else {
        Write-TestLog "App Category '$appCategoryName' NOT found" "WARN"
    }

    # Load OS mapping CSV
    $osMappingPath = $envConfig.DataPaths.OSMappingCSV
    Write-TestLog "Loading OS mapping from: $osMappingPath" "INFO"

    if (-not (Test-Path $osMappingPath)) {
        throw "OS Mapping CSV not found: $osMappingPath"
    }

    $osMappingData = Import-Csv -Path $osMappingPath
    Write-TestLog "Loaded $($osMappingData.Count) OS mapping entries" "SUCCESS"

    # Display OS mappings
    Write-TestLog "=== OS Mappings ===" "INFO"
    foreach ($mapping in $osMappingData) {
        Write-TestLog "  Pattern: '$($mapping.GuestOSPattern)' -> Tag: '$($mapping.TargetTagName)' (Role: $($mapping.RoleName), Group: $($mapping.SecurityGroupName))" "INFO"
    }

    # Test specific VM if provided
    if ($VMName) {
        Write-TestLog "=== Testing VM: $VMName ===" "INFO"

        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-TestLog "VM '$VMName' not found" "ERROR"
            return
        }

        Write-TestLog "VM found: $($vm.Name)" "SUCCESS"

        # Get OS information
        $osInfo = @()
        if ($vm.Guest.OSFullName) {
            $osInfo += @{ Source = "Guest OS"; Name = $vm.Guest.OSFullName }
        }
        if ($vm.ExtensionData.Config.GuestFullName) {
            $osInfo += @{ Source = "Config"; Name = $vm.ExtensionData.Config.GuestFullName }
        }

        Write-TestLog "OS Information:" "INFO"
        foreach ($os in $osInfo) {
            Write-TestLog "  $($os.Source): '$($os.Name)'" "INFO"
        }

        # Test pattern matching
        Write-TestLog "=== Pattern Matching ===" "INFO"
        $matched = $false
        foreach ($os in $osInfo) {
            foreach ($mapping in $osMappingData) {
                if ($os.Name -match $mapping.GuestOSPattern) {
                    Write-TestLog "MATCH: '$($os.Name)' matches pattern '$($mapping.GuestOSPattern)'" "SUCCESS"
                    Write-TestLog "  Target Tag: '$($mapping.TargetTagName)'" "INFO"
                    Write-TestLog "  Role: '$($mapping.RoleName)'" "INFO"
                    Write-TestLog "  Security Group: '$($mapping.SecurityGroupName)'" "INFO"
                    $matched = $true

                    # Check if tag exists
                    $targetTag = Get-Tag -Category $osCategory -Name $mapping.TargetTagName -ErrorAction SilentlyContinue
                    if ($targetTag) {
                        Write-TestLog "  Tag '$($mapping.TargetTagName)' exists in category" "SUCCESS"
                    } else {
                        Write-TestLog "  Tag '$($mapping.TargetTagName)' NOT found in category" "ERROR"
                    }

                    # Check if VM has the tag
                    $vmTags = Get-TagAssignment -Entity $vm -Category $osCategory -ErrorAction SilentlyContinue
                    $hasOSTag = $vmTags | Where-Object { $_.Tag.Name -eq $mapping.TargetTagName }
                    if ($hasOSTag) {
                        Write-TestLog "  VM has OS tag '$($mapping.TargetTagName)'" "SUCCESS"
                    } else {
                        Write-TestLog "  VM does NOT have OS tag '$($mapping.TargetTagName)'" "WARN"
                    }

                    # Check permissions
                    $envDomainMap = @{
                        'DEV'  = 'DLA-Test-Dev.local'
                        'PROD' = 'DLA-Prod.local'
                        'KLEB' = 'DLA-Kleber.local'
                        'OT'   = 'DLA-DaytonOT.local'
                    }
                    $ssoDomain = $envDomainMap[$Environment]
                    $expectedPrincipal = "$ssoDomain\$($mapping.SecurityGroupName)"

                    Write-TestLog "  Expected Permission: Principal='$expectedPrincipal', Role='$($mapping.RoleName)'" "INFO"

                    $vmPermissions = Get-VIPermission -Entity $vm -ErrorAction SilentlyContinue
                    $hasPermission = $vmPermissions | Where-Object {
                        $_.Principal -eq $expectedPrincipal -and $_.Role -eq $mapping.RoleName
                    }

                    if ($hasPermission) {
                        Write-TestLog "  VM has expected permission" "SUCCESS"
                    } else {
                        Write-TestLog "  VM does NOT have expected permission" "ERROR"
                        Write-TestLog "  Current permissions:" "INFO"
                        foreach ($perm in $vmPermissions) {
                            Write-TestLog "    Principal: '$($perm.Principal)', Role: '$($perm.Role)'" "INFO"
                        }
                    }
                }
            }
        }

        if (-not $matched) {
            Write-TestLog "No OS patterns matched for this VM" "WARN"
        }
    }

    Write-TestLog "=== Test Complete ===" "SUCCESS"

}
catch {
    Write-TestLog "Test failed: $($_.Exception.Message)" "ERROR"
    Write-TestLog "Stack trace: $($_.ScriptStackTrace)" "ERROR"
}