<#
.SYNOPSIS
    Test script to verify launcher argument construction
.DESCRIPTION
    This script tests the argument building logic to ensure -Verbose doesn't cause issues
#>

# Test the argument building logic similar to the launcher
$testConfig = @{
    PowerShell7 = @{
        StandardArguments = @("-NoProfile", "-NonInteractive")
        DebugArguments = @()  # Empty array now
    }
    DefaultPaths = @{
        PowerShell7Path = "pwsh.exe"
        MainScriptPath = ".\Scripts\set-VMtagPermissions.ps1"
    }
}

# Test normal execution
Write-Host "=== Testing Normal Execution ===" -ForegroundColor Cyan
$powershellArgs = @()
$scriptArgs = @()

# Add standard arguments
foreach ($arg in $testConfig.PowerShell7.StandardArguments) {
    if (-not [string]::IsNullOrEmpty($arg)) {
        $powershellArgs += $arg
    }
}

# Add -File and script path
$powershellArgs += '-File'
$powershellArgs += "`"$($testConfig.DefaultPaths.MainScriptPath)`""

# Add test script args
$scriptArgs += '-vCenterServer'
$scriptArgs += 'test-vcenter.local'
$scriptArgs += '-Environment'
$scriptArgs += 'DEV'

# Combine arguments
$allArgs = $powershellArgs + $scriptArgs
$commandLine = "$($testConfig.DefaultPaths.PowerShell7Path) $($allArgs -join ' ')"

Write-Host "Normal command line:" -ForegroundColor Green
Write-Host $commandLine -ForegroundColor White

# Test debug execution
Write-Host "`n=== Testing Debug Execution ===" -ForegroundColor Cyan
$powershellArgsDebug = @()
$scriptArgsDebug = @()

# Add standard arguments
foreach ($arg in $testConfig.PowerShell7.StandardArguments) {
    if (-not [string]::IsNullOrEmpty($arg)) {
        $powershellArgsDebug += $arg
    }
}

# Add debug arguments (now empty)
foreach ($arg in $testConfig.PowerShell7.DebugArguments) {
    if (-not [string]::IsNullOrEmpty($arg)) {
        $powershellArgsDebug += $arg
    }
}

# Add -File and script path
$powershellArgsDebug += '-File'
$powershellArgsDebug += "`"$($testConfig.DefaultPaths.MainScriptPath)`""

# Add test script args with debug enabled
$scriptArgsDebug += '-vCenterServer'
$scriptArgsDebug += 'test-vcenter.local'
$scriptArgsDebug += '-Environment'
$scriptArgsDebug += 'DEV'
$scriptArgsDebug += '-EnableScriptDebug'

# Combine arguments
$allArgsDebug = $powershellArgsDebug + $scriptArgsDebug
$commandLineDebug = "$($testConfig.DefaultPaths.PowerShell7Path) $($allArgsDebug -join ' ')"

Write-Host "Debug command line:" -ForegroundColor Green
Write-Host $commandLineDebug -ForegroundColor White

Write-Host "`n=== Argument Analysis ===" -ForegroundColor Cyan
Write-Host "PowerShell Args: $($powershellArgsDebug -join ', ')" -ForegroundColor Yellow
Write-Host "Script Args: $($scriptArgsDebug -join ', ')" -ForegroundColor Yellow

Write-Host "`n=== Test Complete ===" -ForegroundColor Green
Write-Host "The -Verbose argument issue should be resolved by removing it from DebugArguments in config." -ForegroundColor White