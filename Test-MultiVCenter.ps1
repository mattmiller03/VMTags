<#
.SYNOPSIS
    Test script for Enhanced Linked Mode multi-vCenter support
.DESCRIPTION
    This script tests the multi-vCenter configuration and connection functionality
    for Enhanced Linked Mode environments where multiple vCenters share the same SSO domain.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [switch]$TestConnectionsOnly
)

# Import configuration loading logic from launcher
. "$PSScriptRoot\VM_TagPermissions_Launcher.ps1" -Environment $Environment -DryRun -SkipNetworkTests 2>$null

Write-Host "`n=== Multi-vCenter Enhanced Linked Mode Test ===" -ForegroundColor Cyan
Write-Host "Environment: $Environment" -ForegroundColor White

# Test configuration loading
try {
    # Load configuration similar to launcher
    $configPath = Join-Path $PSScriptRoot "ConfigFiles\VMTagsConfig.psd1"

    if (-not (Test-Path $configPath)) {
        throw "Configuration file not found: $configPath"
    }

    $configData = Import-PowerShellDataFile -Path $configPath
    $envConfig = $configData.Environments[$Environment]

    if (-not $envConfig) {
        throw "Environment '$Environment' not found in configuration"
    }

    Write-Host "`n=== Configuration Analysis ===" -ForegroundColor Yellow

    # Check for multi-vCenter configuration
    if ($envConfig.vCenterServers -and $envConfig.vCenterServers.Count -gt 0) {
        Write-Host "Multi-vCenter Mode: ENABLED" -ForegroundColor Green
        Write-Host "Number of vCenter servers: $($envConfig.vCenterServers.Count)" -ForegroundColor White

        Write-Host "`nvCenter Servers:" -ForegroundColor White
        foreach ($vcenter in ($envConfig.vCenterServers | Sort-Object Priority)) {
            $priorityColor = if ($vcenter.Priority -eq 1) { "Green" } else { "Yellow" }
            Write-Host "  [$($vcenter.Priority)] $($vcenter.Server) - $($vcenter.Description)" -ForegroundColor $priorityColor
        }

        Write-Host "`nSSO Domain: $($envConfig.SSODomain)" -ForegroundColor White
        Write-Host "Fallback Server: $($envConfig.vCenterServer)" -ForegroundColor Gray
    } else {
        Write-Host "Multi-vCenter Mode: DISABLED (Single vCenter)" -ForegroundColor Yellow
        Write-Host "vCenter Server: $($envConfig.vCenterServer)" -ForegroundColor White
        Write-Host "SSO Domain: $($envConfig.SSODomain)" -ForegroundColor White
    }

    # Test multi-vCenter settings
    if ($configData.MultiVCenter) {
        Write-Host "`n=== Multi-vCenter Settings ===" -ForegroundColor Yellow
        Write-Host "Connection Strategy: $($configData.MultiVCenter.ConnectionStrategy)" -ForegroundColor White
        Write-Host "Enable Auto Failover: $($configData.MultiVCenter.EnableAutomaticFailover)" -ForegroundColor White
        Write-Host "Aggregate Inventory: $($configData.MultiVCenter.AggregateInventoryAcrossVCenters)" -ForegroundColor White
        Write-Host "Parallel Processing: $($configData.MultiVCenter.EnableParallelVCenterProcessing)" -ForegroundColor White
        Write-Host "Max Retries: $($configData.MultiVCenter.MaxConnectionRetries)" -ForegroundColor White
    }

    # Feature flag check
    $multiVCenterEnabled = $configData.FeatureFlags.EnableMultiVCenterSupport
    $flagStatus = if ($multiVCenterEnabled) { 'ENABLED' } else { 'DISABLED' }
    $flagColor = if ($multiVCenterEnabled) { 'Green' } else { 'Red' }
    Write-Host "`nMulti-vCenter Feature Flag: $flagStatus" -ForegroundColor $flagColor

    if ($TestConnectionsOnly -and $envConfig.vCenterServers) {
        Write-Host "`n=== Network Connectivity Tests ===" -ForegroundColor Yellow

        foreach ($vcenter in ($envConfig.vCenterServers | Sort-Object Priority)) {
            $server = $vcenter.Server
            Write-Host "Testing connectivity to: $server" -ForegroundColor White -NoNewline

            try {
                $connection = Test-NetConnection -ComputerName $server -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop
                if ($connection) {
                    Write-Host " [SUCCESS]" -ForegroundColor Green
                } else {
                    Write-Host " [FAILED]" -ForegroundColor Red
                }
            }
            catch {
                Write-Host " [ERROR: $($_.Exception.Message)]" -ForegroundColor Red
            }
        }
    }

    Write-Host "`n=== Configuration Examples ===" -ForegroundColor Yellow
    Write-Host "To enable multi-vCenter mode for an environment, update the configuration:" -ForegroundColor White
    Write-Host @"

# Example configuration for Enhanced Linked Mode:
ENVIRONMENT = @{
    vCenterServers = @(
        @{ Server = "vcenter1.domain.com"; Description = "Primary Site A"; Priority = 1 }
        @{ Server = "vcenter2.domain.com"; Description = "Secondary Site B"; Priority = 2 }
    )
    vCenterServer = "vcenter1.domain.com"  # Fallback for compatibility
    SSODomain = "shared-sso.domain.com"
    # ... other settings
}
"@ -ForegroundColor Gray

    Write-Host "`n=== Enhanced Linked Mode Behavior ===" -ForegroundColor Yellow
    if ($envConfig.vCenterServers -and $envConfig.vCenterServers.Count -gt 0) {
        Write-Host "For Enhanced Linked Mode environments:" -ForegroundColor White
        Write-Host "• Script executes against PRIMARY vCenter only" -ForegroundColor Green
        Write-Host "• All vCenters share the same VM inventory via SSO" -ForegroundColor Green
        Write-Host "• Changes are visible across all linked vCenters" -ForegroundColor Green
        Write-Host "• This prevents duplicate processing of the same VMs" -ForegroundColor Green

        $parallelEnabled = $configData.MultiVCenter.EnableParallelVCenterProcessing
        if ($parallelEnabled) {
            Write-Host "`nWARNING: Parallel processing is ENABLED" -ForegroundColor Red
            Write-Host "This will execute against ALL vCenters and may process VMs multiple times!" -ForegroundColor Red
        } else {
            Write-Host "`nParallel processing is DISABLED (recommended for Enhanced Linked Mode)" -ForegroundColor Green
        }
    }

    Write-Host "`n=== Usage Examples ===" -ForegroundColor Yellow
    Write-Host "# Normal execution (uses primary vCenter in Enhanced Linked Mode):" -ForegroundColor White
    Write-Host ".\VM_TagPermissions_Launcher.ps1 -Environment $Environment -UseStoredCredentials" -ForegroundColor Gray
    Write-Host "`n# Test connectivity only:" -ForegroundColor White
    Write-Host ".\Test-MultiVCenter.ps1 -Environment $Environment -TestConnectionsOnly" -ForegroundColor Gray

    if ($envConfig.vCenterServers -and $envConfig.vCenterServers.Count -gt 0) {
        Write-Host "`n# To enable parallel execution (NOT recommended for Enhanced Linked Mode):" -ForegroundColor White
        Write-Host "# Set EnableParallelVCenterProcessing = `$true in VMTagsConfig.psd1" -ForegroundColor Gray
    }

    Write-Host "`n=== Test Complete ===" -ForegroundColor Green

} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}

Write-Host "`nFor detailed testing with credentials, use the main launcher script with -DryRun parameter." -ForegroundColor Yellow