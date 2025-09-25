# Network Share CSV File Management for VMTags
<#
.SYNOPSIS
    Retrieves CSV configuration files from network shares with fallback to local files

.DESCRIPTION
    This script provides centralized management of VMTags CSV configuration files
    by supporting retrieval from network shares with authentication and fallback
    mechanisms to local files when network shares are unavailable.

.PARAMETER NetworkPath
    UNC path to the network share containing CSV files (e.g., \\server\share\VMTags\Config)

.PARAMETER LocalFallbackPath
    Local path to use if network share is unavailable

.PARAMETER FileName
    Name of the CSV file to retrieve

.PARAMETER Credential
    Optional credentials for network share authentication

.PARAMETER EnableCaching
    Cache network files locally for improved performance (default: $true)

.PARAMETER CacheExpiryHours
    Number of hours before cached files expire (default: 4)

.EXAMPLE
    $csvData = Get-NetworkShareCSV -NetworkPath "\\fileserver\VMTags\Config\PROD" -LocalFallbackPath ".\Data\PROD" -FileName "AppTagPermissions_PROD.csv"

.EXAMPLE
    # With authentication
    $cred = Get-Credential
    $csvData = Get-NetworkShareCSV -NetworkPath "\\secure-server\VMTags" -LocalFallbackPath ".\Data\DEV" -FileName "OS-Mappings_DEV.csv" -Credential $cred
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "UNC path to network share")]
    [string]$NetworkPath,

    [Parameter(Mandatory = $true, HelpMessage = "Local fallback path")]
    [string]$LocalFallbackPath,

    [Parameter(Mandatory = $true, HelpMessage = "CSV file name")]
    [string]$FileName,

    [Parameter(Mandatory = $false, HelpMessage = "Network share credentials")]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false, HelpMessage = "Enable local caching")]
    [bool]$EnableCaching = $true,

    [Parameter(Mandatory = $false, HelpMessage = "Cache expiry in hours")]
    [int]$CacheExpiryHours = 4,

    [Parameter(Mandatory = $false, HelpMessage = "Force refresh from network")]
    [switch]$ForceRefresh,

    [Parameter(Mandatory = $false, HelpMessage = "Return file info instead of data")]
    [switch]$FileInfoOnly
)

function Write-NetworkShareLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] [NetworkShare] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARN"  { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage -ForegroundColor White }
    }
}

function Test-NetworkShareAccess {
    param(
        [string]$NetworkPath,
        [System.Management.Automation.PSCredential]$Credential
    )

    try {
        Write-NetworkShareLog "Testing network share access: $NetworkPath" "INFO"

        # Test if we can access the network path
        if ($Credential) {
            # Create a temporary PSDrive with credentials
            $driveLetter = Get-AvailableDriveLetter
            $null = New-PSDrive -Name $driveLetter -PSProvider FileSystem -Root $NetworkPath -Credential $Credential -ErrorAction Stop

            # Test access
            $testResult = Test-Path "${driveLetter}:\"

            # Clean up temporary drive
            Remove-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue

            return $testResult
        } else {
            # Test without credentials (current user context)
            return Test-Path $NetworkPath
        }
    }
    catch {
        Write-NetworkShareLog "Network share access test failed: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Get-AvailableDriveLetter {
    $usedDrives = (Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)
    $availableLetters = 'Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K','J','I','H','G','F','E','D'

    foreach ($letter in $availableLetters) {
        if ($letter -notin $usedDrives) {
            return $letter
        }
    }
    throw "No available drive letters for temporary network mapping"
}

function Get-CachedFilePath {
    param(
        [string]$NetworkPath,
        [string]$FileName
    )

    # Create cache directory based on network path hash
    $pathHash = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($NetworkPath))
    $hashString = [System.BitConverter]::ToString($pathHash).Replace('-', '').Substring(0, 8)

    $cacheDir = Join-Path $env:TEMP "VMTags_NetworkShare_Cache\$hashString"
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    return Join-Path $cacheDir $FileName
}

function Test-CacheValid {
    param(
        [string]$CachedFilePath,
        [int]$CacheExpiryHours
    )

    if (-not (Test-Path $CachedFilePath)) {
        return $false
    }

    $fileAge = (Get-Date) - (Get-Item $CachedFilePath).LastWriteTime
    return $fileAge.TotalHours -lt $CacheExpiryHours
}

function Copy-NetworkFileWithCredentials {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [System.Management.Automation.PSCredential]$Credential
    )

    if ($Credential) {
        # Map network drive temporarily
        $driveLetter = Get-AvailableDriveLetter
        $networkRoot = Split-Path $SourcePath -Parent

        try {
            Write-NetworkShareLog "Mapping network drive $driveLetter to $networkRoot" "INFO"
            $null = New-PSDrive -Name $driveLetter -PSProvider FileSystem -Root $networkRoot -Credential $Credential -ErrorAction Stop

            # Copy file using mapped drive
            $mappedSourcePath = $SourcePath.Replace($networkRoot, "${driveLetter}:")
            Copy-Item -Path $mappedSourcePath -Destination $DestinationPath -Force

            Write-NetworkShareLog "Successfully copied file from network share" "SUCCESS"
            return $true
        }
        catch {
            Write-NetworkShareLog "Failed to copy from network share: $($_.Exception.Message)" "ERROR"
            return $false
        }
        finally {
            # Clean up mapped drive
            if (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue) {
                Remove-PSDrive -Name $driveLetter -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        # Direct copy without credentials
        try {
            Copy-Item -Path $SourcePath -Destination $DestinationPath -Force
            Write-NetworkShareLog "Successfully copied file from network share (no credentials)" "SUCCESS"
            return $true
        }
        catch {
            Write-NetworkShareLog "Failed to copy from network share: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }
}

# Main execution
try {
    $networkFilePath = Join-Path $NetworkPath $FileName
    $localFilePath = Join-Path $LocalFallbackPath $FileName
    $cachedFilePath = Get-CachedFilePath -NetworkPath $NetworkPath -FileName $FileName

    Write-NetworkShareLog "=== Network Share CSV Retrieval Started ===" "INFO"
    Write-NetworkShareLog "Network Path: $networkFilePath" "INFO"
    Write-NetworkShareLog "Local Fallback: $localFilePath" "INFO"
    Write-NetworkShareLog "Cache Enabled: $EnableCaching" "INFO"

    $useNetworkFile = $false
    $useCache = $false
    $finalFilePath = ""

    # Check if we should use cached file
    if ($EnableCaching -and -not $ForceRefresh -and (Test-CacheValid -CachedFilePath $cachedFilePath -CacheExpiryHours $CacheExpiryHours)) {
        Write-NetworkShareLog "Using valid cached file: $cachedFilePath" "SUCCESS"
        $useCache = $true
        $finalFilePath = $cachedFilePath
    }
    # Try network share first
    elseif (Test-NetworkShareAccess -NetworkPath $NetworkPath -Credential $Credential) {
        Write-NetworkShareLog "Network share accessible, attempting to retrieve file" "INFO"

        if (Test-Path $networkFilePath) {
            Write-NetworkShareLog "File found on network share: $networkFilePath" "SUCCESS"

            if ($EnableCaching) {
                # Copy to cache
                if (Copy-NetworkFileWithCredentials -SourcePath $networkFilePath -DestinationPath $cachedFilePath -Credential $Credential) {
                    Write-NetworkShareLog "File cached locally: $cachedFilePath" "SUCCESS"
                    $finalFilePath = $cachedFilePath
                } else {
                    Write-NetworkShareLog "Failed to cache file, using network path directly" "WARN"
                    $finalFilePath = $networkFilePath
                }
            } else {
                $finalFilePath = $networkFilePath
            }
            $useNetworkFile = $true
        } else {
            Write-NetworkShareLog "File not found on network share: $networkFilePath" "WARN"
        }
    } else {
        Write-NetworkShareLog "Network share not accessible: $NetworkPath" "WARN"
    }

    # Fallback to local file
    if (-not $useNetworkFile -and -not $useCache) {
        Write-NetworkShareLog "Falling back to local file: $localFilePath" "INFO"

        if (Test-Path $localFilePath) {
            Write-NetworkShareLog "Local fallback file found: $localFilePath" "SUCCESS"
            $finalFilePath = $localFilePath
        } else {
            throw "Neither network file nor local fallback file exists. Network: $networkFilePath, Local: $localFilePath"
        }
    }

    # Return file info or data
    if ($FileInfoOnly) {
        return @{
            Success = $true
            FilePath = $finalFilePath
            Source = if ($useCache) { "Cache" } elseif ($useNetworkFile) { "Network" } else { "Local" }
            LastModified = (Get-Item $finalFilePath).LastWriteTime
            SizeBytes = (Get-Item $finalFilePath).Length
        }
    } else {
        # Import and return CSV data
        Write-NetworkShareLog "Importing CSV data from: $finalFilePath" "INFO"
        $csvData = Import-Csv -Path $finalFilePath

        Write-NetworkShareLog "Successfully imported $($csvData.Count) rows from CSV" "SUCCESS"

        return @{
            Success = $true
            Data = $csvData
            FilePath = $finalFilePath
            Source = if ($useCache) { "Cache" } elseif ($useNetworkFile) { "Network" } else { "Local" }
            RowCount = $csvData.Count
            LastModified = (Get-Item $finalFilePath).LastWriteTime
        }
    }
}
catch {
    $errorMsg = $_.Exception.Message
    Write-NetworkShareLog "Error retrieving CSV file: $errorMsg" "ERROR"

    return @{
        Success = $false
        Error = $errorMsg
        FilePath = ""
        Source = "None"
    }
}
finally {
    Write-NetworkShareLog "=== Network Share CSV Retrieval Completed ===" "INFO"
}