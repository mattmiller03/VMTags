<#
.SYNOPSIS
    Test script to verify automation mode bypass functionality
.DESCRIPTION
    This script tests that user prompts are properly bypassed when automation mode is enabled.
    It simulates the functions that would normally wait for user input.
#>

[CmdletBinding()]
param(
    [switch]$AutomationMode
)

# Set automation mode environment variables if requested
if ($AutomationMode) {
    $env:AUTOMATION_MODE = "SCRIPT_PARAMETER"
    $env:NO_PAUSE = "1"
    $env:POWERSHELL_INTERACTIVE = "0"
    Write-Host "Automation mode enabled via parameter" -ForegroundColor Green
}

# Test the Wait-ForUserInput function
function Wait-ForUserInput {
    param([string]$Message = "Press any key to exit...")

    # Check if running in Aria Operations or automation mode
    if ($env:AUTOMATION_MODE -eq "ARIA_OPERATIONS" -or $env:NO_PAUSE -eq "1" -or $env:CI -eq "true" -or
        $env:ARIA_EXECUTION -eq "1" -or $env:POWERSHELL_INTERACTIVE -eq "0" -or
        $env:JENKINS_URL -or $env:GITHUB_ACTIONS -or $env:TF_BUILD -or
        $env:AUTOMATION_MODE -eq "SCRIPT_PARAMETER") {
        Write-Host "`n[AUTOMATION MODE] Skipping user input: $Message" -ForegroundColor Gray
        return
    }

    Write-Host "`n$Message" -ForegroundColor Yellow
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    catch {
        # If ReadKey fails, use Read-Host as fallback
        Read-Host "Press Enter to continue"
    }
}

# Test the Get-UserInput function
function Get-UserInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [string]$DefaultValue = "",
        [string]$AutomationValue = $DefaultValue
    )

    # Check if running in Aria Operations or automation mode
    if ($env:AUTOMATION_MODE -eq "ARIA_OPERATIONS" -or $env:NO_PAUSE -eq "1" -or $env:CI -eq "true" -or
        $env:ARIA_EXECUTION -eq "1" -or $env:POWERSHELL_INTERACTIVE -eq "0" -or
        $env:JENKINS_URL -or $env:GITHUB_ACTIONS -or $env:TF_BUILD -or
        $env:AUTOMATION_MODE -eq "SCRIPT_PARAMETER") {
        Write-Host "`n[AUTOMATION MODE] Auto-responding to prompt '$Prompt' with: $AutomationValue" -ForegroundColor Gray
        return $AutomationValue
    }

    # Normal interactive mode
    if ($DefaultValue) {
        return Read-Host "$Prompt (default: $DefaultValue)"
    } else {
        return Read-Host $Prompt
    }
}

# Test execution
Write-Host "`n=== Testing Automation Mode Bypass ===" -ForegroundColor Cyan
Write-Host "Current environment variables:" -ForegroundColor White
Write-Host "  AUTOMATION_MODE: $($env:AUTOMATION_MODE)" -ForegroundColor White
Write-Host "  NO_PAUSE: $($env:NO_PAUSE)" -ForegroundColor White
Write-Host "  POWERSHELL_INTERACTIVE: $($env:POWERSHELL_INTERACTIVE)" -ForegroundColor White

Write-Host "`nTesting Wait-ForUserInput function..." -ForegroundColor Yellow
Wait-ForUserInput "This should be bypassed in automation mode"

Write-Host "`nTesting Get-UserInput function..." -ForegroundColor Yellow
$response1 = Get-UserInput -Prompt "Would you like to continue? (Y/N)" -AutomationValue "Y"
Write-Host "Response received: $response1" -ForegroundColor White

$response2 = Get-UserInput -Prompt "Enter environment name" -AutomationValue "PROD"
Write-Host "Response received: $response2" -ForegroundColor White

Write-Host "`n=== Test Complete ===" -ForegroundColor Green
if ($env:AUTOMATION_MODE -or $env:NO_PAUSE) {
    Write-Host "SUCCESS: Automation mode is active - user prompts were bypassed" -ForegroundColor Green
} else {
    Write-Host "INTERACTIVE: Normal interactive mode - user prompts would require input" -ForegroundColor Yellow
}

# Final wait test
Wait-ForUserInput "Final test - this should be bypassed in automation mode"