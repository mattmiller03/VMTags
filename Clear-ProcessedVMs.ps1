# Clear Processed VMs Tracking File
<#
.SYNOPSIS
    Clears the daily VM processing tracking file to allow reprocessing

.DESCRIPTION
    The VMTags script tracks which VMs have been processed each day to prevent
    duplicate processing in multi-vCenter environments. This script clears that
    tracking to allow VMs to be reprocessed.

.PARAMETER Environment
    Environment to clear (DEV, PROD, KLEB, OT)

.PARAMETER All
    Clear all environments

.EXAMPLE
    .\Clear-ProcessedVMs.ps1 -Environment PROD

.EXAMPLE
    .\Clear-ProcessedVMs.ps1 -All
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Environment to clear")]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = $false, HelpMessage = "Clear all environments")]
    [switch]$All
)

function Write-ClearLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

try {
    Write-ClearLog "=== Clearing Processed VMs Tracking ===" "INFO"

    $environments = if ($All) { @('DEV', 'PROD', 'KLEB', 'OT') } else { @($Environment) }

    foreach ($env in $environments) {
        Write-ClearLog "Processing environment: $env" "INFO"

        # Find log directory
        $logDir = ".\Logs\$env"
        if (-not (Test-Path $logDir)) {
            Write-ClearLog "Log directory not found: $logDir" "WARN"
            continue
        }

        # Find processed VMs files
        $today = Get-Date -Format 'yyyyMMdd'
        $processedVMsFile = Join-Path $logDir "ProcessedVMs_$($env)_$today.json"
        $inheritanceFile = Join-Path $logDir "ProcessedInheritanceVMs_$($env)_$today.json"

        # Clear processed VMs file
        if (Test-Path $processedVMsFile) {
            Remove-Item $processedVMsFile -Force
            Write-ClearLog "Cleared: $processedVMsFile" "SUCCESS"
        } else {
            Write-ClearLog "No processed VMs file found: $processedVMsFile" "INFO"
        }

        # Clear inheritance file
        if (Test-Path $inheritanceFile) {
            Remove-Item $inheritanceFile -Force
            Write-ClearLog "Cleared: $inheritanceFile" "SUCCESS"
        } else {
            Write-ClearLog "No inheritance file found: $inheritanceFile" "INFO"
        }

        # Also clear any older files
        $olderFiles = Get-ChildItem $logDir -Filter "ProcessedVMs_$($env)_*.json" | Where-Object { $_.Name -notlike "*$today*" }
        $olderInheritanceFiles = Get-ChildItem $logDir -Filter "ProcessedInheritanceVMs_$($env)_*.json" | Where-Object { $_.Name -notlike "*$today*" }

        foreach ($file in $olderFiles + $olderInheritanceFiles) {
            $fileAge = (Get-Date) - $file.LastWriteTime
            if ($fileAge.Days -gt 1) {
                Remove-Item $file.FullName -Force
                Write-ClearLog "Cleaned up old file: $($file.Name)" "INFO"
            }
        }
    }

    Write-ClearLog "=== Clearing Complete ===" "SUCCESS"
    Write-ClearLog "You can now run the VMTags script to reprocess VMs" "INFO"

}
catch {
    Write-ClearLog "Error clearing processed VMs: $($_.Exception.Message)" "ERROR"
}