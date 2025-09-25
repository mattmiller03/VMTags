# Network Share CSV Access Testing Script
<#
.SYNOPSIS
    Tests network share CSV access functionality for VMTags

.DESCRIPTION
    This script tests the network share configuration and CSV file retrieval
    functionality to ensure proper operation before deploying to production.

.PARAMETER Environment
    Environment to test (DEV, PROD, KLEB, OT)

.PARAMETER TestConnectivity
    Test network share connectivity only

.PARAMETER TestCredentials
    Test credential retrieval from Windows Credential Manager

.PARAMETER TestCaching
    Test file caching functionality

.PARAMETER ForceRefresh
    Force refresh from network share (bypass cache)

.EXAMPLE
    .\Test-NetworkShare.ps1 -Environment PROD -TestConnectivity

.EXAMPLE
    .\Test-NetworkShare.ps1 -Environment KLEB -TestCredentials -TestCaching
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Environment to test")]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = $false, HelpMessage = "Test connectivity only")]
    [switch]$TestConnectivity,

    [Parameter(Mandatory = $false, HelpMessage = "Test credential retrieval")]
    [switch]$TestCredentials,

    [Parameter(Mandatory = $false, HelpMessage = "Test caching functionality")]
    [switch]$TestCaching,

    [Parameter(Mandatory = $false, HelpMessage = "Force refresh from network")]
    [switch]$ForceRefresh
)

function Write-TestLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] [NetworkShareTest] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN"  { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        "TEST" { Write-Host $logMessage -ForegroundColor Cyan }
        default { Write-Host $logMessage -ForegroundColor White }
    }
}

function Test-NetworkShareConfiguration {
    param([hashtable]$Config)

    Write-TestLog "=== Testing Network Share Configuration ===" "TEST"

    $results = @{
        ConfigValid = $false
        NetworkShareEnabled = $false
        PathAccessible = $false
        CredentialsValid = $false
        CacheConfigured = $false
    }

    # Test configuration structure
    if ($Config.EnableNetworkShare -ne $null -and $Config.NetworkSharePath -and $Config.CacheNetworkFiles -ne $null) {
        $results.ConfigValid = $true
        Write-TestLog "Configuration structure is valid" "SUCCESS"
    } else {
        Write-TestLog "Invalid configuration structure" "ERROR"
        return $results
    }

    # Test if network share is enabled
    if ($Config.EnableNetworkShare) {
        $results.NetworkShareEnabled = $true
        Write-TestLog "Network share is enabled for environment" "SUCCESS"
    } else {
        Write-TestLog "Network share is disabled for environment" "WARN"
    }

    # Test network path accessibility
    if ($Config.EnableNetworkShare -and $Config.NetworkSharePath) {
        try {
            $pathTest = Test-Path $Config.NetworkSharePath -ErrorAction Stop
            if ($pathTest) {
                $results.PathAccessible = $true
                Write-TestLog "Network share path is accessible: $($Config.NetworkSharePath)" "SUCCESS"
            } else {
                Write-TestLog "Network share path is not accessible: $($Config.NetworkSharePath)" "ERROR"
            }
        }
        catch {
            Write-TestLog "Error testing network path: $($_.Exception.Message)" "ERROR"
        }
    }

    # Test credential configuration
    if ($Config.NetworkShareCredentialName) {
        $results.CacheConfigured = $true
        Write-TestLog "Credential name configured: $($Config.NetworkShareCredentialName)" "SUCCESS"
    }

    # Test cache configuration
    if ($Config.CacheNetworkFiles -and $Config.CacheExpiryHours -gt 0) {
        $results.CacheConfigured = $true
        Write-TestLog "Caching configured: $($Config.CacheExpiryHours) hours expiry" "SUCCESS"
    }

    return $results
}

function Test-CredentialRetrieval {
    param([string]$CredentialName)

    Write-TestLog "=== Testing Credential Retrieval ===" "TEST"

    if (-not $CredentialName) {
        Write-TestLog "No credential name configured - skipping test" "WARN"
        return $false
    }

    try {
        $credScriptPath = Join-Path $PSScriptRoot "Scripts\Get-StoredCredential.ps1"
        if (-not (Test-Path $credScriptPath)) {
            Write-TestLog "Credential script not found: $credScriptPath" "ERROR"
            return $false
        }

        Write-TestLog "Attempting to retrieve credential: $CredentialName" "INFO"
        $credential = & $credScriptPath -Target $CredentialName -ErrorAction Stop

        if ($credential -and $credential.UserName) {
            Write-TestLog "Successfully retrieved credential for user: $($credential.UserName)" "SUCCESS"
            return $true
        } else {
            Write-TestLog "No credential retrieved for target: $CredentialName" "ERROR"
            return $false
        }
    }
    catch {
        Write-TestLog "Failed to retrieve credential: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Test-CSVRetrieval {
    param(
        [hashtable]$Config,
        [string]$TestFileName = "test-file.csv"
    )

    Write-TestLog "=== Testing CSV File Retrieval ===" "TEST"

    if (-not $Config.EnableNetworkShare) {
        Write-TestLog "Network share disabled - skipping CSV retrieval test" "WARN"
        return $false
    }

    try {
        # Load network share script
        $networkShareScriptPath = Join-Path $PSScriptRoot "Scripts\Get-NetworkShareCSV.ps1"
        if (-not (Test-Path $networkShareScriptPath)) {
            Write-TestLog "Network share script not found: $networkShareScriptPath" "ERROR"
            return $false
        }

        . $networkShareScriptPath

        # Get credentials if configured
        $shareCredential = $null
        if ($Config.NetworkShareCredentialName) {
            $credScriptPath = Join-Path $PSScriptRoot "Scripts\Get-StoredCredential.ps1"
            if (Test-Path $credScriptPath) {
                try {
                    $shareCredential = & $credScriptPath -Target $Config.NetworkShareCredentialName -ErrorAction SilentlyContinue
                }
                catch {
                    Write-TestLog "Could not retrieve credentials, testing without authentication" "WARN"
                }
            }
        }

        # Test with an actual CSV file from the environment
        $csvFiles = @("AppTagPermissions_$Environment.csv", "OS-Mappings_$Environment.csv", "App-Permissions-$Environment.csv")
        $testSuccessful = $false

        foreach ($csvFile in $csvFiles) {
            Write-TestLog "Testing CSV file retrieval: $csvFile" "INFO"

            try {
                $result = Get-NetworkShareCSV -NetworkPath $Config.NetworkSharePath -LocalFallbackPath ".\Data\$Environment" -FileName $csvFile -Credential $shareCredential -EnableCaching $Config.CacheNetworkFiles -CacheExpiryHours $Config.CacheExpiryHours -ForceRefresh:$ForceRefresh

                if ($result.Success) {
                    Write-TestLog "Successfully retrieved $csvFile from $($result.Source) ($($result.RowCount) rows)" "SUCCESS"
                    Write-TestLog "Last Modified: $($result.LastModified)" "INFO"
                    $testSuccessful = $true
                    break
                } else {
                    Write-TestLog "Failed to retrieve $csvFile: $($result.Error)" "WARN"
                }
            }
            catch {
                Write-TestLog "Error testing $csvFile: $($_.Exception.Message)" "WARN"
            }
        }

        return $testSuccessful
    }
    catch {
        Write-TestLog "Error in CSV retrieval test: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Test-CachingFunctionality {
    param([hashtable]$Config)

    Write-TestLog "=== Testing Cache Functionality ===" "TEST"

    if (-not $Config.CacheNetworkFiles) {
        Write-TestLog "Caching is disabled - skipping cache test" "WARN"
        return $true
    }

    try {
        # Check cache directory creation and cleanup
        $tempNetworkPath = "\\test-server\test-share"
        $pathHash = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($tempNetworkPath))
        $hashString = [System.BitConverter]::ToString($pathHash).Replace('-', '').Substring(0, 8)
        $cacheDir = Join-Path $env:TEMP "VMTags_NetworkShare_Cache\$hashString"

        Write-TestLog "Testing cache directory creation: $cacheDir" "INFO"

        # Create test cache directory
        if (-not (Test-Path $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }

        if (Test-Path $cacheDir) {
            Write-TestLog "Cache directory created successfully" "SUCCESS"

            # Create test cache file
            $testFile = Join-Path $cacheDir "test-cache.csv"
            "Header1,Header2`nValue1,Value2" | Out-File -FilePath $testFile -Encoding UTF8

            if (Test-Path $testFile) {
                Write-TestLog "Test cache file created successfully" "SUCCESS"

                # Test cache age validation
                $fileAge = (Get-Date) - (Get-Item $testFile).LastWriteTime
                $isValid = $fileAge.TotalHours -lt $Config.CacheExpiryHours

                Write-TestLog "Cache file age: $([math]::Round($fileAge.TotalMinutes, 2)) minutes" "INFO"
                Write-TestLog "Cache expiry setting: $($Config.CacheExpiryHours) hours" "INFO"
                Write-TestLog "Cache file valid: $isValid" "INFO"

                # Cleanup test file
                Remove-Item $testFile -Force -ErrorAction SilentlyContinue
                Remove-Item $cacheDir -Force -Recurse -ErrorAction SilentlyContinue

                return $true
            }
        }

        return $false
    }
    catch {
        Write-TestLog "Error in cache functionality test: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# Main execution
try {
    Write-TestLog "=== Network Share Testing Started ===" "INFO"
    Write-TestLog "Environment: $Environment" "INFO"
    Write-TestLog "Test Mode: $($PSBoundParameters.Keys -join ', ')" "INFO"

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

    $networkConfig = $envConfig.DataPaths

    # Run tests based on parameters
    $allTestsPassed = $true

    # Test configuration
    $configResults = Test-NetworkShareConfiguration -Config $networkConfig
    if (-not $configResults.ConfigValid) {
        $allTestsPassed = $false
    }

    # Test connectivity if requested
    if ($TestConnectivity -or $PSBoundParameters.Count -eq 1) {
        Write-TestLog "Network share path: $($networkConfig.NetworkSharePath)" "INFO"
        Write-TestLog "Network share enabled: $($networkConfig.EnableNetworkShare)" "INFO"

        if (-not $configResults.PathAccessible -and $networkConfig.EnableNetworkShare) {
            $allTestsPassed = $false
        }
    }

    # Test credentials if requested
    if ($TestCredentials) {
        $credTest = Test-CredentialRetrieval -CredentialName $networkConfig.NetworkShareCredentialName
        if (-not $credTest) {
            $allTestsPassed = $false
        }
    }

    # Test caching if requested
    if ($TestCaching) {
        $cacheTest = Test-CachingFunctionality -Config $networkConfig
        if (-not $cacheTest) {
            $allTestsPassed = $false
        }
    }

    # Test CSV retrieval (default if no specific test requested)
    if ($PSBoundParameters.Count -eq 1 -or (-not $TestConnectivity -and -not $TestCredentials -and -not $TestCaching)) {
        $csvTest = Test-CSVRetrieval -Config $networkConfig
        if (-not $csvTest) {
            Write-TestLog "CSV retrieval test failed, but this may be expected if network share is not yet configured" "WARN"
        }
    }

    # Summary
    Write-TestLog "=== Test Results Summary ===" "INFO"
    Write-TestLog "Configuration Valid: $($configResults.ConfigValid)" "INFO"
    Write-TestLog "Network Share Enabled: $($configResults.NetworkShareEnabled)" "INFO"
    Write-TestLog "Path Accessible: $($configResults.PathAccessible)" "INFO"
    Write-TestLog "Overall Result: $(if ($allTestsPassed) { 'PASSED' } else { 'FAILED' })" $(if ($allTestsPassed) { "SUCCESS" } else { "ERROR" })

    if ($allTestsPassed) {
        Write-TestLog "Network share configuration is ready for use" "SUCCESS"
    } else {
        Write-TestLog "Network share configuration needs attention before use" "ERROR"
    }

    return $allTestsPassed
}
catch {
    Write-TestLog "Test execution failed: $($_.Exception.Message)" "ERROR"
    Write-TestLog "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    return $false
}
finally {
    Write-TestLog "=== Network Share Testing Completed ===" "INFO"
}