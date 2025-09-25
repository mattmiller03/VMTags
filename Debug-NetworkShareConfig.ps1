# Debug Network Share Configuration
param(
    [string]$Environment = "PROD"
)

function Write-DebugLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

Write-DebugLog "=== Network Share Configuration Debug ===" "INFO"
Write-DebugLog "Environment: $Environment" "INFO"
Write-DebugLog "Current Directory: $(Get-Location)" "INFO"

# Test configuration file path resolution
$scriptPath = $MyInvocation.MyCommand.Path
Write-DebugLog "Script Path: $scriptPath" "INFO"

$scriptDir = Split-Path $scriptPath -Parent
Write-DebugLog "Script Directory: $scriptDir" "INFO"

$configPath = Join-Path $scriptDir "ConfigFiles\VMTagsConfig.psd1"
Write-DebugLog "Config Path (relative): $configPath" "INFO"

# Check if config file exists
if (Test-Path $configPath) {
    Write-DebugLog "Configuration file found" "SUCCESS"
} else {
    Write-DebugLog "Configuration file NOT found" "ERROR"

    # Try alternative paths
    $altConfigPath1 = ".\ConfigFiles\VMTagsConfig.psd1"
    $altConfigPath2 = Join-Path (Get-Location) "ConfigFiles\VMTagsConfig.psd1"

    Write-DebugLog "Trying alternative path 1: $altConfigPath1" "INFO"
    if (Test-Path $altConfigPath1) {
        Write-DebugLog "Alternative path 1 FOUND" "SUCCESS"
        $configPath = $altConfigPath1
    } else {
        Write-DebugLog "Alternative path 1 NOT found" "WARN"
    }

    Write-DebugLog "Trying alternative path 2: $altConfigPath2" "INFO"
    if (Test-Path $altConfigPath2) {
        Write-DebugLog "Alternative path 2 FOUND" "SUCCESS"
        $configPath = $altConfigPath2
    } else {
        Write-DebugLog "Alternative path 2 NOT found" "WARN"
    }
}

# Try to load and analyze configuration
try {
    Write-DebugLog "Loading configuration from: $configPath" "INFO"
    $config = Import-PowerShellDataFile -Path $configPath

    if ($config.Environments.$Environment) {
        Write-DebugLog "Environment '$Environment' found in configuration" "SUCCESS"

        $envConfig = $config.Environments.$Environment
        $dataPathsConfig = $envConfig.DataPaths

        Write-DebugLog "DataPaths configuration:" "INFO"
        Write-DebugLog "  EnableNetworkShare: $($dataPathsConfig.EnableNetworkShare)" "INFO"
        Write-DebugLog "  NetworkSharePath: $($dataPathsConfig.NetworkSharePath)" "INFO"
        Write-DebugLog "  CacheNetworkFiles: $($dataPathsConfig.CacheNetworkFiles)" "INFO"
        Write-DebugLog "  CacheExpiryHours: $($dataPathsConfig.CacheExpiryHours)" "INFO"
        Write-DebugLog "  NetworkShareCredentialName: $($dataPathsConfig.NetworkShareCredentialName)" "INFO"

        # Test network share enable condition
        if ($dataPathsConfig.EnableNetworkShare) {
            Write-DebugLog "Network share is ENABLED" "SUCCESS"

            # Test network share path accessibility
            if ($dataPathsConfig.NetworkSharePath) {
                Write-DebugLog "Testing network share path: $($dataPathsConfig.NetworkSharePath)" "INFO"
                try {
                    $pathTest = Test-Path $dataPathsConfig.NetworkSharePath -ErrorAction Stop
                    if ($pathTest) {
                        Write-DebugLog "Network share path is accessible" "SUCCESS"
                    } else {
                        Write-DebugLog "Network share path is NOT accessible" "ERROR"
                    }
                }
                catch {
                    Write-DebugLog "Error testing network share path: $($_.Exception.Message)" "ERROR"
                }
            } else {
                Write-DebugLog "NetworkSharePath is not configured" "ERROR"
            }
        } else {
            Write-DebugLog "Network share is DISABLED" "WARN"
        }

        # Check for required scripts
        $networkShareScript = Join-Path $scriptDir "Scripts\Get-NetworkShareCSV.ps1"
        Write-DebugLog "Checking for network share script: $networkShareScript" "INFO"
        if (Test-Path $networkShareScript) {
            Write-DebugLog "Network share script found" "SUCCESS"
        } else {
            Write-DebugLog "Network share script NOT found" "ERROR"
        }

        $credentialScript = Join-Path $scriptDir "Scripts\Get-StoredCredential.ps1"
        Write-DebugLog "Checking for credential script: $credentialScript" "INFO"
        if (Test-Path $credentialScript) {
            Write-DebugLog "Credential script found" "SUCCESS"
        } else {
            Write-DebugLog "Credential script NOT found" "ERROR"
        }

    } else {
        Write-DebugLog "Environment '$Environment' NOT found in configuration" "ERROR"
        Write-DebugLog "Available environments: $($config.Environments.Keys -join ', ')" "INFO"
    }
}
catch {
    Write-DebugLog "Failed to load configuration: $($_.Exception.Message)" "ERROR"
    Write-DebugLog "Stack trace: $($_.ScriptStackTrace)" "ERROR"
}

Write-DebugLog "=== Debug Complete ===" "INFO"