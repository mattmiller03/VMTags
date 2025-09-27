# Configure Network Share File Mappings for VMTags
<#
.SYNOPSIS
    Helps configure network share file mappings for VMTags environments

.DESCRIPTION
    This script scans the network share for available CSV files and helps configure
    the NetworkShareMapping in VMTagsConfig.psd1 to handle differences between
    local file names and network share file names.

.PARAMETER Environment
    Environment to configure (DEV, PROD, KLEB, OT)

.PARAMETER NetworkSharePath
    Override the network share path from configuration

.PARAMETER ListOnly
    Only list available files without configuring mappings

.PARAMETER AutoConfigure
    Automatically configure mappings based on file pattern matching

.EXAMPLE
    .\Configure-NetworkShareMapping.ps1 -Environment PROD -ListOnly

.EXAMPLE
    .\Configure-NetworkShareMapping.ps1 -Environment DEV -AutoConfigure
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Environment to configure")]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,

    [Parameter(Mandatory = $false, HelpMessage = "Override network share path")]
    [string]$NetworkSharePath,

    [Parameter(Mandatory = $false, HelpMessage = "Only list available files")]
    [switch]$ListOnly,

    [Parameter(Mandatory = $false, HelpMessage = "Auto-configure mappings")]
    [switch]$AutoConfigure
)

function Write-ConfigLog {
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

function Get-NetworkShareFiles {
    param(
        [string]$NetworkPath,
        [string]$Environment
    )

    Write-ConfigLog "Scanning network share: $NetworkPath" "INFO"

    try {
        $csvFiles = Get-ChildItem -Path $NetworkPath -Filter "*.csv" -ErrorAction Stop | Where-Object { $_.Name -match $Environment -or $_.Name -match "App|OS" }

        Write-ConfigLog "Found $($csvFiles.Count) CSV files on network share:" "SUCCESS"
        foreach ($file in $csvFiles) {
            Write-ConfigLog "  $($file.Name) ($('{0:F2}' -f ($file.Length/1KB)) KB, Modified: $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" "INFO"
        }

        return $csvFiles
    }
    catch {
        Write-ConfigLog "Cannot access network share: $($_.Exception.Message)" "ERROR"
        return @()
    }
}

function Get-LocalExpectedFiles {
    param([string]$Environment)

    $expectedFiles = @()

    switch ($Environment) {
        'DEV' {
            $expectedFiles = @("AppTagPermissions_DEV.csv", "OS-Mappings_DEV.csv")
        }
        'PROD' {
            $expectedFiles = @("AppTagPermissions_PROD.csv", "OS-Mappings_PROD.csv")
        }
        'KLEB' {
            $expectedFiles = @("AppTagPermissions_KLE.csv", "OS-Mappings_KLE.csv")
        }
        'OT' {
            $expectedFiles = @("App-Permissions-OT.csv", "OS-Mappings-OT.csv")
        }
    }

    return $expectedFiles
}

function Find-BestMatch {
    param(
        [string]$LocalFileName,
        [array]$NetworkFiles
    )

    $localBase = [System.IO.Path]::GetFileNameWithoutExtension($LocalFileName).ToLower()
    $bestMatch = $null
    $bestScore = 0

    foreach ($networkFile in $NetworkFiles) {
        $networkBase = [System.IO.Path]::GetFileNameWithoutExtension($networkFile.Name).ToLower()

        # Calculate similarity score
        $score = 0

        # Check for common patterns
        if ($localBase -match "app.*permission" -and $networkFile.Name.ToLower() -match "app.*permission") { $score += 50 }
        if ($localBase -match "os.*mapping" -and $networkFile.Name.ToLower() -match "os.*mapping") { $score += 50 }

        # Check for environment match
        if ($networkFile.Name.ToLower() -match $Environment.ToLower()) { $score += 30 }

        # Check for similar keywords
        $localWords = $localBase -split "[-_]"
        $networkWords = $networkBase -split "[-_]"

        foreach ($localWord in $localWords) {
            if ($networkWords -contains $localWord) { $score += 10 }
        }

        if ($score > $bestScore) {
            $bestScore = $score
            $bestMatch = $networkFile
        }
    }

    return @{ File = $bestMatch; Score = $bestScore }
}

function Show-MappingSuggestions {
    param(
        [array]$LocalFiles,
        [array]$NetworkFiles,
        [string]$Environment
    )

    Write-ConfigLog "=== Network Share Mapping Suggestions ===" "INFO"

    $mappings = @{}

    foreach ($localFile in $LocalFiles) {
        $match = Find-BestMatch -LocalFileName $localFile -NetworkFiles $NetworkFiles

        if ($match.File -and $match.Score -gt 20) {
            Write-ConfigLog "Local: '$localFile' -> Network: '$($match.File.Name)' (Score: $($match.Score))" "SUCCESS"
            $mappings[$localFile] = $match.File.Name
        } else {
            Write-ConfigLog "Local: '$localFile' -> No good match found" "WARN"

            # Show all network files for manual selection
            Write-ConfigLog "Available network files:" "INFO"
            foreach ($nf in $NetworkFiles) {
                Write-ConfigLog "  - $($nf.Name)" "INFO"
            }
        }
    }

    Write-ConfigLog "" "INFO"
    Write-ConfigLog "Suggested configuration for $Environment environment:" "INFO"
    Write-ConfigLog "NetworkShareMapping = @{" "INFO"

    foreach ($mapping in $mappings.GetEnumerator()) {
        Write-ConfigLog "    `"$($mapping.Key)`" = `"$($mapping.Value)`"" "INFO"
    }

    Write-ConfigLog "}" "INFO"

    return $mappings
}

try {
    Write-ConfigLog "=== Network Share Mapping Configuration ===" "INFO"
    Write-ConfigLog "Environment: $Environment" "INFO"

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

    # Use provided network path or get from config
    $networkPath = if ($NetworkSharePath) { $NetworkSharePath } else { $envConfig.DataPaths.NetworkSharePath }

    if (-not $networkPath) {
        throw "No network share path configured for environment $Environment"
    }

    Write-ConfigLog "Network share path: $networkPath" "INFO"

    # Check if network share is accessible
    if (-not (Test-Path $networkPath)) {
        Write-ConfigLog "Network share not accessible - you may need to provide credentials first" "WARN"
        Write-ConfigLog "Run: .\Set-NetworkShareCredentials.ps1 -SharePath `"$networkPath`"" "INFO"

        if (-not $ListOnly) {
            $response = Read-Host "Would you like to continue anyway? (y/n)"
            if ($response -ne 'y') {
                exit 1
            }
        }
    }

    # Get network files
    $networkFiles = Get-NetworkShareFiles -NetworkPath $networkPath -Environment $Environment

    if (-not $ListOnly) {
        # Get expected local files
        $localFiles = Get-LocalExpectedFiles -Environment $Environment
        Write-ConfigLog "Expected local files for $Environment`: $($localFiles -join ', ')" "INFO"

        # Show mapping suggestions
        $mappings = Show-MappingSuggestions -LocalFiles $localFiles -NetworkFiles $networkFiles -Environment $Environment

        if ($AutoConfigure -and $mappings.Count -gt 0) {
            Write-ConfigLog "=== Auto-configuring mappings ===" "INFO"

            # TODO: Implement automatic configuration update to VMTagsConfig.psd1
            Write-ConfigLog "Auto-configuration feature coming soon - please manually update the configuration file" "WARN"
        }
    }

    Write-ConfigLog "=== Configuration Complete ===" "SUCCESS"
}
catch {
    Write-ConfigLog "Configuration failed: $($_.Exception.Message)" "ERROR"
}