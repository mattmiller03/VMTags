<#
.SYNOPSIS
    [VERSION 2.1.0] Automates vCenter VM tags and permissions with advanced parallel processing for enterprise-scale performance.
.DESCRIPTION
    This script provides a powerful and repeatable way to manage vCenter VM tags and permissions.
    It connects to a specified vCenter Server and reads its configuration from two distinct CSV files:
    1.  App Permissions CSV: Contains mappings for application-specific tags to specific roles and security groups.
    2.  OS Mapping CSV: Defines how to tag VMs based on their Guest OS name. It maps OS patterns (e.g., "Microsoft Windows Server.*")
       to a target OS tag, a role, and an administrative security group.
    
    VERSION 2.1.0 ENHANCEMENTS:
    - Advanced parallel processing with thread-safe logging and mutex synchronization (70-85% performance gains)
    - Intelligent batch strategies: RoundRobin, PowerStateBalanced, and ComplexityBalanced distribution
    - Real-time progress tracking with comprehensive performance metrics and background reporting
    - Robust error handling with exponential backoff retry logic and comprehensive recovery
    - Memory-optimized concurrent collections for enterprise-scale VM inventories (1000+ VMs)
    - Enhanced security with comprehensive .gitignore protection for organizational data
    
    The script features robust logging, pre-flight checks, and ensures all connections are properly closed upon completion.
.PARAMETER vCenterServer
    The FQDN or IP address of the vCenter Server to connect to.
.PARAMETER Credential
    A PSCredential object for authenticating to the vCenter Server and its SSO domain.
.PARAMETER AppPermissionsCsvPath
    The full path to the CSV file containing application-specific permission data.
    Required columns: 'TagCategory', 'TagName', 'RoleName', 'SecurityGroupDomain', 'SecurityGroupName'.
.PARAMETER OsMappingCsvPath
    The full path to the CSV file that maps Guest OS patterns to tags and permissions.
    Required columns: 'GuestOSPattern', 'TargetTagName', 'RoleName', 'SecurityGroupDomain', 'SecurityGroupName'.
.PARAMETER Environment
    Specifies the operational environment (e.g., DEV, PROD). This determines which tag categories are used.
.PARAMETER EnableScriptDebug
    A switch parameter to enable verbose debug-level logging.
.PARAMETER EnableHierarchicalInheritance
    Enable automatic tag inheritance from parent containers (folders and resource pools).
    When enabled, VMs will automatically inherit tags from their parent folder hierarchy
    and resource pool hierarchy. This allows for easier tag management at scale.
.PARAMETER InheritanceCategories
    Comma-separated list of tag categories to inherit from parent containers.
    Default: Inherits App category tags only. Example: "App,Function,Custom"
.PARAMETER InheritanceDryRun
    Run inheritance in dry-run mode to see what tags would be inherited without making changes.
    Useful for testing and validation before applying inheritance rules.
.EXAMPLE
    # Execute for the PROD environment using separate CSV files.
    $cred = Get-Credential
    .\Set-vCenterObjects_Tag_Assigments.ps1 -vCenterServer 'vcsa01.corp.local' -Credential $cred `
        -AppPermissionsCsvPath 'C:\vCenter\App-Permissions.csv' `
        -OsMappingCsvPath 'C:\vCenter\OS-Mappings.csv' `
        -Environment 'PROD' -EnableScriptDebug

.EXAMPLE
    # Execute with hierarchical tag inheritance enabled
    $cred = Get-Credential
    .\Set-vCenterObjects_Tag_Assigments.ps1 -vCenterServer 'vcsa01.corp.local' -Credential $cred `
        -AppPermissionsCsvPath 'C:\vCenter\App-Permissions.csv' `
        -OsMappingCsvPath 'C:\vCenter\OS-Mappings.csv' `
        -Environment 'PROD' -EnableHierarchicalInheritance -InheritanceCategories "App,Function"

.EXAMPLE
    # Test hierarchical inheritance without making changes
    $cred = Get-Credential
    .\Set-vCenterObjects_Tag_Assigments.ps1 -vCenterServer 'vcsa01.corp.local' -Credential $cred `
        -AppPermissionsCsvPath 'C:\vCenter\App-Permissions.csv' `
        -OsMappingCsvPath 'C:\vCenter\OS-Mappings.csv' `
        -Environment 'DEV' -EnableHierarchicalInheritance -InheritanceDryRun
.NOTES
    REQUIREMENTS:
    - VMware PowerCLI module v12 or higher must be installed.
    - Valid CSV files are required for input.
#>
[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, HelpMessage = "vCenter Server name or IP")]
    [string]$vCenterServer,
    
    # Modified to accept either credential object or credential file path
    [Parameter(Mandatory = $false, HelpMessage = "Credential object for vCenter and SSO")]
    [System.Management.Automation.PSCredential]$Credential,
    
    [Parameter(Mandatory = $false, HelpMessage = "Path to credential file (alternative to Credential parameter)")]
    [string]$CredentialPath,
    
    [Parameter(Mandatory = $true, HelpMessage = "Path to the CSV file for App-team permissions.")]
    [string]$AppPermissionsCsvPath,

    [Parameter(Mandatory = $false, HelpMessage = "Log directory override from launcher")]
    [string]$LogDirectory,
    
    [Parameter(Mandatory = $true, HelpMessage = "Path to the CSV file for OS pattern mapping.")]
    [string]$OsMappingCsvPath,
    
    [Parameter(Mandatory = $true, HelpMessage = "Environment (e.g., DEV, PROD, KLEB, OT) to determine category names")]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,
    
    [Parameter(HelpMessage = "Enable detailed script debug logging")]
    [switch]$EnableScriptDebug,
    
    [Parameter(Mandatory = $false, HelpMessage = "Number of parallel threads for VM processing (default: 4, max: 10)")]
    [ValidateRange(1, 10)]
    [int]$MaxParallelThreads = 4,
    
    [Parameter(Mandatory = $false, HelpMessage = "Batch size for VM processing (default: 50)")]
    [ValidateRange(10, 500)]
    [int]$BatchSize = 50,

    [Parameter(Mandatory = $false, HelpMessage = "Enable hierarchical tag inheritance from folders and resource pools")]
    [switch]$EnableHierarchicalInheritance,

    [Parameter(Mandatory = $false, HelpMessage = "Comma-separated list of tag categories to inherit (default: App tags only)")]
    [string]$InheritanceCategories = "",

    [Parameter(Mandatory = $false, HelpMessage = "Dry run mode for inheritance - show what would be inherited without making changes")]
    [switch]$InheritanceDryRun,

    [Parameter(Mandatory = $false, HelpMessage = "Process only this specific VM (for vSphere Client integration)")]
    [string]$SpecificVM,

    [Parameter(Mandatory = $false, HelpMessage = "vSphere Client integration mode - optimized for single VM processing")]
    [switch]$vSphereClientMode,

    [Parameter(Mandatory = $false, HelpMessage = "Force reprocessing of VMs even if they were already processed today")]
    [switch]$ForceReprocess,

    [Parameter(Mandatory = $false, HelpMessage = "Enable inventory visibility by granting Read-Only on containers to all security groups")]
    [switch]$EnableInventoryVisibility,

    [Parameter(Mandatory = $false, HelpMessage = "Assign permissions on tagged folders and resource pools (not just VMs)")]
    [switch]$EnableContainerPermissions = $true
)

#region A) Credential Loading and Configs
# Add this credential loading logic at the beginning of your script

# Check for Aria Operations execution environment
function Test-AriaExecution {
    $ariaIndicators = @(
        'ARIA_EXECUTION',
        'AUTOMATION_MODE',
        'ARIA_NO_CREDENTIAL_INJECTION',
        'VRO_WORKFLOW_ID',
        'VRO_DEBUG'
    )

    foreach ($indicator in $ariaIndicators) {
        $value = [System.Environment]::GetEnvironmentVariable($indicator)
        if ($value) {
            if ($indicator -eq 'VRO_DEBUG' -and $value -eq '1') {
                $ariaNoCredInject = [System.Environment]::GetEnvironmentVariable('ARIA_NO_CREDENTIAL_INJECTION')
                if ($ariaNoCredInject -eq '1') {
                    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Aria Operations execution detected via: VRO_DEBUG=1 AND ARIA_NO_CREDENTIAL_INJECTION=1" -ForegroundColor Yellow
                    return $true
                }
            }
            elseif ($indicator -eq 'AUTOMATION_MODE' -and $value -eq 'ARIA_OPERATIONS') {
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Aria Operations execution detected via: AUTOMATION_MODE=ARIA_OPERATIONS" -ForegroundColor Yellow
                return $true
            }
            elseif ($indicator -ne 'VRO_DEBUG' -and $indicator -ne 'AUTOMATION_MODE') {
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Aria Operations execution detected via: $($indicator)=$($value)" -ForegroundColor Yellow
                return $true
            }
        }
    }
    return $false
}

# Load Aria service account credentials if in Aria execution context
if (-not $Credential -and (Test-AriaExecution)) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Attempting to retrieve Aria service account credentials..." -ForegroundColor Yellow

    try {
        # Load the Get-AriaServiceCredentials functions
        $getAriaScriptPath = Join-Path $PSScriptRoot "..\Get-AriaServiceCredentials.ps1"
        if (Test-Path $getAriaScriptPath) {
            . $getAriaScriptPath

            if ($Environment) {
                $Credential = Get-AriaServiceCredentials -Environment $Environment -Verbose
                if ($Credential) {
                    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [SUCCESS] Successfully retrieved Aria service account credentials for user: $($Credential.UserName)" -ForegroundColor Green
                    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Using Aria service account credentials for vCenter authentication" -ForegroundColor Green
                } else {
                    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARNING] No Aria service account credentials found, falling back to regular credential methods" -ForegroundColor Yellow
                }
            } else {
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARNING] Environment parameter not provided, cannot retrieve Aria service account credentials" -ForegroundColor Yellow
            }
        } else {
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARNING] Get-AriaServiceCredentials.ps1 not found at: $($getAriaScriptPath)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARNING] Failed to retrieve Aria service account credentials: $_" -ForegroundColor Yellow
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Falling back to regular credential methods" -ForegroundColor Yellow
    }
}

if ($CredentialPath) {
    # Handle special dry run mode
    if ($CredentialPath -eq "DRYRUN_MODE") {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Running in dry run mode - skipping credential loading" -ForegroundColor Yellow
        # Create a dummy credential for dry run mode
        $securePassword = ConvertTo-SecureString "DryRunPassword" -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential("DryRunUser", $securePassword)
    }
    elseif (Test-Path $CredentialPath) {
        # Only load from file if we don't already have Aria service account credentials
        if (-not $Credential) {
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Loading credentials from launcher..." -ForegroundColor Green
            try {
                $credentialMetadata = Import-Csv -Path $CredentialPath
                $credentialFile = $credentialMetadata.CredentialFile

                if (Test-Path $credentialFile) {
                    $Credential = Import-Clixml -Path $credentialFile
                    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Credentials loaded successfully for user: $($Credential.UserName)" -ForegroundColor Green
                } else {
                    throw "Credential file not found: $credentialFile"
                }
            }
            catch {
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] Failed to load credentials from file: $_" -ForegroundColor Red
                throw
            }
        } else {
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Using Aria service account credentials instead of launcher credentials" -ForegroundColor Green
        }
    }
    else {
        throw "Credential file path does not exist: $CredentialPath"
    }
}

if (-not $Credential) {
    throw "Either -Credential or -CredentialPath parameter must be provided"
}

# Standardized on $script: scope for all script-level variables for consistency and correctness.
$script:outputLog = @()
$script:logFolder = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "Logs"
$script:ssoConnected = $false
$script:ScriptDebugEnabled = $EnableScriptDebug.IsPresent
$script:EnableContainerPermissions = $EnableContainerPermissions.IsPresent

$EnvironmentCategoryConfig = @{
    'DEV'  = @{ App = 'vCenter-DEV-App-team'; Function = 'vCenter-DEV-Function'; OS = 'vCenter-DEV-OS' };
    'PROD' = @{ App = 'vCenter-PROD-App-team'; Function = 'vCenter-PROD-Function'; OS = 'vCenter-PROD-OS' };
    'KLEB' = @{ App = 'vCenter-Kleber-App-team'; Function = 'vCenter-Kleber-Function'; OS = 'vCenter-Kleber-OS' };
    'OT'   = @{ App = 'vCenter-OT-App-team'; Function = 'vCenter-OT-Function'; OS = 'vCenter-OT-OS' };
}

# Central mapping of environment to its corresponding SSO domain. This is the single source of truth.
$EnvironmentDomainMap = @{
    'DEV'  = 'DLA-Test-Dev.local'
    'PROD' = 'DLA-Prod.local'
    'KLEB' = 'DLA-Kleber.local'
    'OT'   = 'DLA-DaytonOT.local'
}
#endregion

#region B) LOGGING - FIXED VERSION
# Determine log folder - prioritize launcher LogDirectory parameter, fallback to script directory
$script:logFolder = $null

# Method 1: Use LogDirectory parameter if provided by launcher
if ($LogDirectory -and -not [string]::IsNullOrEmpty($LogDirectory)) {
    $script:logFolder = $LogDirectory
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Using launcher log directory: $($script:logFolder)" -ForegroundColor Green
}
else {
    # Fallback: Try multiple methods to determine the script location
    try {
        # Method 2: Try $MyInvocation.MyCommand.Path
        if ($MyInvocation.MyCommand.Path -and -not [string]::IsNullOrEmpty($MyInvocation.MyCommand.Path)) {
            $scriptDirectory = Split-Path $MyInvocation.MyCommand.Path -Parent
            if (-not [string]::IsNullOrEmpty($scriptDirectory)) {
                $script:logFolder = Join-Path $scriptDirectory "Logs"
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Using MyInvocation path for logs: $($script:logFolder)" -ForegroundColor Cyan
            }
        }
        # Method 3: Try $PSScriptRoot (PowerShell 3.0+)
        elseif ($PSScriptRoot -and -not [string]::IsNullOrEmpty($PSScriptRoot)) {
            $script:logFolder = Join-Path $PSScriptRoot "Logs"
            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Using PSScriptRoot for logs: $($script:logFolder)" -ForegroundColor Cyan
        }
        # Method 4: Use current location
        else {
            $currentLocation = Get-Location
            if ($currentLocation -and $currentLocation.Path) {
                $script:logFolder = Join-Path $currentLocation.Path "Logs"
                Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Using current location for logs: $($script:logFolder)" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN ] Error determining script location: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Final fallback to temp directory if all methods failed
if (-not $script:logFolder -or [string]::IsNullOrEmpty($script:logFolder)) {
    $script:logFolder = Join-Path $env:TEMP "VMTags_Logs"
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN ] Using temp directory fallback for logs: $($script:logFolder)" -ForegroundColor Yellow
}

# Create a single timestamp for this script execution
$script:ExecutionTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFileName = "VMTags_$($Environment)_$($script:ExecutionTimestamp).log"
$script:LogFilePath = Join-Path $script:logFolder $script:LogFileName

# Determine Reports folder - use direct Reports subfolder
$script:reportsFolder = Join-Path (Get-Location) "Reports"

# Add environment subdirectory to reports folder  
$script:reportsFolder = Join-Path $script:reportsFolder $Environment

# Ensure log directory exists
if (-not (Test-Path $script:logFolder)) {
    try {
        New-Item -Path $script:logFolder -ItemType Directory -Force | Out-Null
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Log folder created: $($script:logFolder)" -ForegroundColor Green
    }
    catch {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] Failed to create log folder $($script:logFolder): $($_.Exception.Message)" -ForegroundColor Red
        # Fallback to temp directory
        $script:logFolder = $env:TEMP
        $script:LogFilePath = Join-Path $script:logFolder $script:LogFileName
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN ] Using temp directory for logs: $($script:logFolder)" -ForegroundColor Yellow
    }
}

# Ensure reports directory exists
if (-not (Test-Path $script:reportsFolder)) {
    try {
        New-Item -Path $script:reportsFolder -ItemType Directory -Force | Out-Null
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Reports folder created: $($script:reportsFolder)" -ForegroundColor Green
    }
    catch {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ERROR] Failed to create reports folder $($script:reportsFolder): $($_.Exception.Message)" -ForegroundColor Red
        # Fallback to using log folder for reports
        $script:reportsFolder = $script:logFolder
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN ] Using log directory for reports: $($script:reportsFolder)" -ForegroundColor Yellow
    }
}

# Aria-specific logging format
function Write-AriaLog {
    param($Message, $Level = "INFO")
    
    # VMTags v2.1.0 - Sanitize message to protect sensitive data in Aria logs
    $sanitizedMessage = Protect-SensitiveData -Message $Message
    
    $ariaLogEntry = @{
        Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
        Level = $Level
        Source = "VMTags-Automation"
        Environment = $Environment
        Message = $sanitizedMessage
        Machine = $env:COMPUTERNAME
        User = $env:USERNAME
    }
    
    # Output in format Aria can parse
    $ariaLogEntry | ConvertTo-Json -Compress | Write-Host
}

function Protect-SensitiveData {
    <#
    .SYNOPSIS
        Sanitizes log messages to remove sensitive data patterns
    .DESCRIPTION
        VMTags v2.1.0 - Protects sensitive data in logs by replacing patterns with sanitized versions
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    
    $sanitized = $Message
    
    # Password patterns (case insensitive)
    $sanitized = $sanitized -replace '(?i)(password\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(passwd\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(pwd\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    
    # Token/Key patterns
    $sanitized = $sanitized -replace '(?i)(token\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(apikey\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(api[_-]?key\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(secret\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(private[_-]?key\s*[=:]\s*)([^\s;,]+)', '$1***REDACTED***'
    
    # SecureString patterns
    $sanitized = $sanitized -replace '(System\.Security\.SecureString)([^\s]*)', 'SecureString ***PROTECTED***'
    $sanitized = $sanitized -replace '(ConvertTo-SecureString\s+)([^\s;]+)', '$1***REDACTED***'
    
    # Credential object patterns - simplified patterns
    $sanitized = $sanitized -replace '(NetworkCredential\([^,)]+,\s*)([^)]+)', '$1***REDACTED***)'
    $sanitized = $sanitized -replace '(PSCredential\([^,)]+,\s*)([^)]+)', '$1***PROTECTED***)'
    
    # Connection string patterns
    $sanitized = $sanitized -replace '(?i)(server\s*=\s*[^;]+;\s*uid\s*=\s*[^;]+;\s*pwd\s*=\s*)([^;]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(password\s*=\s*)([^;"\s]+)', '$1***REDACTED***'
    
    # PowerShell argument sanitization - protect -Password, -Credential arguments
    $sanitized = $sanitized -replace '(?i)(-Password\s+)([^\s-]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(?i)(-Credential\s+)([^\s-]+)', '$1***PROTECTED***'
    
    # Session tokens and authentication strings
    $sanitized = $sanitized -replace '(?i)(session[_-]?(?:id|token|key)\s*[=:]\s*)([^\s;,]+)', '$1***SESSION_PROTECTED***'
    $sanitized = $sanitized -replace '(?i)(auth[_-]?(?:token|key)\s*[=:]\s*)([^\s;,]+)', '$1***AUTH_PROTECTED***'
    
    # vCenter session IDs and authentication tokens
    $sanitized = $sanitized -replace '(vmware-api-session-id[=:]\s*)([^\s;,]+)', '$1***VMWARE_SESSION***'
    $sanitized = $sanitized -replace '(SAML[_-]?token[=:]\s*)([^\s;,]+)', '$1***SAML_TOKEN***'
    
    # PowerCLI connection strings and session information
    $sanitized = $sanitized -replace '(Connect-VIServer.*-Password\s+)([^\s-]+)', '$1***REDACTED***'
    $sanitized = $sanitized -replace '(Connect-CisServer.*-Password\s+)([^\s-]+)', '$1***REDACTED***'
    
    return $sanitized
}

function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    $writeThisLog = $false
    switch ($Level.ToUpper()) {
        "INFO" { $writeThisLog = $true }
        "WARN" { $writeThisLog = $true }
        "ERROR" { $writeThisLog = $true }
        "DEBUG" {
            # Check the correct $script: scoped variable. This makes -EnableScriptDebug work.
            if ($script:ScriptDebugEnabled) {
                $writeThisLog = $true
            }
        }
    }
    
    if ($writeThisLog) {
        # VMTags v2.1.0 - Sanitize message to protect sensitive data
        $sanitizedMessage = Protect-SensitiveData -Message $Message
        
        $logEntry = [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Level     = $Level.ToUpper()
            Message   = $sanitizedMessage
        }
        
        $script:outputLog += $logEntry
        
        $hostColor = switch ($Level.ToUpper()) {
            "INFO"  { "Green" }
            "WARN"  { "Yellow" }
            "ERROR" { "Red" }
            "DEBUG" { "Gray" }
            Default { "White" }
        }
        
        Write-Host "$($logEntry.Timestamp) [$($logEntry.Level.PadRight(5))] $($logEntry.Message)" -ForegroundColor $hostColor
        
        # Write to THE SAME log file for this execution
        try {
            "$($logEntry.Timestamp) [$($logEntry.Level.PadRight(5))] $($logEntry.Message)" | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
        }
        catch {
            # Don't spam console with file logging errors
        }
    }
}

function Save-ExecutionLog {
    # Save the complete log at the end of execution
    try {
        $csvLogFileName = "VMTags_$($Environment)_Complete_$($script:ExecutionTimestamp).csv"
        $csvLogFilePath = Join-Path $script:reportsFolder $csvLogFileName
        
        $script:outputLog | Export-Csv -Path $csvLogFilePath -NoTypeInformation
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Complete execution log saved: $($csvLogFilePath)" -ForegroundColor Green
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Text log file: $($script:LogFilePath)" -ForegroundColor Green
    }
    catch {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN ] Failed to save execution log: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Cleanup-OldLogs {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$LogFolder,
        [Parameter(Mandatory = $true)]
        [int]$MaxLogsToKeep
    )
    
    Write-Log "Cleaning up old logs in '$($LogFolder)', keeping $($MaxLogsToKeep) most recent." "DEBUG"
    
    try {
        # Validate log folder path before proceeding
        if ([string]::IsNullOrEmpty($LogFolder) -or -not (Test-Path $LogFolder)) {
            Write-Log "Log folder '$($LogFolder)' does not exist or is invalid, skipping cleanup." "WARN"
            return
        }
        
        # Clean up .log files
        $logFiles = Get-ChildItem -Path $LogFolder -Filter "*.log" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($logFiles -and $logFiles.Count -gt $MaxLogsToKeep) {
            $filesToRemove = $logFiles | Select-Object -Skip $MaxLogsToKeep
            foreach ($file in $filesToRemove) {
                Write-Log "Removing old log file: $($file.FullName)" "DEBUG"
                Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Removed $($filesToRemove.Count) old log files" "DEBUG"
        }
        
        # Clean up .csv files
        $csvFiles = Get-ChildItem -Path $LogFolder -Filter "*.csv" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($csvFiles -and $csvFiles.Count -gt $MaxLogsToKeep) {
            $filesToRemove = $csvFiles | Select-Object -Skip $MaxLogsToKeep
            foreach ($file in $filesToRemove) {
                Write-Log "Removing old CSV file: $($file.FullName)" "DEBUG"
                Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Removed $($filesToRemove.Count) old CSV files" "DEBUG"
        }
        
        Write-Log "Log cleanup completed successfully" "DEBUG"
    }
    catch {
        Write-Log "Error during log cleanup: $($_.Exception.Message)" "WARN"
    }
}

# Initialize logging
Write-Log "Script started." "INFO"
Write-Log "Log directory: $($script:logFolder)" "INFO"
Write-Log "Log file: $($script:LogFileName)" "INFO"

# Perform log cleanup
try {
    Cleanup-OldLogs -LogFolder $script:logFolder -MaxLogsToKeep 5
}
catch {
    Write-Log "Log cleanup failed: $($_.Exception.Message)" "WARN"
}

Write-Log "Environment: $($Environment)" "INFO"
Write-Log "vCenter Server: $($vCenterServer)" "INFO"
Write-Log "Script Debug Enabled: $($script:ScriptDebugEnabled)" "INFO"
#endregion

#region C) SSO & OTHER HELPER FUNCTIONS
function Test-SsoModuleAvailable {
    #//-- FIXED --// Corrected the SSO module name for modern PowerCLI versions (v12+).
    $ssoModuleName = "VMware.vSphere.SsoAdmin"
    Write-Log "Checking for SSO module '$($ssoModuleName)'..." "DEBUG"
    try {
        if (Get-Module -Name $ssoModuleName -ListAvailable) {
            if (-not (Get-Module -Name $ssoModuleName)) {
                Import-Module $ssoModuleName -ErrorAction Stop | Out-Null
            }
            return $true
        }
        Write-Log "SSO module '$($ssoModuleName)' not found." "DEBUG"
        return $false
    }
    catch {
        Write-Log "Error checking/importing SSO module: $_" "WARN"
        return $false
    }
}
function Connect-SsoAdmin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential
    )
    Write-Log "Attempting to connect to SSO Admin server '$($Server)'..." "DEBUG"
    $script:ssoConnected = $false
    try {
        Connect-SsoAdminServer -Server $Server -Credential $Credential -ErrorAction Stop | Out-Null
        $script:ssoConnected = $true
        Write-Log "Successfully connected to SSO Admin server." "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to connect to SSO Admin server '$($Server)': $_" "ERROR"
        return $false
    }
}

function Test-VMOSDetection {
    param([string]$VMName = "*")
    
    Write-Log "=== VM OS Detection Diagnostic ===" "INFO"
    $vms = Get-VM -Name $VMName | Where-Object Name -notmatch '^(vCLS|VLC|stCtlVM)' | Select-Object -First 10
    
    foreach ($vm in $vms) {
        $osInfo = Get-VMOSInformation -VM $vm
        
        Write-Log "VM: $($osInfo.VMName)" "INFO"
        Write-Log "  Power State: $($osInfo.PowerState)" "INFO"
        Write-Log "  VMware Tools: $($osInfo.VMwareToolsStatus)" "INFO"
        Write-Log "  Guest OS (Tools): $($osInfo.GuestOS)" "INFO"
        Write-Log "  Configured OS: $($osInfo.ConfiguredOS)" "INFO"
        Write-Log "  Guest ID: $($osInfo.GuestID)" "INFO"
        Write-Log "  Has OS Info: $($osInfo.HasOSInfo)" "INFO"
        Write-Log "  ---" "INFO"
    }
}

function Get-ParentContainerTags {
    <#
    .SYNOPSIS
        Gets all tags from parent containers (folders and resource pools) of a VM
    .PARAMETER VM
        The virtual machine to check
    .PARAMETER TagCategories
        Array of tag category names to inherit (e.g., @("App", "Function"))
    .RETURNS
        Array of tags that should be inherited from parent containers
    #>
    param(
        [VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$VM,
        [string[]]$TagCategories = @()
    )

    try {
        $inheritableTags = @()

        # Get VM's folder hierarchy
        $vmFolder = $VM.Folder
        $folders = @()

        # Walk up the folder tree to root
        $currentFolder = $vmFolder
        while ($currentFolder -and $currentFolder.Name -ne "vm") {
            $folders += $currentFolder
            $currentFolder = Get-Folder -Id $currentFolder.ParentId -ErrorAction SilentlyContinue
        }

        # Check tags on each folder in hierarchy
        foreach ($folder in $folders) {
            $folderTags = Get-TagAssignment -Entity $folder -ErrorAction SilentlyContinue
            foreach ($tagAssignment in $folderTags) {
                $tag = $tagAssignment.Tag
                # Only inherit specified categories
                if ($TagCategories.Count -eq 0 -or $TagCategories -contains $tag.Category.Name) {
                    $inheritableTags += @{
                        Tag = $tag
                        Source = "Folder"
                        SourceName = $folder.Name
                        SourcePath = $folder.ExtensionData.Summary.FolderPath
                    }
                }
            }
        }

        # Get VM's resource pool hierarchy
        $vmResourcePool = $VM.ResourcePool
        $resourcePools = @()

        # Walk up the resource pool tree
        $currentRP = $vmResourcePool
        while ($currentRP -and $currentRP.Name -ne "Resources") {
            $resourcePools += $currentRP
            $currentRP = Get-ResourcePool -Id $currentRP.ParentId -ErrorAction SilentlyContinue
        }

        # Check tags on each resource pool in hierarchy
        foreach ($rp in $resourcePools) {
            $rpTags = Get-TagAssignment -Entity $rp -ErrorAction SilentlyContinue
            foreach ($tagAssignment in $rpTags) {
                $tag = $tagAssignment.Tag
                # Only inherit specified categories
                if ($TagCategories.Count -eq 0 -or $TagCategories -contains $tag.Category.Name) {
                    $inheritableTags += @{
                        Tag = $tag
                        Source = "ResourcePool"
                        SourceName = $rp.Name
                        SourcePath = $rp.ExtensionData.Summary.Config.MemoryAllocation.Limit
                    }
                }
            }
        }

        return $inheritableTags
    }
    catch {
        Write-Log "Error getting parent container tags for VM '$($VM.Name)': $_" "WARN"
        return @()
    }
}

function Process-HierarchicalTagInheritance {
    <#
    .SYNOPSIS
        Processes hierarchical tag inheritance for all VMs
    .PARAMETER TagCategories
        Array of tag category names to inherit
    .PARAMETER DryRun
        If true, only reports what would be done without making changes
    #>
    param(
        [string[]]$TagCategories = @(),
        [switch]$DryRun = $false
    )

    try {
        Write-Log "=== Processing Hierarchical Tag Inheritance ===" "INFO"
        Write-Log "Inheritable categories: $($TagCategories -join ', ')" "INFO"

        if ($DryRun) {
            Write-Log "DRY RUN MODE: No changes will be made" "INFO"
        }

        # Get all VMs (excluding system VMs)
        $allVMs = Get-VM | Where-Object Name -notmatch '^(vCLS|VLC|stCtlVM)'
        Write-Log "Processing $($allVMs.Count) VMs for hierarchical tag inheritance" "INFO"

        # Enhanced Linked Mode deduplication for hierarchical inheritance
        $processedVMsFile = Join-Path $script:logFolder "ProcessedVMs_Inheritance_$($Environment)_$(Get-Date -Format 'yyyyMMdd').json"
        $processedInheritanceVMs = @{}

        # Load existing processed VMs if file exists
        if (Test-Path $processedVMsFile) {
            try {
                $existingData = Get-Content $processedVMsFile -Raw | ConvertFrom-Json
                if ($existingData -and $existingData.PSObject.Properties) {
                    foreach ($property in $existingData.PSObject.Properties) {
                        $processedInheritanceVMs[$property.Name] = $property.Value
                    }
                }
                Write-Log "Loaded $($processedInheritanceVMs.Count) previously processed VMs from inheritance deduplication file" "DEBUG"
            }
            catch {
                Write-Log "Could not load inheritance deduplication file, starting fresh: $($_.Exception.Message)" "DEBUG"
                $processedInheritanceVMs = @{}
            }
        }

        # Filter out VMs that have already been processed for inheritance today
        $originalInheritanceCount = $allVMs.Count
        $allVMs = $allVMs | Where-Object {
            $vmKey = "$($_.Name)|$($_.Id)"
            if ($processedInheritanceVMs.ContainsKey($vmKey)) {
                Write-Log "Skipping VM '$($_.Name)' inheritance - already processed by vCenter '$($processedInheritanceVMs[$vmKey])'" "DEBUG"
                return $false
            }
            return $true
        }

        if ($originalInheritanceCount -ne $allVMs.Count) {
            Write-Log "Filtered out $($originalInheritanceCount - $allVMs.Count) already-processed VMs for inheritance. Processing $($allVMs.Count) remaining VMs." "INFO"
        }

        $vmProcessed = 0
        $tagsInherited = 0
        $tagsSkipped = 0
        $errors = 0

        foreach ($vm in $allVMs) {
            $vmProcessed++

            try {
                # Get current VM tags
                $currentVMTags = Get-TagAssignment -Entity $vm -ErrorAction SilentlyContinue | ForEach-Object { $_.Tag }

                # Get inheritable tags from parent containers
                $inheritableTags = Get-ParentContainerTags -VM $vm -TagCategories $TagCategories

                if ($inheritableTags.Count -eq 0) {
                    Write-Log "VM '$($vm.Name)': No inheritable tags found in parent containers" "DEBUG"
                    continue
                }

                # Process each inheritable tag
                foreach ($inheritableTag in $inheritableTags) {
                    $tag = $inheritableTag.Tag
                    $source = $inheritableTag.Source
                    $sourceName = $inheritableTag.SourceName

                    # Check if VM already has this tag
                    $existingTag = $currentVMTags | Where-Object { $_.Id -eq $tag.Id }

                    if ($existingTag) {
                        Write-Log "VM '$($vm.Name)': Already has tag '$($tag.Name)' - skipping inheritance" "DEBUG"
                        $tagsSkipped++
                        continue
                    }

                    # Check if VM already has a different tag in the same category
                    $existingCategoryTag = $currentVMTags | Where-Object { $_.Category.Id -eq $tag.Category.Id }

                    if ($existingCategoryTag) {
                        Write-Log "VM '$($vm.Name)': Already has tag '$($existingCategoryTag.Name)' in category '$($tag.Category.Name)' - skipping inheritance of '$($tag.Name)'" "DEBUG"
                        $tagsSkipped++
                        continue
                    }

                    # Apply the inherited tag
                    if (-not $DryRun) {
                        try {
                            New-TagAssignment -Tag $tag -Entity $vm -ErrorAction Stop
                            Write-Log "VM '$($vm.Name)': Inherited tag '$($tag.Name)' from $($source) '$($sourceName)'" "INFO"
                            $tagsInherited++
                        }
                        catch {
                            Write-Log "VM '$($vm.Name)': Failed to inherit tag '$($tag.Name)' from $($source) '$($sourceName)': $_" "ERROR"
                            $errors++
                        }
                    } else {
                        Write-Log "VM '$($vm.Name)': WOULD inherit tag '$($tag.Name)' from $($source) '$($sourceName)'" "INFO"
                        $tagsInherited++
                    }
                }
            }
            catch {
                Write-Log "Error processing hierarchical inheritance for VM '$($vm.Name)': $_" "ERROR"
                $errors++
            }

            # Progress reporting
            if ($vmProcessed % 50 -eq 0) {
                Write-Log "Hierarchical inheritance progress: $($vmProcessed)/$($allVMs.Count) VMs processed" "INFO"
            }

            # Track processed VM for inheritance deduplication across vCenter connections
            $vmKey = "$($vm.Name)|$($vm.Id)"
            $processedInheritanceVMs[$vmKey] = $vCenterServer
        }

        # Save processed VMs to inheritance deduplication file
        if ($processedInheritanceVMs.Count -gt 0) {
            try {
                $processedInheritanceVMs | ConvertTo-Json | Set-Content $processedVMsFile -Force
                Write-Log "Saved $($processedInheritanceVMs.Count) processed VMs to inheritance deduplication file" "DEBUG"
            }
            catch {
                Write-Log "Could not save inheritance deduplication file: $($_.Exception.Message)" "WARN"
            }
        }

        Write-Log "Hierarchical Tag Inheritance Summary:" "INFO"
        Write-Log "  VMs Processed: $($vmProcessed)" "INFO"
        Write-Log "  Tags Inherited: $($tagsInherited)" "INFO"
        Write-Log "  Tags Skipped: $($tagsSkipped)" "INFO"
        Write-Log "  Errors: $($errors)" "INFO"

        return @{
            VMsProcessed = $vmProcessed
            TagsInherited = $tagsInherited
            TagsSkipped = $tagsSkipped
            Errors = $errors
        }
    }
    catch {
        Write-Log "Critical error in hierarchical tag inheritance processing: $_" "ERROR"
        throw
    }
}

function Process-FolderBasedPermissions {
    <#
    .SYNOPSIS
        Processes permissions for VMs based on tags assigned to their parent folders and resource pools
    .DESCRIPTION
        This function addresses the issue where application admin tags are assigned to VM folders
        or resource pools but the associated permissions need to be applied to all VMs within those containers.
        It scans all folders and resource pools for application tags and applies permissions to contained VMs.
    .PARAMETER AppPermissionData
        Array of application permission data from CSV
    .PARAMETER AppCategoryName
        Name of the application tag category to process
    .RETURNS
        Hashtable with processing statistics
    #>
    param(
        [array]$AppPermissionData,
        [string]$AppCategoryName
    )

    Write-Log "Starting folder and resource pool based permission propagation analysis..." "INFO"

    $foldersProcessed = 0
    $resourcePoolsProcessed = 0
    $vmPermissionsApplied = 0
    $folderTagsFound = 0
    $resourcePoolTagsFound = 0
    $errors = 0

    try {
        # Get all folders and resource pools in the vCenter
        Write-Log "Retrieving all VM folders..." "DEBUG"
        $allFolders = Get-Folder -Type VM -ErrorAction SilentlyContinue
        Write-Log "Found $($allFolders.Count) VM folders to analyze" "INFO"

        Write-Log "Retrieving all resource pools..." "DEBUG"
        $allResourcePools = Get-ResourcePool -ErrorAction SilentlyContinue
        Write-Log "Found $($allResourcePools.Count) resource pools to analyze" "INFO"

        # Get the app category object
        $appCat = Get-TagCategory -Name $AppCategoryName -ErrorAction SilentlyContinue
        if (-not $appCat) {
            Write-Log "Application tag category '$($AppCategoryName)' not found - skipping folder and resource pool processing" "WARN"
            return @{
                FoldersProcessed = 0
                ResourcePoolsProcessed = 0
                VMPermissionsApplied = 0
                FolderTagsFound = 0
                ResourcePoolTagsFound = 0
                Errors = 1
            }
        }

        # Process each folder
        foreach ($folder in $allFolders) {
            $foldersProcessed++

            try {
                # Get tags on this folder that match our app category
                $folderTags = Get-TagAssignment -Entity $folder -ErrorAction SilentlyContinue |
                              Where-Object { $_.Tag.Category.Name -eq $AppCategoryName }

                if ($folderTags.Count -eq 0) {
                    Write-Log "Folder '$($folder.Name)': No app tags found" "DEBUG"
                    continue
                }

                Write-Log "Folder '$($folder.Name)': Found $($folderTags.Count) app tags" "INFO"
                $folderTagsFound += $folderTags.Count

                # Debug: List all tags found on this folder
                Write-Log "Folder '$($folder.Name)': Tag details:" "DEBUG"
                $tagIndex = 0
                foreach ($debugTag in $folderTags) {
                    $tagIndex++
                    Write-Log "  Tag #$($tagIndex)`: '$($debugTag.Tag.Name)' (Category: '$($debugTag.Tag.Category.Name)')" "DEBUG"
                }

                # ENHANCEMENT: Assign permissions on the folder itself for each tagged permission
                if ($script:EnableContainerPermissions) {
                    Write-Log "Folder '$($folder.Name)': Assigning permissions on the folder container itself" "INFO"
                    foreach ($folderTagAssignment in $folderTags) {
                        $tagName = $folderTagAssignment.Tag.Name

                        # Find permission mappings for this tag
                        $permissionRows = @($AppPermissionData | Where-Object {
                            $_.TagCategory -ieq $AppCategoryName -and $_.TagName -ieq $tagName
                        })

                        foreach ($permissionRow in $permissionRows) {
                            $principal = "$($permissionRow.SecurityGroupDomain)\$($permissionRow.SecurityGroupName)"

                            # Validate security group exists
                            if (Test-SsoGroupExistsSimple -Domain $permissionRow.SecurityGroupDomain -GroupName $permissionRow.SecurityGroupName) {
                                # Assign permission on the container itself (non-propagating)
                                $containerResult = Assign-ContainerPermission -Container $folder -Principal $principal -RoleName $permissionRow.RoleName -Propagate $false
                                if ($containerResult.Action -eq "Created") {
                                    Write-Log "Folder '$($folder.Name)': Assigned $($permissionRow.RoleName) permission to $principal on container" "INFO"
                                }
                            }
                        }
                    }
                } else {
                    Write-Log "Folder '$($folder.Name)': Container permissions disabled (use -EnableContainerPermissions)" "DEBUG"
                }

                # Get all VMs in this folder (recursively)
                $vmsInFolder = Get-VM -Location $folder -ErrorAction SilentlyContinue |
                               Where-Object Name -notmatch '^(vCLS|VLC|stCtlVM)'

                if ($vmsInFolder.Count -eq 0) {
                    Write-Log "Folder '$($folder.Name)': No VMs found" "DEBUG"
                    continue
                }

                Write-Log "Folder '$($folder.Name)': Found $($vmsInFolder.Count) VMs to process" "INFO"

                # Process each tag found on the folder
                $processedTagCount = 0
                foreach ($folderTagAssignment in $folderTags) {
                    $processedTagCount++
                    $tagName = $folderTagAssignment.Tag.Name

                    Write-Log "Folder '$($folder.Name)': Processing tag $processedTagCount of $($folderTags.Count): '$($tagName)'" "INFO"

                    # Find ALL corresponding permission data for this tag (may be multiple rows for different roles)
                    $permissionRows = @($AppPermissionData | Where-Object {
                        $_.TagCategory -ieq $AppCategoryName -and $_.TagName -ieq $tagName
                    })

                    if ($permissionRows.Count -eq 0) {
                        Write-Log "Folder '$($folder.Name)': No permission mapping found for tag '$($tagName)'" "WARN"
                        continue
                    }

                    Write-Log "Folder '$($folder.Name)': Found $($permissionRows.Count) permission mappings for tag '$($tagName)'" "DEBUG"

                    # Process each permission mapping for this tag
                    foreach ($permissionRow in $permissionRows) {
                        # Build principal name
                        $principal = "$($permissionRow.SecurityGroupDomain)\$($permissionRow.SecurityGroupName)"

                        # Validate security group exists
                        if (-not (Test-SsoGroupExistsSimple -Domain $permissionRow.SecurityGroupDomain -GroupName $permissionRow.SecurityGroupName)) {
                            Write-Log "Folder '$($folder.Name)': Skipping permissions for principal '$($principal)' as SSO group was not found" "WARN"
                            continue
                        }

                        Write-Log "Folder '$($folder.Name)': Applying permissions for tag '$($tagName)' (role: $($permissionRow.RoleName)) to $($vmsInFolder.Count) VMs" "INFO"

                        # Apply permissions to all VMs in the folder
                        foreach ($vm in $vmsInFolder) {
                            try {
                                $result = Assign-PermissionIfNeeded -VM $vm -Principal $principal -RoleName $permissionRow.RoleName
                                Track-PermissionAssignment -Result $result -VM $vm -Source "FolderPermissions"

                                switch ($result.Action) {
                                    "Created" {
                                        $vmPermissionsApplied++
                                        $script:ExecutionSummary.PermissionsAssigned++
                                        Write-Log "Folder '$($folder.Name)': Applied permission to VM '$($vm.Name)' for tag '$($tagName)' (role: $($permissionRow.RoleName))" "DEBUG"
                                    }
                                    "Skipped" {
                                        $script:ExecutionSummary.PermissionsSkipped++
                                        Write-Log "Folder '$($folder.Name)': Skipped permission for VM '$($vm.Name)' for tag '$($tagName)' (role: $($permissionRow.RoleName)) - $($result.Reason)" "DEBUG"
                                    }
                                    "Failed" {
                                        $script:ExecutionSummary.PermissionsFailed++
                                        $script:ExecutionSummary.ErrorsEncountered++
                                        $errors++
                                    }
                                }
                            }
                            catch {
                                Write-Log "Folder '$($folder.Name)': Error applying permissions to VM '$($vm.Name)' for tag '$($tagName)' (role: $($permissionRow.RoleName)): $_" "ERROR"
                                $errors++
                            }
                        }
                    }

                    Write-Log "Folder '$($folder.Name)': Completed processing tag '$($tagName)' ($processedTagCount of $($folderTags.Count))" "DEBUG"
                }

                Write-Log "Folder '$($folder.Name)': Finished processing all $($folderTags.Count) tags" "INFO"
            }
            catch {
                Write-Log "Error processing folder '$($folder.Name)': $_" "ERROR"
                $errors++
            }

            # Progress reporting for large environments
            if ($foldersProcessed % 25 -eq 0) {
                Write-Log "Folder processing progress: $($foldersProcessed)/$($allFolders.Count) folders analyzed" "INFO"
            }
        }

        # Process each resource pool
        foreach ($resourcePool in $allResourcePools) {
            $resourcePoolsProcessed++

            try {
                # Get tags on this resource pool that match our app category
                $resourcePoolTags = Get-TagAssignment -Entity $resourcePool -ErrorAction SilentlyContinue |
                                    Where-Object { $_.Tag.Category.Name -eq $AppCategoryName }

                if ($resourcePoolTags.Count -eq 0) {
                    Write-Log "Resource Pool '$($resourcePool.Name)': No app tags found" "DEBUG"
                    continue
                }

                Write-Log "Resource Pool '$($resourcePool.Name)': Found $($resourcePoolTags.Count) app tags" "INFO"
                $resourcePoolTagsFound += $resourcePoolTags.Count

                # Debug: List all tags found on this resource pool
                Write-Log "Resource Pool '$($resourcePool.Name)': Tag details:" "DEBUG"
                $rpTagIndex = 0
                foreach ($debugTag in $resourcePoolTags) {
                    $rpTagIndex++
                    Write-Log "  Tag #$($rpTagIndex)`: '$($debugTag.Tag.Name)' (Category: '$($debugTag.Tag.Category.Name)')" "DEBUG"
                }

                # ENHANCEMENT: Assign permissions on the resource pool itself for each tagged permission
                if ($script:EnableContainerPermissions) {
                    Write-Log "Resource Pool '$($resourcePool.Name)': Assigning permissions on the resource pool container itself" "INFO"
                    foreach ($resourcePoolTagAssignment in $resourcePoolTags) {
                        $tagName = $resourcePoolTagAssignment.Tag.Name

                        # Find permission mappings for this tag
                        $permissionRows = @($AppPermissionData | Where-Object {
                            $_.TagCategory -ieq $AppCategoryName -and $_.TagName -ieq $tagName
                        })

                        foreach ($permissionRow in $permissionRows) {
                            $principal = "$($permissionRow.SecurityGroupDomain)\$($permissionRow.SecurityGroupName)"

                            # Validate security group exists
                            if (Test-SsoGroupExistsSimple -Domain $permissionRow.SecurityGroupDomain -GroupName $permissionRow.SecurityGroupName) {
                                # Assign permission on the container itself (non-propagating)
                                $containerResult = Assign-ContainerPermission -Container $resourcePool -Principal $principal -RoleName $permissionRow.RoleName -Propagate $false
                                if ($containerResult.Action -eq "Created") {
                                    Write-Log "Resource Pool '$($resourcePool.Name)': Assigned $($permissionRow.RoleName) permission to $principal on container" "INFO"
                                }
                            }
                        }
                    }
                } else {
                    Write-Log "Resource Pool '$($resourcePool.Name)': Container permissions disabled (use -EnableContainerPermissions)" "DEBUG"
                }

                # Get all VMs in this resource pool
                $vmsInResourcePool = Get-VM -Location $resourcePool -ErrorAction SilentlyContinue |
                                     Where-Object Name -notmatch '^(vCLS|VLC|stCtlVM)'

                if ($vmsInResourcePool.Count -eq 0) {
                    Write-Log "Resource Pool '$($resourcePool.Name)': No VMs found" "DEBUG"
                    continue
                }

                Write-Log "Resource Pool '$($resourcePool.Name)': Found $($vmsInResourcePool.Count) VMs to process" "INFO"

                # Process each tag found on the resource pool
                $rpProcessedTagCount = 0
                foreach ($resourcePoolTagAssignment in $resourcePoolTags) {
                    $rpProcessedTagCount++
                    $tagName = $resourcePoolTagAssignment.Tag.Name

                    Write-Log "Resource Pool '$($resourcePool.Name)': Processing tag $($rpProcessedTagCount) of $($resourcePoolTags.Count): '$($tagName)'" "INFO"

                    # Find ALL corresponding permission data for this tag (may be multiple rows for different roles)
                    $permissionRows = @($AppPermissionData | Where-Object {
                        $_.TagCategory -ieq $AppCategoryName -and $_.TagName -ieq $tagName
                    })

                    if ($permissionRows.Count -eq 0) {
                        Write-Log "Resource Pool '$($resourcePool.Name)': No permission mapping found for tag '$($tagName)'" "WARN"
                        continue
                    }

                    Write-Log "Resource Pool '$($resourcePool.Name)': Found $($permissionRows.Count) permission mappings for tag '$($tagName)'" "DEBUG"

                    # Process each permission mapping for this tag
                    foreach ($permissionRow in $permissionRows) {
                        # Build principal name
                        $principal = "$($permissionRow.SecurityGroupDomain)\$($permissionRow.SecurityGroupName)"

                        # Validate security group exists
                        if (-not (Test-SsoGroupExistsSimple -Domain $permissionRow.SecurityGroupDomain -GroupName $permissionRow.SecurityGroupName)) {
                            Write-Log "Resource Pool '$($resourcePool.Name)': Skipping permissions for principal '$($principal)' as SSO group was not found" "WARN"
                            continue
                        }

                        Write-Log "Resource Pool '$($resourcePool.Name)': Applying permissions for tag '$($tagName)' (role: $($permissionRow.RoleName)) to $($vmsInResourcePool.Count) VMs" "INFO"

                        # Apply permissions to all VMs in the resource pool
                        foreach ($vm in $vmsInResourcePool) {
                            try {
                                $result = Assign-PermissionIfNeeded -VM $vm -Principal $principal -RoleName $permissionRow.RoleName
                                Track-PermissionAssignment -Result $result -VM $vm -Source "ResourcePoolPermissions"

                                switch ($result.Action) {
                                    "Created" {
                                        $vmPermissionsApplied++
                                        $script:ExecutionSummary.PermissionsAssigned++
                                        Write-Log "Resource Pool '$($resourcePool.Name)': Applied permission to VM '$($vm.Name)' for tag '$($tagName)' (role: $($permissionRow.RoleName))" "DEBUG"
                                    }
                                    "Skipped" {
                                        $script:ExecutionSummary.PermissionsSkipped++
                                        Write-Log "Resource Pool '$($resourcePool.Name)': Skipped permission for VM '$($vm.Name)' for tag '$($tagName)' (role: $($permissionRow.RoleName)) - $($result.Reason)" "DEBUG"
                                    }
                                    "Failed" {
                                        $script:ExecutionSummary.PermissionsFailed++
                                        $script:ExecutionSummary.ErrorsEncountered++
                                        $errors++
                                    }
                                }
                            }
                            catch {
                                Write-Log "Resource Pool '$($resourcePool.Name)': Error applying permissions to VM '$($vm.Name)' for tag '$($tagName)' (role: $($permissionRow.RoleName)): $_" "ERROR"
                                $errors++
                            }
                        }
                    }

                    Write-Log "Resource Pool '$($resourcePool.Name)': Completed processing tag '$($tagName)' ($rpProcessedTagCount of $($resourcePoolTags.Count))" "DEBUG"
                }

                Write-Log "Resource Pool '$($resourcePool.Name)': Finished processing all $($resourcePoolTags.Count) tags" "INFO"
            }
            catch {
                Write-Log "Error processing resource pool '$($resourcePool.Name)': $_" "ERROR"
                $errors++
            }

            # Progress reporting for large environments
            if ($resourcePoolsProcessed % 25 -eq 0) {
                Write-Log "Resource Pool processing progress: $($resourcePoolsProcessed)/$($allResourcePools.Count) resource pools analyzed" "INFO"
            }
        }

        Write-Log "Folder and Resource Pool Based Permission Propagation Summary:" "INFO"
        Write-Log "  Folders Processed: $($foldersProcessed)" "INFO"
        Write-Log "  Folder Tags Found: $($folderTagsFound)" "INFO"
        Write-Log "  Resource Pools Processed: $($resourcePoolsProcessed)" "INFO"
        Write-Log "  Resource Pool Tags Found: $($resourcePoolTagsFound)" "INFO"
        Write-Log "  VM Permissions Applied: $($vmPermissionsApplied)" "INFO"
        Write-Log "  Errors: $($errors)" "INFO"

        return @{
            FoldersProcessed = $foldersProcessed
            ResourcePoolsProcessed = $resourcePoolsProcessed
            VMPermissionsApplied = $vmPermissionsApplied
            FolderTagsFound = $folderTagsFound
            ResourcePoolTagsFound = $resourcePoolTagsFound
            Errors = $errors
        }
    }
    catch {
        Write-Log "Critical error in folder and resource pool permission processing: $_" "ERROR"
        return @{
            FoldersProcessed = $foldersProcessed
            ResourcePoolsProcessed = $resourcePoolsProcessed
            VMPermissionsApplied = $vmPermissionsApplied
            FolderTagsFound = $folderTagsFound
            ResourcePoolTagsFound = $resourcePoolTagsFound
            Errors = $errors + 1
        }
    }
}

function Get-VMOSInformation {
    param([VMware.VimAutomation.ViCore.Types.V1.Inventory.VirtualMachine]$VM)
    
    $osInfo = @{
        VMName = $VM.Name
        PowerState = $VM.PowerState
        GuestOS = $null
        ConfiguredOS = $null
        GuestID = $null
        VMwareToolsStatus = $null
        HasOSInfo = $false
    }
    
    # Get VMware Tools status
    try {
        $osInfo.VMwareToolsStatus = $VM.ExtensionData.Guest.ToolsStatus
    }
    catch {
        $osInfo.VMwareToolsStatus = "Unknown"
    }
    
    # Get Guest OS (from VMware Tools)
    if (-not [string]::IsNullOrWhiteSpace($VM.Guest.OSFullName)) {
        $osInfo.GuestOS = $VM.Guest.OSFullName
        $osInfo.HasOSInfo = $true
    }
    
    # Get Configured OS (from VM settings)
    if (-not [string]::IsNullOrWhiteSpace($VM.ExtensionData.Config.GuestFullName)) {
        $osInfo.ConfiguredOS = $VM.ExtensionData.Config.GuestFullName
        $osInfo.HasOSInfo = $true
    }
    
    # Get Guest ID
    if (-not [string]::IsNullOrWhiteSpace($VM.ExtensionData.Config.GuestId)) {
        $osInfo.GuestID = $VM.ExtensionData.Config.GuestId
        $osInfo.HasOSInfo = $true
    }
    
    return $osInfo
}

function Test-SsoGroupExistsSimple {
    param(
        [string]$Domain,
        [string]$GroupName
    )
    if (-not $script:ssoConnected) {
        Write-Log "SSO is not connected. Cannot check group existence for '$($Domain)\$($GroupName)'." "WARN"
        return $true # Fails open - assume it exists if we can't check
    }
    Write-Log "Checking SSO group existence for '$($GroupName)' in domain '$($Domain)'..." "DEBUG"
    try {
        Get-SsoGroup -Name $GroupName -Domain $Domain -ErrorAction Stop | Out-Null
        Write-Log "SSO group '$($GroupName)@$($Domain)' found." "DEBUG"
        return $true
    }
    catch {
        Write-Log "SSO group '$($GroupName)@$($Domain)' not found: $($_.Exception.Message)" "ERROR"
        return $false
    }
}
function Ensure-TagCategory {
    # PowerCLI 13+ Note: EntityType cannot be modified on existing categories using Set-TagCategory
    # EntityType can only be set during category creation with New-TagCategory
    param([string]$CategoryName, [string]$Description = "Managed by script", [string]$Cardinality = "MULTIPLE", [string[]]$EntityType = @("VirtualMachine", "Folder", "VApp", "ResourcePool"))
    $existingCat = Get-TagCategory -Name $CategoryName -ErrorAction SilentlyContinue
    if ($existingCat) {
        # Check if existing category has required entity types
        $currentEntityTypes = $existingCat.EntityType
        $missingTypes = @()

        foreach ($type in $EntityType) {
            if ($currentEntityTypes -notcontains $type) {
                $missingTypes += $type
            }
        }

        if ($missingTypes.Count -gt 0) {
            Write-Log "Category '$($CategoryName)' exists but is missing entity types: [$($missingTypes -join ', ')]. Current: [$($currentEntityTypes -join ', ')]" "WARN"
            Write-Log "NOTE: PowerCLI 13+ does not support updating EntityType on existing categories. Manual update required if needed." "WARN"
            Write-Log "Continuing with existing category configuration" "INFO"
        } else {
            Write-Log "Category '$($CategoryName)' exists with correct entity types: [$($currentEntityTypes -join ', ')]" "DEBUG"
        }

        return $existingCat
    }
    Write-Log "Category '$($CategoryName)' not found, creating..." "INFO"
    try {
        return New-TagCategory -Name $CategoryName -Description $Description -Cardinality $Cardinality -EntityType $EntityType -ErrorAction Stop
    }
    catch {
        # Handle parallel processing race conditions for categories too
        if ($_.Exception.Message -match "already.exists|AlreadyExists") {
            Write-Log "Category '$($CategoryName)' was created by another thread - checking for existing category" "DEBUG"
            $existingCatAfterError = Get-TagCategory -Name $CategoryName -ErrorAction SilentlyContinue
            if ($existingCatAfterError) {
                Write-Log "Successfully found existing category '$($CategoryName)'" "INFO"
                return $existingCatAfterError
            }
        } else {
            Write-Log "Unexpected category creation error for '$($CategoryName)': $_" "WARN"
        }
        
        # Final check for category existence
        $finalCheck = Get-TagCategory -Name $CategoryName -ErrorAction SilentlyContinue
        if ($finalCheck) {
            Write-Log "Category '$($CategoryName)' found after creation error - using existing category" "INFO"
            return $finalCheck
        }
        
        Write-Log "Failed to create or find category '$($CategoryName)'" "ERROR"
        return $null
    }
}
function Ensure-Tag {
    param([string]$TagName, [VMware.VimAutomation.ViCore.Types.V1.Tagging.TagCategory]$Category)
    
    Write-Log "Ensure-Tag: Checking for tag '$($TagName)' in category '$($Category.Name)'" "DEBUG"
    
    # First, try to get the tag in the specific category
    $existingTag = Get-Tag -Name $TagName -Category $Category -ErrorAction SilentlyContinue
    if ($existingTag) { 
        Write-Log "Ensure-Tag: Tag '$($TagName)' already exists in category '$($Category.Name)' - returning existing tag" "INFO"
        return $existingTag 
    }
    
    Write-Log "Tag '$($TagName)' not found in category '$($Category.Name)', creating..." "INFO"
    try {
        $newTag = New-Tag -Name $TagName -Category $Category -Description "Managed by script" -ErrorAction Stop
        Write-Log "Successfully created tag '$($TagName)' in category '$($Category.Name)'" "INFO"
        return $newTag
    }
    catch {
        # Handle parallel processing race conditions gracefully
        if ($_.Exception.Message -match "already.exists|AlreadyExists") {
            # This is expected in parallel processing - another thread created the tag
            Write-Log "Tag '$($TagName)' was created by another thread - checking for existing tag" "DEBUG"
            $existingTagAfterError = Get-Tag -Name $TagName -Category $Category -ErrorAction SilentlyContinue
            if ($existingTagAfterError) {
                Write-Log "Successfully found existing tag '$($TagName)' in category '$($Category.Name)'" "INFO"
                return $existingTagAfterError
            }
        } else {
            # This is an unexpected error - log as warning
            Write-Log "Unexpected tag creation error: $_" "WARN"
        }
        
        # Double-check one more time after any error
        $existingTagAfterError = Get-Tag -Name $TagName -Category $Category -ErrorAction SilentlyContinue
        if ($existingTagAfterError) {
            Write-Log "Tag '$($TagName)' found after creation error - using existing tag" "INFO"
            return $existingTagAfterError
        }
        
        # Check if tag exists in a different category (common issue)
        $tagInOtherCategory = Get-Tag -Name $TagName -ErrorAction SilentlyContinue | Where-Object { $_.Category.Name -ne $Category.Name }
        if ($tagInOtherCategory) {
            Write-Log "Tag '$($TagName)' exists in different category: '$($tagInOtherCategory.Category.Name)' - cannot create in '$($Category.Name)'" "ERROR"
        } else {
            Write-Log "Failed to create tag '$($TagName)' in category '$($Category.Name)': $_" "ERROR"
        }
        return $null
    }
}
function Clone-RoleFromSupportAdminTemplate {
    param([string]$NewRoleName)
    
    # Try multiple variations of the SupportAdmin template role name
    $templateRoleNames = @("SupportAdmin", "Support Admin", "Support Admin Template", "SupportAdminTemplate")
    $templateRole = $null
    
    foreach ($roleName in $templateRoleNames) {
        $templateRole = Get-VIRole -Name $roleName -ErrorAction SilentlyContinue
        if ($templateRole) {
            Write-Log "Found template role: '$($roleName)'" "DEBUG"
            break
        }
    }
    
    if (-not $templateRole) {
        Write-Log "Template role not found. Tried: $($templateRoleNames -join ', '). Cannot clone role '$($NewRoleName)'." "ERROR"
        return $null
    }
    
    try {
        Write-Log "Cloning role '$($NewRoleName)' from template '$($templateRole.Name)'..." "INFO"
        return New-VIRole -Name $NewRoleName -Privilege (Get-viPrivilege -Role $templateRole) -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to clone role '$($NewRoleName)' from template '$($templateRole.Name)': $_" "ERROR"
        return $null
    }
}
function Assign-PermissionIfNeeded {
    param(
        [psobject]$VM, 
        [string]$Principal, 
        [string]$RoleName
    )
    
    Write-Log "Checking permission: VM='$($VM.Name)', Principal='$($Principal)', Role='$($RoleName)'" "DEBUG"
    
    try {
        # Check if role exists, create if needed
        $roles = @(Get-VIRole -Name $RoleName -ErrorAction SilentlyContinue)

        if ($roles.Count -eq 0) {
            # Role doesn't exist, try to create it
            $role = Clone-RoleFromSupportAdminTemplate -NewRoleName $RoleName
            if (-not $role) {
                throw "Could not find or create role '$($RoleName)'."
            }
        } elseif ($roles.Count -eq 1) {
            # Exactly one role found - perfect
            $role = $roles[0]
        } else {
            # Multiple roles found - try to find exact match or use first one
            Write-Log "WARNING: Multiple roles found with name '$($RoleName)' ($($roles.Count) matches). Using first match." "WARN"
            $exactMatch = $roles | Where-Object { $_.Name -ceq $RoleName }
            if ($exactMatch) {
                $role = $exactMatch[0]  # Use first exact match if multiple exact matches
                Write-Log "Found exact case-sensitive match for role '$($RoleName)'" "DEBUG"
            } else {
                $role = $roles[0]  # Use first role if no exact match
                Write-Log "Using first role match: '$($role.Name)' for requested role '$($RoleName)'" "DEBUG"
            }
        }
        
        # Check for existing permissions - FIXED LOGIC
        $existingPermissions = Get-VIPermission -Entity $VM -ErrorAction SilentlyContinue
        
        # Look for exact match: same principal AND same role
        $duplicatePermission = $existingPermissions | Where-Object {
            $_.Principal -eq $Principal -and $_.Role -eq $RoleName
        }
        
        if ($duplicatePermission) {
            Write-Log "Permission already exists: VM='$($VM.Name)', Principal='$($Principal)', Role='$($RoleName)' - SKIPPING" "DEBUG"
            return @{
                Action = "Skipped"
                Reason = "Permission already exists"
                Principal = $Principal
                Role = $RoleName
                Propagate = $duplicatePermission.Propagate
            }
        }
        
        # Check for additional permissions (same principal, different role) - ALLOW MULTIPLE ROLES
        $additionalPermissions = $existingPermissions | Where-Object {
            $_.Principal -eq $Principal -and $_.Role -ne $RoleName
        }

        if ($additionalPermissions) {
            $existingRoles = ($additionalPermissions | ForEach-Object { $_.Role }) -join ', '
            Write-Log "INFO: Principal '$($Principal)' already has role(s) [$existingRoles] on VM='$($VM.Name)'. Adding additional role '$($RoleName)'" "INFO"
            # Continue with assignment - vCenter supports multiple roles for same principal
        }
        
        # Validate we have a single role object before assignment
        if (-not $role) {
            throw "Role object is null after lookup/creation for role '$($RoleName)'"
        }
        if ($role -is [array]) {
            throw "Role object is still an array after processing. This should not happen. Role count: $($role.Count)"
        }

        # Assign the new permission
        Write-Log "Assigning permission: VM='$($VM.Name)', Principal='$($Principal)', Role='$($role.Name)'" "INFO"
        $newPermission = New-VIPermission -Entity $VM -Principal $Principal -Role $role -Propagate:$false -ErrorAction Stop
        
        return @{
            Action = "Created"
            Principal = $Principal
            Role = $RoleName
            Propagate = $false
            PermissionObject = $newPermission
        }
    }
    catch {
        # Check if the error is due to inherited permissions from folder
        $errorMessage = $_.Exception.Message
        
        if ($errorMessage -match "already exists|inherited|propagate|folder" -or 
            $errorMessage -match "permission.*exists" -or
            $errorMessage -match "duplicate") {
            
            # Highlighted warning for inherited permission conflicts
            Write-Log "⚠️  INHERITED PERMISSION CONFLICT ⚠️" "WARN"
            Write-Log "    VM: '$($VM.Name)'" "WARN"
            Write-Log "    Principal: '$($Principal)'" "WARN"
            Write-Log "    Role: '$($RoleName)'" "WARN"
            Write-Log "    Reason: Permission likely inherited from folder level" "WARN"
            Write-Log "    Error: $($errorMessage)" "WARN"
            Write-Log "⚠️  ================================== ⚠️" "WARN"
            
            return @{
                Action = "Skipped"
                Reason = "Inherited from folder"
                Principal = $Principal
                Role = $RoleName
                Error = $errorMessage
                InheritedPermission = $true
            }
        } else {
            # Regular permission assignment failure
            Write-Log "Failed to assign permission for '$($Principal)' on VM '$($VM.Name)': $_" "ERROR"
            return @{
                Action = "Failed"
                Principal = $Principal
                Role = $RoleName
                Error = $errorMessage
                InheritedPermission = $false
            }
        }
    }
}

function Find-VMsWithoutExplicitPermissions {
    param(
        [array]$VMs,
        [string]$Environment
    )
    
    Write-Log "=== Analyzing VMs for Missing Explicit Permissions ===" "INFO"
    
    $vmsWithoutPermissions = @()
    $vmsWithOnlyInherited = @()
    $vmsWithExplicit = @()
    $totalChecked = 0
    
    foreach ($vm in $VMs) {
        $totalChecked++
        
        try {
            # Get all permissions for this VM
            $allPermissions = Get-VIPermission -Entity $vm -ErrorAction SilentlyContinue
            
            if (-not $allPermissions -or $allPermissions.Count -eq 0) {
                # No permissions at all (very unusual)
                $vmsWithoutPermissions += [PSCustomObject]@{
                    VMName = $vm.Name
                    PowerState = $vm.PowerState
                    GuestOS = $vm.Guest.OSFullName
                    ConfiguredOS = $vm.ExtensionData.Config.GuestFullName
                    Folder = $vm.Folder.Name
                    Issue = "No permissions found"
                    InheritedPermissions = 0
                    ExplicitPermissions = 0
                }
                Write-Log "VM '$($vm.Name)' has NO permissions (unusual)" "WARN"
                continue
            }
            
            # Separate inherited vs explicit permissions
            $inheritedPermissions = $allPermissions | Where-Object { $_.Propagate -eq $true }
            $explicitPermissions = $allPermissions | Where-Object { $_.Propagate -eq $false }
            
            if ($explicitPermissions.Count -eq 0) {
                # Only inherited permissions
                $vmsWithOnlyInherited += [PSCustomObject]@{
                    VMName = $vm.Name
                    PowerState = $vm.PowerState
                    GuestOS = $vm.Guest.OSFullName
                    ConfiguredOS = $vm.ExtensionData.Config.GuestFullName
                    Folder = $vm.Folder.Name
                    Issue = "Only inherited permissions"
                    InheritedPermissions = $inheritedPermissions.Count
                    ExplicitPermissions = 0
                    InheritedRoles = ($inheritedPermissions | ForEach-Object { "$($_.Principal):$($_.Role)" }) -join "; "
                }
                Write-Log "VM '$($vm.Name)' has only inherited permissions ($($inheritedPermissions.Count) inherited)" "WARN"
            }
            else {
                # Has explicit permissions
                $vmsWithExplicit += [PSCustomObject]@{
                    VMName = $vm.Name
                    PowerState = $vm.PowerState
                    InheritedPermissions = $inheritedPermissions.Count
                    ExplicitPermissions = $explicitPermissions.Count
                    ExplicitRoles = ($explicitPermissions | ForEach-Object { "$($_.Principal):$($_.Role)" }) -join "; "
                }
                Write-Log "VM '$($vm.Name)' has $($explicitPermissions.Count) explicit and $($inheritedPermissions.Count) inherited permissions" "DEBUG"
            }
        }
        catch {
            Write-Log "Error checking permissions for VM '$($vm.Name)': $_" "ERROR"
        }
        
        # Progress reporting
        if ($totalChecked % 50 -eq 0) {
            Write-Log "Permission analysis progress: $($totalChecked)/$($VMs.Count) VMs checked" "INFO"
        }
    }
    
    # Generate summary report
    Write-Log "=== Permission Analysis Summary ===" "INFO"
    Write-Log "Total VMs Analyzed: $($totalChecked)" "INFO"
    Write-Log "VMs with explicit permissions: $($vmsWithExplicit.Count)" "INFO"
    Write-Log "VMs with only inherited permissions: $($vmsWithOnlyInherited.Count)" "INFO"
    Write-Log "VMs with no permissions: $($vmsWithoutPermissions.Count)" "INFO"
    
    # Process OS tagging for VMs with only inherited permissions
    if ($vmsWithOnlyInherited.Count -gt 0) {
        Write-Log "=== Processing OS Tags for VMs with Only Inherited Permissions ===" "INFO"
        
        try {
            # Get OS mapping data
            $osMappingData = Import-Csv -Path $OsMappingCsvPath
            if (-not $osMappingData -or $osMappingData.Count -eq 0) {
                Write-Log "No OS mapping data found in $($OsMappingCsvPath) - skipping OS tag assignment for inherited VMs" "WARN"
            } else {
                $inheritedVMsOSTagged = 0
                $inheritedVMsOSSkipped = 0
                
                foreach ($vmRecord in $vmsWithOnlyInherited) {
                    try {
                        # Get the actual VM object
                        $vm = Get-VM -Name $vmRecord.VMName -ErrorAction SilentlyContinue
                        if (-not $vm) {
                            Write-Log "VM '$($vmRecord.VMName)' not found - skipping OS tag assignment" "WARN"
                            $inheritedVMsOSSkipped++
                            continue
                        }
                        
                        # Get OS information for this VM
                        $osInfo = Get-VMOSInformation -VM $vm
                        $osToCheck = @($osInfo.Guest, $osInfo.Config) | Where-Object { $_.OSName -and $_.OSName -ne "Unknown" -and $_.OSName -ne "" }
                        
                        if ($osToCheck.Count -eq 0) {
                            Write-Log "No valid OS information found for VM '$($vm.Name)' - skipping OS tag assignment" "WARN"
                            $inheritedVMsOSSkipped++
                            continue
                        }
                        
                        $vmMatched = $false
                        
                        # Try each OS source against the mapping patterns
                        foreach ($osSource in $osToCheck) {
                            if ($vmMatched) { break }
                            
                            foreach ($osMapRow in $osMappingData) {
                                try {
                                    if ($osSource.OSName -match $osMapRow.GuestOSPattern) {
                                        Write-Log "Inherited VM '$($vm.Name)' matches OS pattern '$($osMapRow.GuestOSPattern)' using $($osSource.Source): '$($osSource.OSName)'" "INFO"
                                        
                                        $targetTagName = $osMapRow.TargetTagName
                                        $osTagObj = Get-Tag -Category $osCat -Name $targetTagName -ErrorAction SilentlyContinue
                                        if (-not $osTagObj) { 
                                            Write-Log "Target OS tag '$($targetTagName)' not found in category '$($osCat.Name)' - skipping" "ERROR"
                                            break
                                        }
                                        
                                        # Check if VM already has this OS tag
                                        $existingOSTags = Get-TagAssignment -Entity $vm -Category $osCat -ErrorAction SilentlyContinue
                                        if ($existingOSTags | Where-Object { $_.Tag.Name -eq $targetTagName }) {
                                            Write-Log "Inherited VM '$($vm.Name)' already has OS tag '$($targetTagName)' - skipping" "DEBUG"
                                        } else {
                                            # Assign the OS tag
                                            New-TagAssignment -Tag $osTagObj -Entity $vm -ErrorAction Stop
                                            Write-Log "Assigned OS tag '$($targetTagName)' to inherited VM '$($vm.Name)'" "INFO"
                                            $inheritedVMsOSTagged++
                                        }
                                        
                                        $vmMatched = $true
                                        break
                                    }
                                }
                                catch {
                                    Write-Log "Error processing OS pattern '$($osMapRow.GuestOSPattern)' for inherited VM '$($vm.Name)': $_" "ERROR"
                                }
                            }
                        }
                        
                        if (-not $vmMatched) {
                            $osNames = ($osToCheck | ForEach-Object { "$($_.Source): '$($_.OSName)'" }) -join "; "
                            Write-Log "Inherited VM '$($vm.Name)' did not match any OS patterns. Available OS info: $($osNames)" "WARN"
                            $inheritedVMsOSSkipped++
                        }
                    }
                    catch {
                        Write-Log "Error processing inherited VM '$($vmRecord.VMName)' for OS tagging: $_" "ERROR"
                        $inheritedVMsOSSkipped++
                    }
                }
                
                Write-Log "OS tag processing for inherited VMs completed: $($inheritedVMsOSTagged) tagged, $($inheritedVMsOSSkipped) skipped" "INFO"
            }
        }
        catch {
            Write-Log "Error during OS tag processing for inherited VMs: $_" "ERROR"
        }
    }
    
    # Save detailed reports - FIXED FILE NAMING
    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        
        if ($vmsWithOnlyInherited.Count -gt 0) {
            $inheritedOnlyReport = Join-Path $script:reportsFolder "VMsWithOnlyInheritedPermissions_$($Environment)_$timestamp.csv"
            $vmsWithOnlyInherited | Export-Csv -Path $inheritedOnlyReport -NoTypeInformation
            Write-Log "VMs with only inherited permissions saved to: $($inheritedOnlyReport)" "INFO"
        }
        
        if ($vmsWithoutPermissions.Count -gt 0) {
            $noPermissionsReport = Join-Path $script:reportsFolder "VMsWithNoPermissions_$($Environment)_$timestamp.csv"
            $vmsWithoutPermissions | Export-Csv -Path $noPermissionsReport -NoTypeInformation
            Write-Log "VMs with no permissions saved to: $($noPermissionsReport)" "INFO"
        }
        
        if ($vmsWithExplicit.Count -gt 0) {
            $explicitPermissionsReport = Join-Path $script:reportsFolder "VMsWithExplicitPermissions_$($Environment)_$timestamp.csv"
            $vmsWithExplicit | Export-Csv -Path $explicitPermissionsReport -NoTypeInformation
            Write-Log "VMs with explicit permissions saved to: $($explicitPermissionsReport)" "INFO"
        }
    }
    catch {
        Write-Log "Failed to save permission analysis reports: $_" "ERROR"
    }
    
    return @{
        WithoutPermissions = $vmsWithoutPermissions
        OnlyInherited = $vmsWithOnlyInherited
        WithExplicit = $vmsWithExplicit
        TotalChecked = $totalChecked
    }
}

function Grant-InventoryVisibility {
    <#
    .SYNOPSIS
        Grants Read-Only permissions on inventory containers to allow users to navigate vCenter structure
    .DESCRIPTION
        This function grants non-propagating Read-Only permissions on datacenters, clusters, folders,
        and resource pools to security groups that have VM permissions. This allows users to see and
        navigate the inventory structure without having actual permissions on all objects.
    .PARAMETER SecurityGroups
        Array of security group principals (domain\groupname format) to grant visibility to
    .PARAMETER SkipDatacenters
        Skip granting permissions on datacenters (if they already have visibility)
    #>
    param(
        [string[]]$SecurityGroups,
        [switch]$SkipDatacenters
    )

    Write-Log "=== Granting Inventory Visibility ===" "INFO"
    Write-Log "Security groups to process: $($SecurityGroups.Count)" "INFO"

    $results = @{
        DatacenterPermissions = 0
        ClusterPermissions = 0
        FolderPermissions = 0
        ResourcePoolPermissions = 0
        Skipped = 0
        Errors = 0
    }

    try {
        # Get Read-Only role (this is a built-in vCenter role)
        $readOnlyRole = Get-VIRole -Name "ReadOnly" -ErrorAction Stop

        if (-not $readOnlyRole) {
            Write-Log "Read-Only role not found in vCenter. Skipping inventory visibility grants." "WARN"
            return $results
        }

        # Process each security group
        foreach ($securityGroup in $SecurityGroups) {
            Write-Log "Processing inventory visibility for: $securityGroup" "INFO"

            try {
                # Grant on Datacenters (unless skipped)
                if (-not $SkipDatacenters) {
                    $datacenters = Get-Datacenter -ErrorAction SilentlyContinue
                    foreach ($datacenter in $datacenters) {
                        try {
                            $existingPerm = Get-VIPermission -Entity $datacenter -Principal $securityGroup -ErrorAction SilentlyContinue
                            if (-not $existingPerm) {
                                New-VIPermission -Entity $datacenter -Principal $securityGroup -Role $readOnlyRole -Propagate:$false -ErrorAction Stop | Out-Null
                                Write-Log "Granted Read-Only on Datacenter '$($datacenter.Name)' to $securityGroup" "DEBUG"
                                $results.DatacenterPermissions++
                            } else {
                                $results.Skipped++
                            }
                        }
                        catch {
                            Write-Log "Failed to grant visibility on Datacenter '$($datacenter.Name)' to $securityGroup`: $_" "WARN"
                            $results.Errors++
                        }
                    }
                }

                # Grant on Clusters
                $clusters = Get-Cluster -ErrorAction SilentlyContinue
                foreach ($cluster in $clusters) {
                    try {
                        $existingPerm = Get-VIPermission -Entity $cluster -Principal $securityGroup -ErrorAction SilentlyContinue
                        if (-not $existingPerm) {
                            New-VIPermission -Entity $cluster -Principal $securityGroup -Role $readOnlyRole -Propagate:$false -ErrorAction Stop | Out-Null
                            Write-Log "Granted Read-Only on Cluster '$($cluster.Name)' to $securityGroup" "DEBUG"
                            $results.ClusterPermissions++
                        } else {
                            $results.Skipped++
                        }
                    }
                    catch {
                        Write-Log "Failed to grant visibility on Cluster '$($cluster.Name)' to $securityGroup`: $_" "WARN"
                        $results.Errors++
                    }
                }

                # Grant on VM Folders (non-blue folders)
                $folders = Get-Folder -Type VM -ErrorAction SilentlyContinue
                foreach ($folder in $folders) {
                    try {
                        $existingPerm = Get-VIPermission -Entity $folder -Principal $securityGroup -ErrorAction SilentlyContinue
                        if (-not $existingPerm) {
                            New-VIPermission -Entity $folder -Principal $securityGroup -Role $readOnlyRole -Propagate:$false -ErrorAction Stop | Out-Null
                            Write-Log "Granted Read-Only on Folder '$($folder.Name)' to $securityGroup" "DEBUG"
                            $results.FolderPermissions++
                        } else {
                            $results.Skipped++
                        }
                    }
                    catch {
                        Write-Log "Failed to grant visibility on Folder '$($folder.Name)' to $securityGroup`: $_" "WARN"
                        $results.Errors++
                    }
                }

                # Grant on Resource Pools
                $resourcePools = Get-ResourcePool -ErrorAction SilentlyContinue
                foreach ($resourcePool in $resourcePools) {
                    try {
                        $existingPerm = Get-VIPermission -Entity $resourcePool -Principal $securityGroup -ErrorAction SilentlyContinue
                        if (-not $existingPerm) {
                            New-VIPermission -Entity $resourcePool -Principal $securityGroup -Role $readOnlyRole -Propagate:$false -ErrorAction Stop | Out-Null
                            Write-Log "Granted Read-Only on Resource Pool '$($resourcePool.Name)' to $securityGroup" "DEBUG"
                            $results.ResourcePoolPermissions++
                        } else {
                            $results.Skipped++
                        }
                    }
                    catch {
                        Write-Log "Failed to grant visibility on Resource Pool '$($resourcePool.Name)' to $securityGroup`: $_" "WARN"
                        $results.Errors++
                    }
                }
            }
            catch {
                Write-Log "Error processing inventory visibility for $securityGroup`: $_" "ERROR"
                $results.Errors++
            }
        }

        Write-Log "Inventory Visibility Summary:" "INFO"
        Write-Log "  Datacenter Permissions: $($results.DatacenterPermissions)" "INFO"
        Write-Log "  Cluster Permissions: $($results.ClusterPermissions)" "INFO"
        Write-Log "  Folder Permissions: $($results.FolderPermissions)" "INFO"
        Write-Log "  Resource Pool Permissions: $($results.ResourcePoolPermissions)" "INFO"
        Write-Log "  Skipped (already exist): $($results.Skipped)" "INFO"
        Write-Log "  Errors: $($results.Errors)" "INFO"
    }
    catch {
        Write-Log "Critical error in Grant-InventoryVisibility: $_" "ERROR"
        $results.Errors++
    }

    return $results
}

function Assign-ContainerPermission {
    <#
    .SYNOPSIS
        Assigns permissions on a container (folder or resource pool) for a security group
    .DESCRIPTION
        This function assigns the specified role to a security group on a container object.
        This ensures that when tags are assigned to containers, the permissions are also
        assigned on the container itself, not just on child VMs.
    .PARAMETER Container
        The container object (folder or resource pool)
    .PARAMETER Principal
        The security group principal (domain\groupname format)
    .PARAMETER RoleName
        The name of the role to assign
    .PARAMETER Propagate
        Whether to propagate permissions to children (default: $false)
    #>
    param(
        [psobject]$Container,
        [string]$Principal,
        [string]$RoleName,
        [bool]$Propagate = $false
    )

    Write-Log "Checking container permission: Container='$($Container.Name)', Principal='$($Principal)', Role='$($RoleName)'" "DEBUG"

    try {
        # Check if role exists
        $role = Get-VIRole -Name $RoleName -ErrorAction SilentlyContinue

        if (-not $role) {
            # Try to create role if it doesn't exist
            $role = Clone-RoleFromSupportAdminTemplate -NewRoleName $RoleName
            if (-not $role) {
                Write-Log "Could not find or create role '$($RoleName)' for container '$($Container.Name)'" "WARN"
                return @{
                    Action = "Failed"
                    Reason = "Role not found"
                    Principal = $Principal
                    Role = $RoleName
                }
            }
        }

        # Check for existing permission
        $existingPermission = Get-VIPermission -Entity $Container -ErrorAction SilentlyContinue | Where-Object {
            $_.Principal -eq $Principal -and $_.Role -eq $RoleName
        }

        if ($existingPermission) {
            Write-Log "Permission already exists on container '$($Container.Name)' for '$($Principal)' with role '$($RoleName)' - SKIPPING" "DEBUG"
            return @{
                Action = "Skipped"
                Reason = "Permission already exists"
                Principal = $Principal
                Role = $RoleName
            }
        }

        # Assign the permission
        Write-Log "Assigning permission on container '$($Container.Name)': Principal='$($Principal)', Role='$($RoleName)', Propagate=$($Propagate)" "INFO"
        $newPermission = New-VIPermission -Entity $Container -Principal $Principal -Role $role -Propagate:$Propagate -ErrorAction Stop

        return @{
            Action = "Created"
            Principal = $Principal
            Role = $RoleName
            Propagate = $Propagate
            PermissionObject = $newPermission
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Log "Failed to assign permission on container '$($Container.Name)' for '$($Principal)': $errorMessage" "ERROR"
        return @{
            Action = "Failed"
            Principal = $Principal
            Role = $RoleName
            Error = $errorMessage
        }
    }
}

function Track-PermissionAssignment {
    param($Result, $VM, $Source)

    if (-not $script:PermissionResults) {
        $script:PermissionResults = @()
    }

    $script:PermissionResults += [PSCustomObject]@{
        VMName = $VM.Name
        PowerState = $VM.PowerState
        Source = $Source  # "AppPermissions" or "OSMapping"
        Action = $Result.Action
        Principal = $Result.Principal
        Role = $Result.Role
        Reason = $Result.Reason
        Error = $Result.Error
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}
#endregion

#region I) MAIN EXECUTION
# Initialize tracking variables
$script:PermissionResults = @()
$script:ExecutionSummary = @{
    TagsCreated = 0
    TagsAssigned = 0
    PermissionsAssigned = 0
    PermissionsSkipped = 0
    PermissionsFailed = 0
    VMsProcessed = 0
    VMsSkipped = 0
    ErrorsEncountered = 0
    FolderBasedPermissions = @{
        FoldersProcessed = 0
        ResourcePoolsProcessed = 0
        FolderTagsFound = 0
        ResourcePoolTagsFound = 0
        VMPermissionsApplied = 0
        Errors = 0
    }
}

try {
    # --- Pre-flight Checks and Connections ---
    Write-Log "Starting preflight checks..." "INFO"
    
    if (-not $EnvironmentCategoryConfig.ContainsKey($Environment)) {
        throw "Environment '$($Environment)' is not defined in EnvironmentCategoryConfig."
    }
    
    $config = $EnvironmentCategoryConfig[$Environment]
    $AppCategoryName = $config.App
    $FunctionCategoryName = $config.Function
    $OsCategoryName = $config.OS
    
    Write-Log "Environment set to '$($Environment)'. Using categories: App='$($AppCategoryName)', OS='$($OsCategoryName)'" "INFO"
    
    # Determine the current SSO Domain from the environment map
    if (-not $EnvironmentDomainMap.ContainsKey($Environment)) {
        throw "SSO Domain for environment '$($Environment)' is not defined in EnvironmentDomainMap."
    }
    
    $currentSsoDomain = $EnvironmentDomainMap[$Environment]
    Write-Log "Using SSO domain '$($currentSsoDomain)' for OS permission assignments in this environment." "INFO"
    
    # Test network connectivity
    Write-Log "Testing connectivity to vCenter '$($vCenterServer)'..." "INFO"
    if (-not (Test-NetConnection $vCenterServer -Port 443 -InformationLevel Quiet -ErrorAction SilentlyContinue)) {
        throw "Cannot reach vCenter '$($vCenterServer)' on port 443."
    }
    Write-Log "Network connectivity confirmed." "INFO"
    
    # Disconnect any existing vCenter sessions
    if ($global:DefaultVIServers.Count -gt 0) {
        Write-Log "Disconnecting existing vCenter sessions..." "INFO"
        Disconnect-VIServer -Server * -Confirm:$false -Force -ErrorAction SilentlyContinue
    }
    
    # Connect to vCenter
    Write-Log "Connecting to vCenter '$($vCenterServer)'..." "INFO"
    Write-Log "Setting PowerCLI certificate policy to 'Ignore' for vCenter connectivity" "DEBUG"
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    $vc = Connect-VIServer -Server $vCenterServer -Credential $Credential -ErrorAction Stop
    Write-Log "Connected to vCenter $($vc.Name) (v$($vc.Version))." "INFO"
    
    # Connect to SSO if available
    if (Test-SsoModuleAvailable) {
        Connect-SsoAdmin -Server $vCenterServer -Credential $Credential
    } else {
        Write-Log "SSO Admin module not available. Group existence checks will be skipped." "WARN"
    }
    
    # --- Data Import and Validation ---
    Write-Log "Importing and validating CSV data..." "INFO"
    
    # Load CSV data using network share functionality if available
    $appPermissionData = @()
    $osMappingData = @()

    # Try to load configuration file to check for network share settings
    $useNetworkShare = $false
    $networkShareConfig = $null

    # Try multiple paths to find the configuration file
    $possibleConfigPaths = @(
        (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) "..\ConfigFiles\VMTagsConfig.psd1"),
        (Join-Path $PSScriptRoot "..\ConfigFiles\VMTagsConfig.psd1"),
        ".\ConfigFiles\VMTagsConfig.psd1",
        (Join-Path (Get-Location) "ConfigFiles\VMTagsConfig.psd1")
    )

    $configPath = $null
    foreach ($testPath in $possibleConfigPaths) {
        if (Test-Path $testPath) {
            $configPath = $testPath
            Write-Log "Found configuration file at: $($configPath)" "INFO"
            break
        }
    }

    if ($configPath -and (Test-Path $configPath)) {
        try {
            Write-Log "Loading network share configuration from: $($configPath)" "INFO"
            $config = Import-PowerShellDataFile -Path $configPath

            if ($config.Environments -and $config.Environments.$Environment) {
                Write-Log "Environment '$($Environment)' found in configuration" "INFO"
                $envDataPaths = $config.Environments.$Environment.DataPaths

                if ($envDataPaths.EnableNetworkShare -eq $true) {
                    $useNetworkShare = $true
                    $networkShareConfig = $envDataPaths
                    Write-Log "Network share enabled for environment: $($Environment)" "INFO"
                    Write-Log "Network share path: $($envDataPaths.NetworkSharePath)" "INFO"
                } else {
                    Write-Log "Network share disabled for environment: $($Environment) (EnableNetworkShare = $($envDataPaths.EnableNetworkShare))" "INFO"
                }
            } else {
                Write-Log "Environment '$($Environment)' not found in configuration file" "WARN"
                Write-Log "Available environments: $($config.Environments.Keys -join ', ')" "INFO"
            }
        }
        catch {
            Write-Log "Failed to load network share configuration: $($_.Exception.Message)" "WARN"
            Write-Log "Stack trace: $($_.ScriptStackTrace)" "WARN"
        }
    } else {
        Write-Log "Configuration file not found in any of the expected locations" "WARN"
        Write-Log "Searched paths: $($possibleConfigPaths -join '; ')" "INFO"
    }

    # Load App Permissions CSV
    if ($useNetworkShare -and $networkShareConfig) {
        try {
            # Load network share script
            $networkShareScriptPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "Get-NetworkShareCSV.ps1"
            if (Test-Path $networkShareScriptPath) {
                # Don't dot-source, we'll call it directly

                # Try to use existing vCenter credentials first (most common scenario)
                $shareCredential = $null
                $useVCenterCredentials = if ($networkShareConfig.UseVCenterCredentials -ne $null) { $networkShareConfig.UseVCenterCredentials } else { $true }

                if ($Credential -and $useVCenterCredentials) {
                    Write-Log "Using vCenter service account credentials for network share access" "INFO"
                    $shareCredential = $Credential
                }
                elseif (-not $useVCenterCredentials) {
                    Write-Log "UseVCenterCredentials is disabled - will use dedicated network share credentials" "INFO"
                }
                # Check Windows Credential Manager for dedicated network share credentials
                if (-not $shareCredential -and $networkShareConfig.NetworkShareCredentialName) {
                    try {
                        # Load credential manager script
                        $credScriptPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "Get-StoredCredential.ps1"
                        if (Test-Path $credScriptPath) {
                            $shareCredential = & $credScriptPath -Target $networkShareConfig.NetworkShareCredentialName -ErrorAction SilentlyContinue
                            if ($shareCredential) {
                                Write-Log "Retrieved dedicated network share credentials from credential manager" "INFO"
                            }
                        }
                    }
                    catch {
                        Write-Log "Could not retrieve network share credentials: $($_.Exception.Message)" "WARN"
                    }
                }

                # If no credentials available, test access and potentially prompt
                if (-not $shareCredential) {
                    Write-Log "No credentials available for network share access - testing anonymous access" "INFO"

                    # Check if we can access the share without credentials first
                    try {
                        $testAccess = Test-Path $networkShareConfig.NetworkSharePath -ErrorAction Stop
                        if ($testAccess) {
                            Write-Log "Network share accessible without credentials" "INFO"
                        } else {
                            Write-Log "Network share requires authentication" "INFO"

                            # Prompt for credentials interactively
                            Write-Host "Network share credentials required for: $($networkShareConfig.NetworkSharePath)" -ForegroundColor Yellow
                            $shareCredential = Get-Credential -Message "Enter credentials for network share access" -UserName "$env:USERDOMAIN\$env:USERNAME"

                            if ($shareCredential) {
                                Write-Log "Interactive credentials provided for network share" "INFO"
                            } else {
                                Write-Log "No credentials provided - will attempt without authentication" "WARN"
                            }
                        }
                    }
                    catch {
                        Write-Log "Cannot test network share access: $($_.Exception.Message)" "WARN"
                        Write-Log "Prompting for credentials as fallback" "INFO"

                        # Prompt for credentials as fallback
                        Write-Host "Network share credentials required for: $($networkShareConfig.NetworkSharePath)" -ForegroundColor Yellow
                        $shareCredential = Get-Credential -Message "Enter credentials for network share access" -UserName "$env:USERDOMAIN\$env:USERNAME"
                    }
                }

                # Get App Permissions CSV from network share
                $appPermFileName = Split-Path $AppPermissionsCsvPath -Leaf
                $localFallbackPath = Split-Path $AppPermissionsCsvPath -Parent

                # Debug parameter values
                Write-Log "Network share parameters:" "DEBUG"
                Write-Log "  NetworkPath: '$($networkShareConfig.NetworkSharePath)'" "DEBUG"
                Write-Log "  LocalFallbackPath: '$($localFallbackPath)'" "DEBUG"
                Write-Log "  FileName: '$($appPermFileName)'" "DEBUG"
                Write-Log "  EnableCaching: '$($networkShareConfig.CacheNetworkFiles)'" "DEBUG"
                Write-Log "  CacheExpiryHours: '$($networkShareConfig.CacheExpiryHours)'" "DEBUG"

                # Validate required parameters
                if ([string]::IsNullOrWhiteSpace($networkShareConfig.NetworkSharePath)) {
                    throw "NetworkSharePath is null or empty: '$($networkShareConfig.NetworkSharePath)'"
                }
                if ([string]::IsNullOrWhiteSpace($localFallbackPath)) {
                    throw "LocalFallbackPath is null or empty: '$localFallbackPath'"
                }
                if ([string]::IsNullOrWhiteSpace($appPermFileName)) {
                    throw "App Permissions CSV filename is null or empty: '$appPermFileName'"
                }

                # Set default values for optional parameters if needed
                $enableCaching = if ($networkShareConfig.CacheNetworkFiles -ne $null) { $networkShareConfig.CacheNetworkFiles } else { $true }
                $cacheExpiryHours = if ($networkShareConfig.CacheExpiryHours -ne $null) { $networkShareConfig.CacheExpiryHours } else { 4 }

                Write-Log "Calling network share script directly with parameters" "DEBUG"

                # Build parameters hashtable for splatting
                $scriptParams = @{
                    NetworkPath = $networkShareConfig.NetworkSharePath
                    LocalFallbackPath = $localFallbackPath
                    FileName = $appPermFileName
                    EnableCaching = $enableCaching
                    CacheExpiryHours = $cacheExpiryHours
                }

                # Add network share mapping if configured
                if ($networkShareConfig.NetworkShareMapping) {
                    $scriptParams.NetworkShareMapping = $networkShareConfig.NetworkShareMapping
                    Write-Log "Using network share file mapping for environment $Environment" "DEBUG"
                }

                # Add credential if available
                if ($shareCredential) {
                    $scriptParams.Credential = $shareCredential
                }

                Write-Log "Script parameters: $($scriptParams.Keys -join ', ')" "DEBUG"

                # Call the script directly with parameter splatting
                $appResult = & $networkShareScriptPath @scriptParams

                if ($appResult.Success) {
                    $appPermissionData = $appResult.Data
                    Write-Log "Loaded App Permissions CSV from $($appResult.Source): $($appResult.RowCount) rows" "INFO"
                } else {
                    throw "Failed to load App Permissions CSV from network share: $($appResult.Error)"
                }
            } else {
                throw "Network share script not found: $($networkShareScriptPath)"
            }
        }
        catch {
            Write-Log "Network share loading failed, falling back to local file: $($_.Exception.Message)" "WARN"
            $useNetworkShare = $false
        }
    }

    # Fallback to local file loading for App Permissions CSV
    if (-not $useNetworkShare -or $appPermissionData.Count -eq 0) {
        if (-not (Test-Path $AppPermissionsCsvPath)) {
            throw "Application Permissions CSV not found: $($AppPermissionsCsvPath)"
        }
        $appPermissionData = Import-Csv -Path $AppPermissionsCsvPath
        Write-Log "Loaded App Permissions CSV from local file: $($appPermissionData.Count) rows" "INFO"
    }

    # Load OS Mapping CSV
    if ($useNetworkShare -and $networkShareConfig) {
        try {
            # Get OS Mapping CSV from network share
            $osMappingFileName = Split-Path $OsMappingCsvPath -Leaf
            $osLocalFallbackPath = Split-Path $OsMappingCsvPath -Parent

            # Debug parameter values for OS Mapping
            Write-Log "OS Mapping network share parameters:" "DEBUG"
            Write-Log "  NetworkPath: '$($networkShareConfig.NetworkSharePath)'" "DEBUG"
            Write-Log "  LocalFallbackPath: '$($osLocalFallbackPath)'" "DEBUG"
            Write-Log "  FileName: '$($osMappingFileName)'" "DEBUG"

            # Validate required parameters
            if ([string]::IsNullOrWhiteSpace($networkShareConfig.NetworkSharePath)) {
                throw "NetworkSharePath is null or empty for OS Mapping: '$($networkShareConfig.NetworkSharePath)'"
            }
            if ([string]::IsNullOrWhiteSpace($osLocalFallbackPath)) {
                throw "LocalFallbackPath is null or empty for OS Mapping: '$osLocalFallbackPath'"
            }
            if ([string]::IsNullOrWhiteSpace($osMappingFileName)) {
                throw "OS Mapping CSV filename is null or empty: '$osMappingFileName'"
            }

            # Set default values for optional parameters if needed
            $osEnableCaching = if ($networkShareConfig.CacheNetworkFiles -ne $null) { $networkShareConfig.CacheNetworkFiles } else { $true }
            $osCacheExpiryHours = if ($networkShareConfig.CacheExpiryHours -ne $null) { $networkShareConfig.CacheExpiryHours } else { 4 }

            Write-Log "Calling network share script for OS Mapping with validated parameters" "DEBUG"

            # Build parameters hashtable for OS Mapping
            $osScriptParams = @{
                NetworkPath = $networkShareConfig.NetworkSharePath
                LocalFallbackPath = $osLocalFallbackPath
                FileName = $osMappingFileName
                EnableCaching = $osEnableCaching
                CacheExpiryHours = $osCacheExpiryHours
            }

            # Add network share mapping if configured
            if ($networkShareConfig.NetworkShareMapping) {
                $osScriptParams.NetworkShareMapping = $networkShareConfig.NetworkShareMapping
                Write-Log "Using network share file mapping for OS Mapping in environment $Environment" "DEBUG"
            }

            # Add credential if available
            if ($shareCredential) {
                $osScriptParams.Credential = $shareCredential
            }

            Write-Log "OS Mapping script parameters: $($osScriptParams.Keys -join ', ')" "DEBUG"

            # Call the script directly with parameter splatting
            $osResult = & $networkShareScriptPath @osScriptParams

            if ($osResult.Success) {
                $osMappingData = $osResult.Data
                Write-Log "Loaded OS Mapping CSV from $($osResult.Source): $($osResult.RowCount) rows" "INFO"
            } else {
                throw "Failed to load OS Mapping CSV from network share: $($osResult.Error)"
            }
        }
        catch {
            Write-Log "Network share loading failed for OS Mapping, falling back to local file: $($_.Exception.Message)" "WARN"
        }
    }

    # Fallback to local file loading for OS Mapping CSV
    if (-not $useNetworkShare -or $osMappingData.Count -eq 0) {
        if (-not (Test-Path $OsMappingCsvPath)) {
            throw "OS Mapping CSV not found: $OsMappingCsvPath"
        }
        $osMappingData = Import-Csv -Path $OsMappingCsvPath
        Write-Log "Loaded OS Mapping CSV from local file: $($osMappingData.Count) rows" "INFO"
    }
    
    Write-Log "Imported $($appPermissionData.Count) rows from App Permissions CSV." "INFO"
    Write-Log "Imported $($osMappingData.Count) rows from OS Mapping CSV." "INFO"
    
    # Validate CSV data
    $requiredAppColumns = @('TagCategory', 'TagName', 'RoleName', 'SecurityGroupDomain', 'SecurityGroupName')
    $requiredOsColumns = @('GuestOSPattern', 'TargetTagName', 'RoleName', 'SecurityGroupDomain', 'SecurityGroupName')
    
    $appColumns = ($appPermissionData | Get-Member -MemberType NoteProperty).Name
    $osColumns = ($osMappingData | Get-Member -MemberType NoteProperty).Name
    
    foreach ($column in $requiredAppColumns) {
        if ($column -notin $appColumns) {
            throw "Required column '$column' missing from App Permissions CSV"
        }
    }
    
    foreach ($column in $requiredOsColumns) {
        if ($column -notin $osColumns) {
            throw "Required column '$column' missing from OS Mapping CSV"
        }
    }
    
    Write-Log "CSV data validation completed successfully." "INFO"
    
    # --- Ensure Tag Categories Exist ---
    Write-Log "Ensuring tag categories exist..." "INFO"
    
    $appCat = Ensure-TagCategory -CategoryName $AppCategoryName
    $osCat = Ensure-TagCategory -CategoryName $OsCategoryName
    
    # For Function category - use existing instead of creating
    $functionCat = Get-TagCategory -Name $FunctionCategoryName -ErrorAction SilentlyContinue
    if (-not $functionCat) {
        Write-Log "Function category '$($FunctionCategoryName)' not found - this is expected as we reference existing Function tags" "INFO"
    } else {
        Write-Log "Using existing Function category '$($FunctionCategoryName)' for domain controller references" "INFO"
    }
    
    if (-not $appCat) { 
        throw "FATAL: Could not create App category '$($AppCategoryName)'." 
    }
    if (-not $osCat) { 
        throw "FATAL: Could not create OS category '$($OsCategoryName)'." 
    }
    
    Write-Log "Tag categories verified/created successfully." "INFO"

    # --- Hierarchical Tag Inheritance (Optional) ---
    if ($EnableHierarchicalInheritance) {
        Write-Log "Hierarchical tag inheritance is ENABLED" "INFO"

        # Determine which categories to inherit
        $categoriesToInherit = @()
        if ([string]::IsNullOrWhiteSpace($InheritanceCategories)) {
            # Default: inherit only App category tags
            $categoriesToInherit = @($AppCategoryName)
            Write-Log "Using default inheritance categories: App tags only" "INFO"
        } else {
            # Parse comma-separated list
            $categoriesToInherit = $InheritanceCategories.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            Write-Log "Using custom inheritance categories: $($categoriesToInherit -join ', ')" "INFO"
        }

        # Process hierarchical inheritance
        try {
            $inheritanceResult = Process-HierarchicalTagInheritance -TagCategories $categoriesToInherit -DryRun:$InheritanceDryRun

            # Update execution summary with inheritance statistics
            $script:ExecutionSummary.HierarchicalInheritance = @{
                Enabled = $true
                VMsProcessed = $inheritanceResult.VMsProcessed
                TagsInherited = $inheritanceResult.TagsInherited
                TagsSkipped = $inheritanceResult.TagsSkipped
                Errors = $inheritanceResult.Errors
                Categories = $categoriesToInherit
                DryRun = $InheritanceDryRun.IsPresent
            }

            Write-Log "Hierarchical tag inheritance completed successfully" "INFO"
        }
        catch {
            Write-Log "Error during hierarchical tag inheritance: $_" "ERROR"
            $script:ExecutionSummary.ErrorsEncountered++
        }
    } else {
        Write-Log "Hierarchical tag inheritance is DISABLED" "INFO"
        $script:ExecutionSummary.HierarchicalInheritance = @{
            Enabled = $false
        }
    }

    # --- Processing Part 1A: Folder-Based Permission Propagation ---
    Write-Log "=== Processing Folder-Based Permission Propagation ===" "INFO"
    $folderPermissionsResult = Process-FolderBasedPermissions -AppPermissionData $appPermissionData -AppCategoryName $AppCategoryName
    $script:ExecutionSummary.FolderBasedPermissions = $folderPermissionsResult

    # --- Processing Part 1B: Direct VM Application Permissions ---
    Write-Log "=== Processing Direct VM Application Permissions from $($AppPermissionsCsvPath) ===" "INFO"
    Write-Log "Expected App Category Name: '$($AppCategoryName)'" "INFO"
    Write-Log "Total App Permission Rows to Process: $($appPermissionData.Count)" "INFO"
    
    $appRowsProcessed = 0
    $appTagsCreated = 0
    $appPermissionsProcessed = 0
    
    foreach ($row in $appPermissionData) {
        $appRowsProcessed++
        Write-Log "Processing App Row #$($appRowsProcessed): Category='$($row.TagCategory)', Tag='$($row.TagName)'" "DEBUG"
        
        if ($row.TagCategory -ieq $AppCategoryName) {
            Write-Log "Processing App row: Tag='$($row.TagName)', Role='$($row.RoleName)'" "DEBUG"
            
            try {
                # Ensure the tag exists
                Write-Log "Attempting to ensure tag '$($row.TagName)' exists in category '$($appCat.Name)'" "DEBUG"
                $tagObj = Ensure-Tag -TagName $row.TagName -Category $appCat
                
                if (-not $tagObj) { 
                    Write-Log "Failed to create/find tag '$($row.TagName)' in category '$($appCat.Name)' - skipping row" "ERROR"
                    $script:ExecutionSummary.ErrorsEncountered++
                    continue 
                } else {
                    Write-Log "Successfully obtained tag '$($row.TagName)' in category '$($appCat.Name)'" "DEBUG"
                }
                
                if ($tagObj.Name -eq $row.TagName -and -not (Get-Tag -Name $row.TagName -Category $appCat -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $row.TagName })) {
                    $appTagsCreated++
                    $script:ExecutionSummary.TagsCreated++
                }
                
                # Build principal name
                $principal = "$($row.SecurityGroupDomain)\$($row.SecurityGroupName)"
                
                # Validate security group exists (if SSO is connected)
                if (-not (Test-SsoGroupExistsSimple -Domain $row.SecurityGroupDomain -GroupName $row.SecurityGroupName)) {
                    Write-Log "Skipping permissions for principal '$($principal)' as SSO group was not found." "WARN"
                    continue
                }
                
                # Find VMs with this tag
                $vms = Get-VM -Tag $tagObj -ErrorAction SilentlyContinue | Where-Object Name -notmatch '^(vCLS|VLC|stCtlVM)'
                Write-Log "Found $($vms.Count) VMs with tag '$($row.TagName)'" "DEBUG"
                
                if ($vms.Count -eq 0) { 
                    Write-Log "No VMs found with tag '$($row.TagName)'" "DEBUG"
                    continue 
                }
                
                # Assign permissions to each VM
                foreach ($vm in $vms) {
                    $script:ExecutionSummary.VMsProcessed++
                    $result = Assign-PermissionIfNeeded -VM $vm -Principal $principal -RoleName $row.RoleName
                    Track-PermissionAssignment -Result $result -VM $vm -Source "AppPermissions"
                    
                    switch ($result.Action) {
                        "Created" { 
                            $appPermissionsProcessed++
                            $script:ExecutionSummary.PermissionsAssigned++
                        }
                        "Skipped" { 
                            $script:ExecutionSummary.PermissionsSkipped++
                        }
                        "Failed" { 
                            $script:ExecutionSummary.PermissionsFailed++
                            $script:ExecutionSummary.ErrorsEncountered++
                        }
                    }
                }
            } 
            catch {
                Write-Log "Error processing App row for tag '$($row.TagName)': $_" "ERROR"
                $script:ExecutionSummary.ErrorsEncountered++
            }
        }
        else {
            Write-Log "Skipping App row with non-matching category: '$($row.TagCategory)' (expected: '$($AppCategoryName)')" "INFO"
        }
        
        # Progress reporting
        if ($appRowsProcessed % 10 -eq 0) {
            Write-Log "App permissions progress: $($appRowsProcessed)/$($appPermissionData.Count) rows processed" "INFO"
        }
    }
    
    Write-Log "App Permissions Summary: $($appRowsProcessed) rows processed, $($appTagsCreated) tags created, $($appPermissionsProcessed) permissions assigned" "INFO"
    
    # --- Processing Part 2: OS Tagging and Permissions ---
    Write-Log "=== Processing OS Tagging and Permissions from $($OsMappingCsvPath) ===" "INFO"
    
    # Pre-create all OS tags from mapping file
    Write-Log "Pre-creating all OS tags from mapping file..." "DEBUG"
    $osTagsCreated = 0
    
    foreach ($osMapRow in $osMappingData) {
        $osTagObj = Ensure-Tag -TagName $osMapRow.TargetTagName -Category $osCat
        if ($osTagObj -and -not (Get-Tag -Name $osMapRow.TargetTagName -Category $osCat -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $osMapRow.TargetTagName })) {
            $osTagsCreated++
            $script:ExecutionSummary.TagsCreated++
        }
    }
    
    Write-Log "Pre-created $($osTagsCreated) OS tags" "INFO"
    
    # Get VMs for processing - handle single VM mode for vSphere Client integration
    if ($SpecificVM) {
        Write-Log "vSphere Client Mode: Processing specific VM '$($SpecificVM)'" "INFO"
        $allVms = Get-VM -Name $SpecificVM -ErrorAction SilentlyContinue

        if (-not $allVms) {
            throw "VM '$SpecificVM' not found. Please verify the VM name is correct."
        }

        if ($allVms -is [array]) {
            $allVms = $allVms[0]  # Take first match if multiple VMs found
            Write-Log "Multiple VMs found with name '$SpecificVM'. Using first match: $($allVms.Name)" "WARN"
        }

        $allVms = @($allVms)  # Ensure it's an array for consistent processing
        Write-Log "Single VM mode: Will process VM '$($allVms[0].Name)'" "INFO"
    }
    else {
        # Standard mode: Get all VMs excluding system and control VMs
        Write-Log "Getting all VMs for OS processing (excluding vCLS*, VLC*, stCtlVM* VMs)..." "DEBUG"
        $allVms = Get-VM | Where-Object Name -notmatch '^(vCLS|VLC|stCtlVM)'
        Write-Log "Found $($allVms.Count) VMs to check for OS patterns (after filtering system VMs)." "INFO"
    }

    # Enhanced Linked Mode deduplication: Create a tracking file for processed VMs across vCenter connections
    $processedVMsFile = Join-Path $script:logFolder "ProcessedVMs_$($Environment)_$(Get-Date -Format 'yyyyMMdd').json"
    $processedVMs = @{}

    # Load existing processed VMs if file exists (for multi-vCenter scenarios)
    if (Test-Path $processedVMsFile) {
        try {
            $existingData = Get-Content $processedVMsFile -Raw | ConvertFrom-Json
            if ($existingData -and $existingData.PSObject.Properties) {
                foreach ($property in $existingData.PSObject.Properties) {
                    $processedVMs[$property.Name] = $property.Value
                }
            }
            Write-Log "Loaded $($processedVMs.Count) previously processed VMs from deduplication file" "DEBUG"
        }
        catch {
            Write-Log "Could not load VM deduplication file, starting fresh: $($_.Exception.Message)" "DEBUG"
            $processedVMs = @{}
        }
    }

    # Filter out VMs that have already been processed by this environment today (unless ForceReprocess is enabled)
    $originalCount = $allVms.Count
    if (-not $ForceReprocess) {
        $allVms = $allVms | Where-Object {
            $vmKey = "$($_.Name)|$($_.Id)"  # Use Name and Id for uniqueness
            if ($processedVMs.ContainsKey($vmKey)) {
                Write-Log "Skipping VM '$($_.Name)' - already processed by vCenter '$($processedVMs[$vmKey])'" "DEBUG"
                return $false
            }
            return $true
        }

        if ($originalCount -ne $allVms.Count) {
            Write-Log "Filtered out $($originalCount - $allVms.Count) already-processed VMs. Processing $($allVms.Count) remaining VMs." "INFO"
        }
    } else {
        Write-Log "ForceReprocess enabled - processing all $($allVms.Count) VMs regardless of previous processing status" "INFO"
    }
    
    $osProcessedCount = 0
    $osSkippedCount = 0
    $osTaggedCount = 0
    $osPermissionCount = 0
    
    foreach ($vm in $allVms) {
        $osProcessedCount++
        
        # Try multiple sources for OS information
        $osToCheck = @()
        
        # 1. First try Guest OS (from VMware Tools - only available when VM is running)
        if (-not [string]::IsNullOrWhiteSpace($vm.Guest.OSFullName)) {
            $osToCheck += @{
                Source = "Guest OS (VMware Tools)"
                OSName = $vm.Guest.OSFullName
            }
            Write-Log "VM '$($vm.Name)' - Guest OS from Tools: '$($vm.Guest.OSFullName)'" "DEBUG"
        }
        
        # 2. Fallback to configured Guest OS (from VM settings - always available)
        if (-not [string]::IsNullOrWhiteSpace($vm.ExtensionData.Config.GuestFullName)) {
            $osToCheck += @{
                Source = "VM Configuration"
                OSName = $vm.ExtensionData.Config.GuestFullName
            }
            Write-Log "VM '$($vm.Name)' - Configured Guest OS: '$($vm.ExtensionData.Config.GuestFullName)'" "DEBUG"
        }
        
        # 3. Last resort - use Guest ID
        if (-not [string]::IsNullOrWhiteSpace($vm.ExtensionData.Config.GuestId)) {
            $osToCheck += @{
                Source = "Guest ID"
                OSName = $vm.ExtensionData.Config.GuestId
            }
            Write-Log "VM '$($vm.Name)' - Guest ID: '$($vm.ExtensionData.Config.GuestId)'" "DEBUG"
        }
        
        # If no OS information available at all
        if ($osToCheck.Count -eq 0) {
            Write-Log "VM '$($vm.Name)' - No OS information available (PowerState: $($vm.PowerState))" "WARN"
            $osSkippedCount++
            $script:ExecutionSummary.VMsSkipped++
            continue
        }
        
        $vmMatched = $false
        
        # Try each OS source against the mapping patterns
        foreach ($osInfo in $osToCheck) {
            if ($vmMatched) { break }
            
            foreach ($osMapRow in $osMappingData) {
                try {
                    if ($osInfo.OSName -match $osMapRow.GuestOSPattern) {
                        Write-Log "VM '$($vm.Name)' matches OS pattern '$($osMapRow.GuestOSPattern)' using $($osInfo.Source): '$($osInfo.OSName)'" "INFO"
                        
                        $targetTagName = $osMapRow.TargetTagName
                        $osTagObj = Get-Tag -Category $osCat -Name $targetTagName -ErrorAction SilentlyContinue
                        if (-not $osTagObj) { 
                            Write-Log "Target tag '$($targetTagName)' not found in category '$($osCat.Name)'" "ERROR"
                            $script:ExecutionSummary.ErrorsEncountered++
                            break 
                        }
                        
                        # Apply OS Tag
                        Write-Log "Checking if VM '$($vm.Name)' already has OS tag '$($targetTagName)'" "DEBUG"
                        $existingTag = Get-TagAssignment -Entity $vm -Tag $osTagObj -ErrorAction SilentlyContinue
                        if (-not $existingTag) {
                            Write-Log "VM '$($vm.Name)' does not have OS tag '$($targetTagName)' - applying tag now" "INFO"
                            try { 
                                New-TagAssignment -Entity $vm -Tag $osTagObj -ErrorAction Stop 
                                $osTaggedCount++
                                $script:ExecutionSummary.TagsAssigned++
                                Write-Log "Successfully applied OS tag '$($targetTagName)' to VM '$($vm.Name)'" "INFO"
                            }
                            catch { 
                                Write-Log "Failed to apply OS tag '$($targetTagName)' to VM '$($vm.Name)': $_" "ERROR" 
                                $script:ExecutionSummary.ErrorsEncountered++
                            }
                        } else {
                            Write-Log "VM '$($vm.Name)' already has OS tag '$($targetTagName)' - skipping" "INFO"
                        }
                        
                        # Apply Permissions - check for Domain Controller special case
                        $osPrincipal = "$($currentSsoDomain)\$($osMapRow.SecurityGroupName)"
                        $roleToAssign = $osMapRow.RoleName

                        Write-Log "DEBUG: About to process OS permissions for VM '$($vm.Name)'" "DEBUG"
                        Write-Log "DEBUG: OS Principal: '$osPrincipal'" "DEBUG"
                        Write-Log "DEBUG: Role to Assign: '$roleToAssign'" "DEBUG"
                        Write-Log "DEBUG: OS Map Row: SecurityGroupName='$($osMapRow.SecurityGroupName)', RoleName='$($osMapRow.RoleName)'" "DEBUG"

                        # Check if this is a Domain Controller for Windows OS admin permissions override
                        if ($osMapRow.SecurityGroupName -eq "Windows Server Team") {
                            try {
                                # Check for Domain Controller function tag
                                $functionTags = Get-TagAssignment -Entity $vm -Category $functionCat -ErrorAction SilentlyContinue
                                $isDomainController = $functionTags | Where-Object { $_.Tag.Name -eq "Domain Controller" }
                                
                                if ($isDomainController) {
                                    $roleToAssign = "ReadOnly"
                                    Write-Log "VM '$($vm.Name)' is a Domain Controller - overriding Windows Server Team permissions with ReadOnly role" "INFO"
                                } else {
                                    Write-Log "VM '$($vm.Name)' is a Windows Server (not Domain Controller) - applying full Windows Server Team permissions" "DEBUG"
                                }
                            }
                            catch {
                                Write-Log "Error checking Domain Controller function tag for VM '$($vm.Name)': $_" "WARN"
                                # Continue with original role if function tag check fails
                            }
                        }
                        
                        Write-Log "Processing permissions for VM '$($vm.Name)': Principal='$($osPrincipal)', Role='$($roleToAssign)'" "DEBUG"

                        $result = Assign-PermissionIfNeeded -VM $vm -Principal $osPrincipal -RoleName $roleToAssign
                        Track-PermissionAssignment -Result $result -VM $vm -Source "OSMapping"

                        Write-Log "DEBUG: Permission assignment result for VM '$($vm.Name)': Action='$($result.Action)', Reason='$($result.Reason)'" "DEBUG"

                        switch ($result.Action) {
                            "Created" {
                                $osPermissionCount++
                                $script:ExecutionSummary.PermissionsAssigned++
                                Write-Log "SUCCESS: Created OS permission for VM '$($vm.Name)': '$osPrincipal' -> '$roleToAssign'" "INFO"
                            }
                            "Skipped" {
                                $script:ExecutionSummary.PermissionsSkipped++
                                Write-Log "SKIPPED: OS permission for VM '$($vm.Name)': '$osPrincipal' -> '$roleToAssign' (Reason: $($result.Reason))" "INFO"
                            }
                            "Failed" { 
                                $script:ExecutionSummary.PermissionsFailed++
                                $script:ExecutionSummary.ErrorsEncountered++
                            }
                        }
                        
                        $vmMatched = $true
                        break # Match found, move to the next VM
                    }
                }
                catch {
                    Write-Log "Error processing OS pattern '$($osMapRow.GuestOSPattern)' for VM '$($vm.Name)': $_" "ERROR"
                    $script:ExecutionSummary.ErrorsEncountered++
                }
            }
        }
        
        if (-not $vmMatched) {
            $osNames = ($osToCheck | ForEach-Object { "$($_.Source): '$($_.OSName)'" }) -join "; "
            Write-Log "VM '$($vm.Name)' did not match any OS patterns. Available OS info: $($osNames)" "WARN"
            $osSkippedCount++
            $script:ExecutionSummary.VMsSkipped++
        }
        
        # Progress reporting
        if ($osProcessedCount % 25 -eq 0) {
            Write-Log "OS processing progress: $($osProcessedCount)/$($allVms.Count) VMs (Tagged: $($osTaggedCount), Permissions: $($osPermissionCount), Skipped: $($osSkippedCount))" "INFO"
        }

        # Track processed VM for deduplication across vCenter connections
        $vmKey = "$($vm.Name)|$($vm.Id)"
        $processedVMs[$vmKey] = $vCenterServer
    }

    # Save processed VMs to deduplication file for multi-vCenter scenarios
    if ($processedVMs.Count -gt 0) {
        try {
            $processedVMs | ConvertTo-Json | Set-Content $processedVMsFile -Force
            Write-Log "Saved $($processedVMs.Count) processed VMs to deduplication file for multi-vCenter tracking" "DEBUG"
        }
        catch {
            Write-Log "Could not save VM deduplication file: $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "OS Processing Complete - Total VMs: $($allVms.Count), Processed: $($osProcessedCount), Tagged: $($osTaggedCount), Permissions Assigned: $($osPermissionCount), Skipped: $($osSkippedCount)" "INFO"
    
    # --- Permission Analysis ---
    Write-Log "=== Starting Comprehensive Permission Analysis ===" "INFO"
    $permissionAnalysis = Find-VMsWithoutExplicitPermissions -VMs $allVms -Environment $Environment
    
    # --- Process OS Tags for VMs with Only Inherited Permissions ---
    if ($permissionAnalysis.OnlyInherited.Count -gt 0) {
        Write-Log "=== Processing OS Tags for VMs with Only Inherited Permissions ===" "INFO"
        Write-Log "Found $($permissionAnalysis.OnlyInherited.Count) VMs with only inherited permissions - applying OS tags..." "INFO"
        
        $inheritedVMsOSTagged = 0
        $inheritedVMsOSSkipped = 0
        
        foreach ($vmRecord in $permissionAnalysis.OnlyInherited) {
            try {
                # Get the VM object
                $vm = Get-VM -Name $vmRecord.VMName -ErrorAction SilentlyContinue
                if (-not $vm) {
                    Write-Log "Could not find VM '$($vmRecord.VMName)' for OS tag processing" "WARN"
                    $inheritedVMsOSSkipped++
                    continue
                }
                
                # Try multiple sources for OS information (same logic as main OS processing)
                $osToCheck = @()
                
                # 1. First try Guest OS (from VMware Tools - only available when VM is running)
                if (-not [string]::IsNullOrWhiteSpace($vm.Guest.OSFullName)) {
                    $osToCheck += @{
                        Source = "Guest OS (VMware Tools)"
                        OSName = $vm.Guest.OSFullName
                    }
                    Write-Log "VM '$($vm.Name)' - Guest OS from Tools: '$($vm.Guest.OSFullName)'" "DEBUG"
                }
                
                # 2. Fallback to configured Guest OS (from VM settings - always available)
                if (-not [string]::IsNullOrWhiteSpace($vm.ExtensionData.Config.GuestFullName)) {
                    $osToCheck += @{
                        Source = "VM Configuration"
                        OSName = $vm.ExtensionData.Config.GuestFullName
                    }
                    Write-Log "VM '$($vm.Name)' - Configured Guest OS: '$($vm.ExtensionData.Config.GuestFullName)'" "DEBUG"
                }
                
                # 3. Last resort - use Guest ID
                if (-not [string]::IsNullOrWhiteSpace($vm.ExtensionData.Config.GuestId)) {
                    $osToCheck += @{
                        Source = "Guest ID"
                        OSName = $vm.ExtensionData.Config.GuestId
                    }
                    Write-Log "VM '$($vm.Name)' - Guest ID: '$($vm.ExtensionData.Config.GuestId)'" "DEBUG"
                }
                
                # If no OS information available
                if ($osToCheck.Count -eq 0) {
                    Write-Log "VM '$($vm.Name)' - No OS information available for inherited VM (PowerState: $($vm.PowerState))" "WARN"
                    $inheritedVMsOSSkipped++
                    continue
                }
                
                $vmMatched = $false
                
                # Try each OS source against the mapping patterns
                foreach ($osInfo in $osToCheck) {
                    if ($vmMatched) { break }
                    
                    foreach ($osMapRow in $osMappingData) {
                        try {
                            if ($osInfo.OSName -match $osMapRow.GuestOSPattern) {
                                Write-Log "Inherited VM '$($vm.Name)' matches OS pattern '$($osMapRow.GuestOSPattern)' using $($osInfo.Source): '$($osInfo.OSName)'" "INFO"
                                
                                $targetTagName = $osMapRow.TargetTagName
                                $osTagObj = Get-Tag -Category $osCat -Name $targetTagName -ErrorAction SilentlyContinue
                                if (-not $osTagObj) { 
                                    Write-Log "Target tag '$($targetTagName)' not found in category '$($osCat.Name)' for inherited VM processing" "ERROR"
                                    break 
                                }
                                
                                # Apply OS Tag only (no permissions since they only have inherited)
                                $existingTag = Get-TagAssignment -Entity $vm -Tag $osTagObj -ErrorAction SilentlyContinue
                                if (-not $existingTag) {
                                    Write-Log "Applying OS tag '$($targetTagName)' to inherited VM '$($vm.Name)'" "INFO"
                                    try { 
                                        New-TagAssignment -Entity $vm -Tag $osTagObj -ErrorAction Stop 
                                        $inheritedVMsOSTagged++
                                        $script:ExecutionSummary.TagsAssigned++
                                    }
                                    catch { 
                                        Write-Log "Failed to apply OS tag '$($targetTagName)' to inherited VM '$($vm.Name)': $_" "ERROR" 
                                        $script:ExecutionSummary.ErrorsEncountered++
                                    }
                                } else {
                                    Write-Log "Inherited VM '$($vm.Name)' already has OS tag '$($targetTagName)'" "DEBUG"
                                }
                                
                                $vmMatched = $true
                                break # Match found, move to next VM
                            }
                        }
                        catch {
                            Write-Log "Error processing OS pattern '$($osMapRow.GuestOSPattern)' for inherited VM '$($vm.Name)': $_" "ERROR"
                            $script:ExecutionSummary.ErrorsEncountered++
                        }
                    }
                }
                
                if (-not $vmMatched) {
                    $osNames = ($osToCheck | ForEach-Object { "$($_.Source): '$($_.OSName)'" }) -join "; "
                    Write-Log "Inherited VM '$($vm.Name)' did not match any OS patterns. Available OS info: $($osNames)" "WARN"
                    $inheritedVMsOSSkipped++
                }
            }
            catch {
                Write-Log "Error processing inherited VM '$($vmRecord.VMName)' for OS tagging: $_" "ERROR"
                $inheritedVMsOSSkipped++
                $script:ExecutionSummary.ErrorsEncountered++
            }
        }
        
        Write-Log "OS tag processing for inherited VMs completed: $($inheritedVMsOSTagged) tagged, $($inheritedVMsOSSkipped) skipped" "INFO"
    }

    # --- Grant Inventory Visibility (Optional) ---
    if ($EnableInventoryVisibility) {
        Write-Log "=== Granting Inventory Visibility to Security Groups ===" "INFO"

        try {
            # Collect all unique security groups from both App Permissions and OS Mappings
            $allSecurityGroups = @()

            # From App Permissions CSV
            $appSecurityGroups = $appPermissionData | ForEach-Object {
                "$($_.SecurityGroupDomain)\$($_.SecurityGroupName)"
            } | Select-Object -Unique

            # From OS Mappings CSV
            $osSecurityGroups = $osMappingData | ForEach-Object {
                "$($_.SecurityGroupDomain)\$($_.SecurityGroupName)"
            } | Select-Object -Unique

            # Combine and deduplicate
            $allSecurityGroups = ($appSecurityGroups + $osSecurityGroups) | Select-Object -Unique

            Write-Log "Found $($allSecurityGroups.Count) unique security groups to grant inventory visibility" "INFO"

            # Grant inventory visibility
            $visibilityResult = Grant-InventoryVisibility -SecurityGroups $allSecurityGroups

            # Track results
            $script:ExecutionSummary.InventoryVisibility = $visibilityResult

            Write-Log "Inventory visibility grants completed" "INFO"
        }
        catch {
            Write-Log "Error granting inventory visibility: $_" "ERROR"
            $script:ExecutionSummary.ErrorsEncountered++
        }
    } else {
        Write-Log "Inventory visibility feature is DISABLED (use -EnableInventoryVisibility to enable)" "INFO"
        $script:ExecutionSummary.InventoryVisibility = @{
            Enabled = $false
        }
    }

    # --- Generate Final Reports and Summary ---
    Write-Log "=== Generating Final Reports and Summary ===" "INFO"
    
    # Calculate final statistics
    $totalPermissionsAssigned = ($script:PermissionResults | Where-Object { $_.Action -eq "Created" }).Count
    $totalPermissionsSkipped = ($script:PermissionResults | Where-Object { $_.Action -eq "Skipped" }).Count
    $totalPermissionsFailed = ($script:PermissionResults | Where-Object { $_.Action -eq "Failed" }).Count
    
    # Generate comprehensive execution summary
    Write-Log "=== FINAL EXECUTION SUMMARY ===" "INFO"
    Write-Log "Environment: $($Environment)" "INFO"
    Write-Log "vCenter Server: $($vCenterServer)" "INFO"
    Write-Log "Execution Start Time: $(Get-Date)" "INFO"
    Write-Log "=== CSV Data Processing ===" "INFO"
    Write-Log "App Permission Rows: $($appPermissionData.Count)" "INFO"
    Write-Log "OS Mapping Rows: $($osMappingData.Count)" "INFO"
    Write-Log "=== Tag Management ===" "INFO"
    Write-Log "Tags Created: $($script:ExecutionSummary.TagsCreated)" "INFO"
    Write-Log "Tag Assignments: $($script:ExecutionSummary.TagsAssigned)" "INFO"
    Write-Log "=== VM Processing ===" "INFO"
    Write-Log "Total VMs Found: $($allVms.Count)" "INFO"
    Write-Log "VMs Successfully Processed: $($script:ExecutionSummary.VMsProcessed)" "INFO"
    Write-Log "VMs Skipped: $($script:ExecutionSummary.VMsSkipped)" "INFO"
    Write-Log "=== Permission Assignment Results ===" "INFO"
    Write-Log "Permissions Successfully Assigned: $($totalPermissionsAssigned)" "INFO"
    Write-Log "Permissions Skipped (duplicates/conflicts): $($totalPermissionsSkipped)" "INFO"
    Write-Log "Permission Assignment Failures: $($totalPermissionsFailed)" "INFO"

    # Multi-Role Assignment Analysis
    $multiRoleAssignments = $script:PermissionResults | Group-Object VMName, Principal |
        Where-Object { $_.Count -gt 1 -and ($_.Group | Where-Object { $_.Action -eq "Created" }).Count -gt 1 }

    if ($multiRoleAssignments.Count -gt 0) {
        Write-Log "=== Multi-Role Assignment Analysis ===" "INFO"
        Write-Log "VMs with Multi-Role Assignments: $($multiRoleAssignments.Count)" "INFO"

        foreach ($assignment in $multiRoleAssignments | Select-Object -First 10) {
            $vmName = $assignment.Group[0].VMName
            $principal = $assignment.Group[0].Principal
            $roles = ($assignment.Group | Where-Object { $_.Action -eq "Created" } | ForEach-Object { $_.Role }) -join ', '
            Write-Log "  VM: '$($vmName)', Principal: '$($principal)', Roles: [$roles]" "INFO"
        }

        if ($multiRoleAssignments.Count -gt 10) {
            Write-Log "  ... and $($multiRoleAssignments.Count - 10) more multi-role assignments" "INFO"
        }
    }
    Write-Log "=== Folder and Resource Pool Based Permission Propagation Results ===" "INFO"
    Write-Log "Folders Processed: $($script:ExecutionSummary.FolderBasedPermissions.FoldersProcessed)" "INFO"
    Write-Log "Folder Tags Found: $($script:ExecutionSummary.FolderBasedPermissions.FolderTagsFound)" "INFO"
    Write-Log "Resource Pools Processed: $($script:ExecutionSummary.FolderBasedPermissions.ResourcePoolsProcessed)" "INFO"
    Write-Log "Resource Pool Tags Found: $($script:ExecutionSummary.FolderBasedPermissions.ResourcePoolTagsFound)" "INFO"
    Write-Log "VM Permissions Applied from Containers: $($script:ExecutionSummary.FolderBasedPermissions.VMPermissionsApplied)" "INFO"
    Write-Log "Container Processing Errors: $($script:ExecutionSummary.FolderBasedPermissions.Errors)" "INFO"
    Write-Log "=== Permission Analysis Results ===" "INFO"
    Write-Log "VMs with Explicit Permissions: $($permissionAnalysis.WithExplicit.Count)" "INFO"
    Write-Log "VMs with Only Inherited Permissions: $($permissionAnalysis.OnlyInherited.Count)" "INFO"
    Write-Log "VMs with No Permissions: $($permissionAnalysis.WithoutPermissions.Count)" "INFO"

    # Inventory Visibility Summary
    if ($EnableInventoryVisibility -and $script:ExecutionSummary.InventoryVisibility) {
        Write-Log "=== Inventory Visibility Results ===" "INFO"
        Write-Log "Datacenter Read-Only Permissions: $($script:ExecutionSummary.InventoryVisibility.DatacenterPermissions)" "INFO"
        Write-Log "Cluster Read-Only Permissions: $($script:ExecutionSummary.InventoryVisibility.ClusterPermissions)" "INFO"
        Write-Log "Folder Read-Only Permissions: $($script:ExecutionSummary.InventoryVisibility.FolderPermissions)" "INFO"
        Write-Log "Resource Pool Read-Only Permissions: $($script:ExecutionSummary.InventoryVisibility.ResourcePoolPermissions)" "INFO"
        Write-Log "Visibility Grants Skipped (already exist): $($script:ExecutionSummary.InventoryVisibility.Skipped)" "INFO"
        Write-Log "Visibility Grant Errors: $($script:ExecutionSummary.InventoryVisibility.Errors)" "INFO"
    }

    Write-Log "=== Error Summary ===" "INFO"
    Write-Log "Total Errors Encountered: $($script:ExecutionSummary.ErrorsEncountered)" "INFO"
    
    # Determine overall execution status
    $executionStatus = if ($script:ExecutionSummary.ErrorsEncountered -eq 0) {
        "SUCCESS"
    } elseif ($totalPermissionsAssigned -gt 0) {
        "PARTIAL SUCCESS"
    } else {
        "FAILED"
    }
    
    Write-Log "=== OVERALL STATUS: $($executionStatus) ===" "INFO"
    
   # --- Save Detailed Reports ---
Write-Log "=== Saving Detailed Reports ===" "INFO"

try {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    # Save permission assignment results
    if ($script:PermissionResults.Count -gt 0) {
        $permissionResultsReport = Join-Path $script:reportsFolder "PermissionAssignmentResults_$($Environment)_$timestamp.csv"
        $script:PermissionResults | Export-Csv -Path $permissionResultsReport -NoTypeInformation
        Write-Log "Permission assignment results saved to: $($permissionResultsReport)" "INFO"
    }
    
    # Save execution summary
    $summaryReport = Join-Path $script:reportsFolder "ExecutionSummary_$($Environment)_$timestamp.csv"
    $summaryData = [PSCustomObject]@{
        Environment = $Environment
        vCenterServer = $vCenterServer
        ExecutionTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        AppPermissionRows = $appPermissionData.Count
        OSMappingRows = $osMappingData.Count
        TagsCreated = $script:ExecutionSummary.TagsCreated
        TagsAssigned = $script:ExecutionSummary.TagsAssigned
        TotalVMs = $allVms.Count
        VMsProcessed = $script:ExecutionSummary.VMsProcessed
        VMsSkipped = $script:ExecutionSummary.VMsSkipped
        PermissionsAssigned = $totalPermissionsAssigned
        PermissionsSkipped = $totalPermissionsSkipped
        PermissionsFailed = $totalPermissionsFailed
        VMsWithExplicitPermissions = $permissionAnalysis.WithExplicit.Count
        VMsWithOnlyInheritedPermissions = $permissionAnalysis.OnlyInherited.Count
        VMsWithNoPermissions = $permissionAnalysis.WithoutPermissions.Count
        ErrorsEncountered = $script:ExecutionSummary.ErrorsEncountered
        ExecutionStatus = $executionStatus
    }
    
    $summaryData | Export-Csv -Path $summaryReport -NoTypeInformation
    Write-Log "Execution summary saved to: $($summaryReport)" "INFO"
    
    # Save VMs that need attention (only inherited permissions or no permissions)
    $vmsNeedingAttention = @()
    $vmsNeedingAttention += $permissionAnalysis.OnlyInherited | ForEach-Object { 
        $_ | Add-Member -NotePropertyName "AttentionReason" -NotePropertyValue "Only Inherited Permissions" -PassThru
    }
    $vmsNeedingAttention += $permissionAnalysis.WithoutPermissions | ForEach-Object { 
        $_ | Add-Member -NotePropertyName "AttentionReason" -NotePropertyValue "No Permissions" -PassThru
    }
    
    if ($vmsNeedingAttention.Count -gt 0) {
        $attentionReport = Join-Path $script:reportsFolder "VMsNeedingAttention_$($Environment)_$timestamp.csv"
        $vmsNeedingAttention | Export-Csv -Path $attentionReport -NoTypeInformation
        Write-Log "VMs needing attention saved to: $($attentionReport)" "INFO"
        Write-Log "ATTENTION: $($vmsNeedingAttention.Count) VMs require manual review for permissions" "WARN"
    }
    
    Write-Log "All reports saved successfully to: $($script:reportsFolder)" "INFO"
}
catch {
    Write-Log "Failed to save some reports: $_" "ERROR"
    $script:ExecutionSummary.ErrorsEncountered++
}
    
    # Final status message
    if ($executionStatus -eq "SUCCESS") {
        Write-Log "Script execution completed successfully with no errors." "INFO"
    } elseif ($executionStatus -eq "PARTIAL SUCCESS") {
        Write-Log "Script execution completed with some errors, but permissions were assigned." "WARN"
    } else {
        Write-Log "Script execution completed with significant errors." "ERROR"
    }
}
catch {
    Write-Log "FATAL SCRIPT ERROR: $_" "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" "ERROR"
    $script:ExecutionSummary.ErrorsEncountered++
    throw
}
finally {
    # --- Cleanup ---
    Write-Log "=== Starting Cleanup ===" "INFO"
    
    # Save complete execution log
    Save-ExecutionLog
    
    # Disconnect from SSO
    if ($script:ssoConnected) {
        try { 
            Disconnect-SsoAdminServer -Server $vCenterServer -ErrorAction Stop
            Write-Log "SSO disconnected." "INFO" 
        }
        catch { 
            Write-Log "SSO disconnect failed: $_" "WARN" 
        }
    }
    
    # Disconnect from vCenter
    if ($global:DefaultVIServers.Count -gt 0) {
        try { 
            Disconnect-VIServer -Server * -Confirm:$false -Force -ErrorAction Stop
            Write-Log "vCenter disconnected." "INFO" 
        }
        catch { 
            Write-Log "vCenter disconnect failed: $_" "WARN" 
        }
    }
    
    # PowerCLI certificate policy left as 'Ignore' for continued use
    Write-Log "PowerCLI certificate policy maintained as 'Ignore' for subsequent operations." "INFO"
    
    Write-Log "Script execution finished." "INFO"
    Write-Log "Log files saved to: $($script:logFolder)" "INFO"
    Write-Log "Report files saved to: $($script:reportsFolder)" "INFO"
    
    # Display quick summary to console
    Write-Host "`n=== QUICK SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Permissions Assigned: $($totalPermissionsAssigned)" -ForegroundColor Green
    Write-Host "Permissions Skipped: $($totalPermissionsSkipped)" -ForegroundColor Yellow
    Write-Host "Permission Failures: $($totalPermissionsFailed)" -ForegroundColor Red
    Write-Host "Container-Based Permissions: $($script:ExecutionSummary.FolderBasedPermissions.VMPermissionsApplied)" -ForegroundColor Cyan
    Write-Host "Folders with Tags: $($script:ExecutionSummary.FolderBasedPermissions.FolderTagsFound)" -ForegroundColor Cyan
    Write-Host "Resource Pools with Tags: $($script:ExecutionSummary.FolderBasedPermissions.ResourcePoolTagsFound)" -ForegroundColor Cyan
    Write-Host "VMs Needing Attention: $($vmsNeedingAttention.Count)" -ForegroundColor Yellow
    Write-Host "Check logs for detailed results: $($script:logFolder)" -ForegroundColor White
    Write-Host "Check reports for CSV exports: $($script:reportsFolder)" -ForegroundColor White
    # Determine status color
    $statusColor = switch ($executionStatus) {
        "SUCCESS" { "Green" }
        "PARTIAL SUCCESS" { "Yellow" }
        default { "Red" }
    }
    Write-Host "Overall Status: $($executionStatus)" -ForegroundColor $statusColor
}
#endregion