<#
.SYNOPSIS
    [VERSION 2.0] Automates vCenter VM tags and permissions with parallel processing for improved performance.
.DESCRIPTION
    This script provides a powerful and repeatable way to manage vCenter VM tags and permissions.
    It connects to a specified vCenter Server and reads its configuration from two distinct CSV files:
    1.  App Permissions CSV: Contains mappings for application-specific tags to specific roles and security groups.
    2.  OS Mapping CSV: Defines how to tag VMs based on their Guest OS name. It maps OS patterns (e.g., "Microsoft Windows Server.*")
       to a target OS tag, a role, and an administrative security group.
    
    VERSION 2.0 ENHANCEMENTS:
    - Parallel processing of VM operations using PowerShell runspaces for significant performance improvements
    - Batch processing capabilities to handle large VM inventories efficiently
    - Enhanced progress tracking with real-time performance metrics
    - Optimized PowerCLI operations for concurrent execution
    - Thread-safe logging and error handling
    
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
.EXAMPLE
    # Execute for the PROD environment using separate CSV files.
    $cred = Get-Credential
    .\Set-vCenterObjects_Tag_Assigments.ps1 -vCenterServer 'vcsa01.corp.local' -Credential $cred `
        -AppPermissionsCsvPath 'C:\vCenter\App-Permissions.csv' `
        -OsMappingCsvPath 'C:\vCenter\OS-Mappings.csv' `
        -Environment 'PROD' -EnableScriptDebug
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
    
    [Parameter(Mandatory = $false, HelpMessage = "Enable parallel processing of VM operations")]
    [switch]$EnableParallelProcessing,
    
    [Parameter(Mandatory = $false, HelpMessage = "Batch processing strategy (RoundRobin, PowerStateBalanced, ComplexityBalanced)")]
    [ValidateSet('RoundRobin', 'PowerStateBalanced', 'ComplexityBalanced')]
    [string]$BatchStrategy = 'RoundRobin',
    
    [Parameter(Mandatory = $false, HelpMessage = "Enable real-time progress tracking")]
    [switch]$EnableProgressTracking,
    
    [Parameter(Mandatory = $false, HelpMessage = "Enable robust error handling with retry logic")]
    [switch]$EnableErrorHandling,
    
    [Parameter(Mandatory = $false, HelpMessage = "Delay in seconds between retry attempts (default: 2)")]
    [ValidateRange(1, 30)]
    [int]$RetryDelaySeconds = 2,
    
    [Parameter(Mandatory = $false, HelpMessage = "Maximum number of retry attempts per operation (default: 3)")]
    [ValidateRange(1, 10)]
    [int]$MaxOperationRetries = 3
)

#region A) Credential Loading and Configs
# Add this credential loading logic at the beginning of your script
if ($CredentialPath) {
    # Handle special dry run mode
    if ($CredentialPath -eq "DRYRUN_MODE") {
        Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO ] Running in dry run mode - skipping credential loading" -ForegroundColor Yellow
        # Create a dummy credential for dry run mode
        $securePassword = ConvertTo-SecureString "DryRunPassword" -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential("DryRunUser", $securePassword)
    }
    elseif (Test-Path $CredentialPath) {
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
    
    $ariaLogEntry = @{
        Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
        Level = $Level
        Source = "VMTags-Automation"
        Environment = $Environment
        Message = $Message
        Machine = $env:COMPUTERNAME
        User = $env:USERNAME
    }
    
    # Output in format Aria can parse
    $ariaLogEntry | ConvertTo-Json -Compress | Write-Host
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
        $logEntry = [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Level     = $Level.ToUpper()
            Message   = $Message
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

#region Thread-Safe Logging for Parallel Operations
# Initialize thread-safe logging system
$script:LogMutex = $null
$script:ProgressData = @{}
$script:ParallelLogQueue = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()

function Initialize-ThreadSafeLogging {
    [CmdletBinding()]
    Param()
    
    try {
        # Create a named mutex for cross-thread synchronization
        $mutexName = "VMTags_Logging_$($script:ExecutionTimestamp)"
        $script:LogMutex = [System.Threading.Mutex]::new($false, $mutexName)
        
        # Initialize progress tracking
        $script:ProgressData = [hashtable]::Synchronized(@{
            TotalVMs = 0
            ProcessedVMs = 0
            SuccessfulVMs = 0
            FailedVMs = 0
            SkippedVMs = 0
            StartTime = Get-Date
            BatchesCompleted = 0
            CurrentBatch = 0
            ThreadMetrics = @{}
        })
        
        Write-Log "Thread-safe logging system initialized with mutex: $mutexName" "DEBUG"
        return $true
    }
    catch {
        Write-Log "Failed to initialize thread-safe logging: $_" "ERROR"
        return $false
    }
}

function Write-ThreadSafeLog {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",
        [Parameter(Mandatory = $false)]
        [int]$ThreadId = 0,
        [Parameter(Mandatory = $false)]
        [string]$VMName = ""
    )
    
    $logEntry = [PSCustomObject]@{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Level = $Level
        ThreadId = $ThreadId
        VMName = $VMName
        Message = $Message
        ProcessId = $PID
    }
    
    # Queue the log entry for thread-safe processing
    $script:ParallelLogQueue.Enqueue($logEntry)
    
    # Also write to console immediately for real-time feedback
    $consoleColor = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "DEBUG" { "Gray" }
        default { "White" }
    }
    
    $threadPrefix = if ($ThreadId -gt 0) { "[T$ThreadId]" } else { "" }
    $vmPrefix = if ($VMName) { "[$VMName]" } else { "" }
    
    Write-Host "$($logEntry.Timestamp) [$Level] $threadPrefix$vmPrefix $Message" -ForegroundColor $consoleColor
}

function Update-ProgressData {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Updates
    )
    
    try {
        if ($script:LogMutex.WaitOne(1000)) {
            try {
                foreach ($key in $Updates.Keys) {
                    $script:ProgressData[$key] = $Updates[$key]
                }
                
                # Calculate derived metrics
                if ($script:ProgressData.TotalVMs -gt 0) {
                    $script:ProgressData.PercentComplete = [math]::Round(($script:ProgressData.ProcessedVMs / $script:ProgressData.TotalVMs) * 100, 2)
                }
                
                $elapsed = (Get-Date) - $script:ProgressData.StartTime
                $script:ProgressData.ElapsedMinutes = [math]::Round($elapsed.TotalMinutes, 2)
                
                if ($script:ProgressData.ProcessedVMs -gt 0) {
                    $avgTimePerVM = $elapsed.TotalSeconds / $script:ProgressData.ProcessedVMs
                    $remainingVMs = $script:ProgressData.TotalVMs - $script:ProgressData.ProcessedVMs
                    $estimatedRemainingSeconds = $avgTimePerVM * $remainingVMs
                    $script:ProgressData.EstimatedRemainingMinutes = [math]::Round($estimatedRemainingSeconds / 60, 2)
                    $script:ProgressData.VMsPerMinute = [math]::Round($script:ProgressData.ProcessedVMs / $elapsed.TotalMinutes, 2)
                }
            }
            finally {
                $script:LogMutex.ReleaseMutex()
            }
        }
    }
    catch {
        Write-ThreadSafeLog "Failed to update progress data: $_" "ERROR"
    }
}

function Get-ProgressSummary {
    [CmdletBinding()]
    Param()
    
    try {
        if ($script:LogMutex.WaitOne(1000)) {
            try {
                return $script:ProgressData.Clone()
            }
            finally {
                $script:LogMutex.ReleaseMutex()
            }
        }
    }
    catch {
        Write-ThreadSafeLog "Failed to get progress summary: $_" "ERROR"
        return @{}
    }
}

function Flush-ParallelLogs {
    [CmdletBinding()]
    Param()
    
    try {
        $logEntries = @()
        $logEntry = $null
        
        # Dequeue all pending log entries
        while ($script:ParallelLogQueue.TryDequeue([ref]$logEntry)) {
            $logEntries += $logEntry
        }
        
        if ($logEntries.Count -gt 0) {
            # Write to file in batch for better performance
            if ($script:LogMutex.WaitOne(2000)) {
                try {
                    foreach ($entry in $logEntries) {
                        $logLine = "$($entry.Timestamp) [$($entry.Level)] [T$($entry.ThreadId)] $($entry.Message)"
                        if ($entry.VMName) {
                            $logLine = "$($entry.Timestamp) [$($entry.Level)] [T$($entry.ThreadId)] [$($entry.VMName)] $($entry.Message)"
                        }
                        
                        # Add to script output log for CSV export
                        $script:outputLog += [PSCustomObject]@{
                            Timestamp = $entry.Timestamp
                            Level = $entry.Level
                            ThreadId = $entry.ThreadId
                            VMName = $entry.VMName
                            Message = $entry.Message
                        }
                        
                        # Write to log file
                        try {
                            Add-Content -Path $script:LogFilePath -Value $logLine -ErrorAction SilentlyContinue
                        }
                        catch {
                            # Suppress file write errors to avoid spam
                        }
                    }
                }
                finally {
                    $script:LogMutex.ReleaseMutex()
                }
            }
            
            Write-ThreadSafeLog "Flushed $($logEntries.Count) parallel log entries" "DEBUG"
        }
    }
    catch {
        Write-Log "Failed to flush parallel logs: $_" "ERROR"
    }
}

function Cleanup-ThreadSafeLogging {
    [CmdletBinding()]
    Param()
    
    try {
        # Flush any remaining logs
        Flush-ParallelLogs
        
        # Dispose of mutex
        if ($script:LogMutex) {
            $script:LogMutex.Dispose()
            $script:LogMutex = $null
        }
        
        Write-Log "Thread-safe logging system cleaned up" "DEBUG"
    }
    catch {
        Write-Log "Error cleaning up thread-safe logging: $_" "ERROR"
    }
}
#endregion

#region Batch Processing Logic for Intelligent VM Batching
function Split-VMsIntoBatches {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [array]$VMs,
        [Parameter(Mandatory = $false)]
        [int]$BatchSize = 50,
        [Parameter(Mandatory = $false)]
        [string]$BatchingStrategy = "RoundRobin"
    )
    
    try {
        Write-ThreadSafeLog "Splitting $($VMs.Count) VMs into batches of size $BatchSize using $BatchingStrategy strategy" "INFO"
        
        $batches = @()
        $batchIndex = 0
        
        switch ($BatchingStrategy) {
            "RoundRobin" {
                # Default strategy - simple round-robin distribution
                for ($i = 0; $i -lt $VMs.Count; $i += $BatchSize) {
                    $endIndex = [math]::Min($i + $BatchSize - 1, $VMs.Count - 1)
                    $batch = $VMs[$i..$endIndex]
                    
                    $batchObject = [PSCustomObject]@{
                        BatchId = $batchIndex++
                        VMs = $batch
                        Count = $batch.Count
                        EstimatedComplexity = $batch.Count # Simple complexity based on count
                        PowerStateDistribution = ($batch | Group-Object PowerState | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ","
                    }
                    
                    $batches += $batchObject
                    Write-ThreadSafeLog "Created batch $($batchObject.BatchId) with $($batchObject.Count) VMs (PowerStates: $($batchObject.PowerStateDistribution))" "DEBUG"
                }
            }
            
            "PowerStateBalanced" {
                # Advanced strategy - balance powered on vs off VMs across batches
                $poweredOnVMs = $VMs | Where-Object { $_.PowerState -eq "PoweredOn" }
                $poweredOffVMs = $VMs | Where-Object { $_.PowerState -ne "PoweredOn" }
                
                Write-ThreadSafeLog "PowerStateBalanced: $($poweredOnVMs.Count) powered on, $($poweredOffVMs.Count) powered off VMs" "DEBUG"
                
                $totalBatches = [math]::Ceiling($VMs.Count / $BatchSize)
                $onVMsPerBatch = [math]::Ceiling($poweredOnVMs.Count / $totalBatches)
                $offVMsPerBatch = [math]::Ceiling($poweredOffVMs.Count / $totalBatches)
                
                for ($batchNum = 0; $batchNum -lt $totalBatches; $batchNum++) {
                    $batchVMs = @()
                    
                    # Add powered on VMs to this batch
                    $onStartIndex = $batchNum * $onVMsPerBatch
                    $onEndIndex = [math]::Min($onStartIndex + $onVMsPerBatch - 1, $poweredOnVMs.Count - 1)
                    if ($onStartIndex -lt $poweredOnVMs.Count) {
                        $batchVMs += $poweredOnVMs[$onStartIndex..$onEndIndex]
                    }
                    
                    # Add powered off VMs to this batch
                    $offStartIndex = $batchNum * $offVMsPerBatch
                    $offEndIndex = [math]::Min($offStartIndex + $offVMsPerBatch - 1, $poweredOffVMs.Count - 1)
                    if ($offStartIndex -lt $poweredOffVMs.Count) {
                        $batchVMs += $poweredOffVMs[$offStartIndex..$offEndIndex]
                    }
                    
                    if ($batchVMs.Count -gt 0) {
                        $batchObject = [PSCustomObject]@{
                            BatchId = $batchIndex++
                            VMs = $batchVMs
                            Count = $batchVMs.Count
                            EstimatedComplexity = ($batchVMs | Where-Object { $_.PowerState -eq "PoweredOn" }).Count * 1.5 + ($batchVMs | Where-Object { $_.PowerState -ne "PoweredOn" }).Count
                            PowerStateDistribution = ($batchVMs | Group-Object PowerState | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ","
                        }
                        
                        $batches += $batchObject
                        Write-ThreadSafeLog "Created balanced batch $($batchObject.BatchId) with $($batchObject.Count) VMs (Complexity: $($batchObject.EstimatedComplexity))" "DEBUG"
                    }
                }
            }
            
            "ComplexityBalanced" {
                # Most advanced - balance based on VM complexity (powered state, OS type, existing tags)
                $vmsWithComplexity = $VMs | ForEach-Object {
                    $complexity = 1 # Base complexity
                    
                    # Powered on VMs are more complex (VMware Tools data available)
                    if ($_.PowerState -eq "PoweredOn") { $complexity += 0.5 }
                    
                    # VMs with existing tags might need more processing
                    try {
                        $existingTags = Get-TagAssignment -Entity $_ -ErrorAction SilentlyContinue
                        if ($existingTags) { $complexity += ($existingTags.Count * 0.1) }
                    }
                    catch {
                        # Ignore tag assignment errors during batching
                    }
                    
                    [PSCustomObject]@{
                        VM = $_
                        Complexity = $complexity
                    }
                }
                
                # Sort by complexity and distribute evenly
                $sortedVMs = $vmsWithComplexity | Sort-Object Complexity
                $totalBatches = [math]::Ceiling($VMs.Count / $BatchSize)
                
                for ($batchNum = 0; $batchNum -lt $totalBatches; $batchNum++) {
                    $batchVMs = @()
                    $batchComplexity = 0
                    
                    # Distribute VMs to balance complexity across batches
                    for ($vmIndex = $batchNum; $vmIndex -lt $sortedVMs.Count; $vmIndex += $totalBatches) {
                        if ($batchVMs.Count -lt $BatchSize) {
                            $batchVMs += $sortedVMs[$vmIndex].VM
                            $batchComplexity += $sortedVMs[$vmIndex].Complexity
                        }
                    }
                    
                    if ($batchVMs.Count -gt 0) {
                        $batchObject = [PSCustomObject]@{
                            BatchId = $batchIndex++
                            VMs = $batchVMs
                            Count = $batchVMs.Count
                            EstimatedComplexity = [math]::Round($batchComplexity, 2)
                            PowerStateDistribution = ($batchVMs | Group-Object PowerState | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ","
                        }
                        
                        $batches += $batchObject
                        Write-ThreadSafeLog "Created complexity-balanced batch $($batchObject.BatchId) with $($batchObject.Count) VMs (Complexity: $($batchObject.EstimatedComplexity))" "DEBUG"
                    }
                }
            }
        }
        
        Write-ThreadSafeLog "Successfully created $($batches.Count) batches with total complexity: $([math]::Round(($batches | Measure-Object EstimatedComplexity -Sum).Sum, 2))" "INFO"
        return $batches
    }
    catch {
        Write-ThreadSafeLog "Failed to split VMs into batches: $_" "ERROR"
        throw
    }
}

function Get-OptimalBatchSettings {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [int]$TotalVMs,
        [Parameter(Mandatory = $true)]
        [int]$MaxParallelThreads,
        [Parameter(Mandatory = $false)]
        [int]$RequestedBatchSize = 50
    )
    
    try {
        # Calculate optimal settings based on VM count and system resources
        $systemInfo = @{
            LogicalProcessors = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
            TotalMemoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
        }
        
        # Adjust batch size based on total VMs and thread count
        $optimalBatchSize = $RequestedBatchSize
        
        if ($TotalVMs -lt 100) {
            # Small inventories - smaller batches for better granularity
            $optimalBatchSize = [math]::Min($RequestedBatchSize, 25)
        }
        elseif ($TotalVMs -gt 1000) {
            # Large inventories - larger batches for efficiency
            $optimalBatchSize = [math]::Max($RequestedBatchSize, 75)
        }
        
        # Ensure we don't create more batches than we can process efficiently
        $maxRecommendedBatches = $MaxParallelThreads * 4
        if (([math]::Ceiling($TotalVMs / $optimalBatchSize)) -gt $maxRecommendedBatches) {
            $optimalBatchSize = [math]::Ceiling($TotalVMs / $maxRecommendedBatches)
        }
        
        # Choose batching strategy based on inventory size
        $recommendedStrategy = if ($TotalVMs -lt 200) {
            "RoundRobin"
        }
        elseif ($TotalVMs -lt 500) {
            "PowerStateBalanced"
        }
        else {
            "ComplexityBalanced"
        }
        
        $settings = [PSCustomObject]@{
            OptimalBatchSize = $optimalBatchSize
            RecommendedStrategy = $recommendedStrategy
            EstimatedBatches = [math]::Ceiling($TotalVMs / $optimalBatchSize)
            SystemInfo = $systemInfo
            Reasoning = @{
                BatchSizeAdjustment = "Adjusted from $RequestedBatchSize to $optimalBatchSize based on inventory size"
                StrategySelection = "Selected $recommendedStrategy strategy for $TotalVMs VMs"
                SystemConsideration = "$($systemInfo.LogicalProcessors) logical processors, $($systemInfo.TotalMemoryGB)GB RAM detected"
            }
        }
        
        Write-ThreadSafeLog "Optimal batch settings: $($settings.OptimalBatchSize) batch size, $($settings.RecommendedStrategy) strategy, $($settings.EstimatedBatches) estimated batches" "INFO"
        return $settings
    }
    catch {
        Write-ThreadSafeLog "Failed to calculate optimal batch settings: $_" "ERROR"
        # Return safe defaults
        return [PSCustomObject]@{
            OptimalBatchSize = 50
            RecommendedStrategy = "RoundRobin"
            EstimatedBatches = [math]::Ceiling($TotalVMs / 50)
        }
    }
}

function Test-BatchPerformance {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [array]$Batches,
        [Parameter(Mandatory = $false)]
        [switch]$DetailedAnalysis
    )
    
    try {
        $analysis = [PSCustomObject]@{
            TotalBatches = $Batches.Count
            TotalVMs = ($Batches | Measure-Object -Property Count -Sum).Sum
            AverageBatchSize = [math]::Round(($Batches | Measure-Object -Property Count -Average).Average, 2)
            MinBatchSize = ($Batches | Measure-Object -Property Count -Minimum).Minimum
            MaxBatchSize = ($Batches | Measure-Object -Property Count -Maximum).Maximum
            TotalComplexity = [math]::Round(($Batches | Measure-Object -Property EstimatedComplexity -Sum).Sum, 2)
            AverageComplexity = [math]::Round(($Batches | Measure-Object -Property EstimatedComplexity -Average).Average, 2)
            ComplexityBalance = @{}
        }
        
        # Calculate complexity balance (variance from average)
        $complexityVariance = 0
        foreach ($batch in $Batches) {
            $complexityVariance += [math]::Pow($batch.EstimatedComplexity - $analysis.AverageComplexity, 2)
        }
        $analysis.ComplexityBalance.Variance = [math]::Round($complexityVariance / $Batches.Count, 2)
        $analysis.ComplexityBalance.StandardDeviation = [math]::Round([math]::Sqrt($analysis.ComplexityBalance.Variance), 2)
        $analysis.ComplexityBalance.BalanceScore = [math]::Max(0, 100 - ($analysis.ComplexityBalance.StandardDeviation * 10))
        
        if ($DetailedAnalysis) {
            $analysis | Add-Member -NotePropertyName "BatchDetails" -NotePropertyValue ($Batches | Select-Object BatchId, Count, EstimatedComplexity, PowerStateDistribution)
        }
        
        Write-ThreadSafeLog "Batch analysis: $($analysis.TotalBatches) batches, avg size $($analysis.AverageBatchSize), balance score $([math]::Round($analysis.ComplexityBalance.BalanceScore, 1))%" "INFO"
        return $analysis
    }
    catch {
        Write-ThreadSafeLog "Failed to analyze batch performance: $_" "ERROR"
        return $null
    }
}
#endregion

#region Progress Tracking System with Real-Time Performance Metrics
function Start-ProgressTracking {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [int]$TotalVMs,
        [Parameter(Mandatory = $true)]
        [int]$TotalBatches,
        [Parameter(Mandatory = $false)]
        [int]$MaxParallelThreads = 4
    )
    
    try {
        # Initialize comprehensive progress tracking
        Update-ProgressData -Updates @{
            TotalVMs = $TotalVMs
            TotalBatches = $TotalBatches
            MaxParallelThreads = $MaxParallelThreads
            ProcessedVMs = 0
            SuccessfulVMs = 0
            FailedVMs = 0
            SkippedVMs = 0
            TagsAssigned = 0
            PermissionsCreated = 0
            PermissionsSkipped = 0
            PermissionsFailed = 0
            BatchesCompleted = 0
            CurrentBatch = 0
            StartTime = Get-Date
            LastUpdateTime = Get-Date
            PercentComplete = 0
            ElapsedMinutes = 0
            EstimatedRemainingMinutes = 0
            VMsPerMinute = 0
            ThreadMetrics = @{}
        }
        
        # Initialize thread-specific metrics
        for ($i = 1; $i -le $MaxParallelThreads; $i++) {
            $script:ProgressData.ThreadMetrics["Thread$i"] = @{
                VMsProcessed = 0
                CurrentVM = ""
                Status = "Idle"
                LastActivity = Get-Date
                Errors = 0
                BatchesProcessed = 0
            }
        }
        
        Write-ThreadSafeLog "Progress tracking initialized for $TotalVMs VMs across $TotalBatches batches with $MaxParallelThreads threads" "INFO"
        
        # Start background progress reporter
        Start-ProgressReporter
        
        return $true
    }
    catch {
        Write-ThreadSafeLog "Failed to start progress tracking: $_" "ERROR"
        return $false
    }
}

function Update-ThreadStatus {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [int]$ThreadId,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter(Mandatory = $false)]
        [string]$CurrentVM = "",
        [Parameter(Mandatory = $false)]
        [string]$CurrentAction = ""
    )
    
    try {
        if ($script:LogMutex.WaitOne(500)) {
            try {
                $threadKey = "Thread$ThreadId"
                if ($script:ProgressData.ThreadMetrics.ContainsKey($threadKey)) {
                    $script:ProgressData.ThreadMetrics[$threadKey].Status = $Status
                    $script:ProgressData.ThreadMetrics[$threadKey].CurrentVM = $CurrentVM
                    $script:ProgressData.ThreadMetrics[$threadKey].LastActivity = Get-Date
                    
                    if ($CurrentAction) {
                        $script:ProgressData.ThreadMetrics[$threadKey].CurrentAction = $CurrentAction
                    }
                    
                    # Update counts based on status
                    switch ($Status) {
                        "Processing" { 
                            $script:ProgressData.ThreadMetrics[$threadKey].VMsProcessed++
                        }
                        "Error" { 
                            $script:ProgressData.ThreadMetrics[$threadKey].Errors++
                        }
                        "BatchCompleted" {
                            $script:ProgressData.ThreadMetrics[$threadKey].BatchesProcessed++
                        }
                    }
                }
                
                $script:ProgressData.LastUpdateTime = Get-Date
            }
            finally {
                $script:LogMutex.ReleaseMutex()
            }
        }
    }
    catch {
        Write-ThreadSafeLog "Failed to update thread $ThreadId status: $_" "ERROR" -ThreadId $ThreadId
    }
}

function Update-VMProgress {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$Result, # Success, Failed, Skipped
        [Parameter(Mandatory = $false)]
        [int]$ThreadId = 0,
        [Parameter(Mandatory = $false)]
        [hashtable]$Metrics = @{}
    )
    
    try {
        $updates = @{
            ProcessedVMs = $script:ProgressData.ProcessedVMs + 1
            LastUpdateTime = Get-Date
        }
        
        # Update result counters
        switch ($Result) {
            "Success" { 
                $updates.SuccessfulVMs = $script:ProgressData.SuccessfulVMs + 1
            }
            "Failed" { 
                $updates.FailedVMs = $script:ProgressData.FailedVMs + 1
            }
            "Skipped" { 
                $updates.SkippedVMs = $script:ProgressData.SkippedVMs + 1
            }
        }
        
        # Update specific metrics if provided
        foreach ($metric in $Metrics.Keys) {
            if ($script:ProgressData.ContainsKey($metric)) {
                $updates[$metric] = $script:ProgressData[$metric] + $Metrics[$metric]
            }
        }
        
        Update-ProgressData -Updates $updates
        
        Write-ThreadSafeLog "VM '$VMName' processed with result: $Result" "DEBUG" -ThreadId $ThreadId -VMName $VMName
    }
    catch {
        Write-ThreadSafeLog "Failed to update VM progress for '$VMName': $_" "ERROR" -ThreadId $ThreadId
    }
}

function Start-ProgressReporter {
    [CmdletBinding()]
    Param()
    
    # Start a background job for periodic progress reporting
    $script:ProgressReporterJob = Start-Job -ScriptBlock {
        param($ProgressDataRef, $LogMutexName)
        
        # Import necessary functions (simplified for background job)
        function Write-ProgressReport {
            param($Progress)
            
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $line1 = "[$timestamp] === PROGRESS REPORT ==="
            $line2 = "VMs: $($Progress.ProcessedVMs)/$($Progress.TotalVMs) ($($Progress.PercentComplete)% complete)"
            $line3 = "Success: $($Progress.SuccessfulVMs), Failed: $($Progress.FailedVMs), Skipped: $($Progress.SkippedVMs)"
            $line4 = "Batches: $($Progress.BatchesCompleted)/$($Progress.TotalBatches)"
            $line5 = "Rate: $($Progress.VMsPerMinute) VMs/min, ETA: $($Progress.EstimatedRemainingMinutes) min"
            $line6 = "Elapsed: $($Progress.ElapsedMinutes) min"
            
            Write-Host $line1 -ForegroundColor Cyan
            Write-Host $line2 -ForegroundColor White
            Write-Host $line3 -ForegroundColor Green
            Write-Host $line4 -ForegroundColor Yellow
            Write-Host $line5 -ForegroundColor Magenta
            Write-Host $line6 -ForegroundColor Gray
            Write-Host "========================================" -ForegroundColor Cyan
        }
        
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting($LogMutexName)
            
            while ($true) {
                Start-Sleep -Seconds 30  # Report every 30 seconds
                
                try {
                    if ($mutex.WaitOne(1000)) {
                        try {
                            # Get current progress (simplified access)
                            $currentProgress = $ProgressDataRef
                            if ($currentProgress -and $currentProgress.TotalVMs -gt 0) {
                                Write-ProgressReport -Progress $currentProgress
                            }
                        }
                        finally {
                            $mutex.ReleaseMutex()
                        }
                    }
                }
                catch {
                    # Ignore errors in background reporting
                }
            }
        }
        catch {
            # Background job failed to start - not critical
        }
    } -ArgumentList $script:ProgressData, "VMTags_Logging_$($script:ExecutionTimestamp)"
}

function Stop-ProgressReporter {
    [CmdletBinding()]
    Param()
    
    try {
        if ($script:ProgressReporterJob) {
            Stop-Job -Job $script:ProgressReporterJob -PassThru | Remove-Job
            $script:ProgressReporterJob = $null
            Write-ThreadSafeLog "Progress reporter stopped" "DEBUG"
        }
    }
    catch {
        Write-ThreadSafeLog "Error stopping progress reporter: $_" "ERROR"
    }
}

function Get-DetailedProgressReport {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$IncludeThreadDetails,
        [Parameter(Mandatory = $false)]
        [switch]$IncludePerformanceMetrics
    )
    
    try {
        $progress = Get-ProgressSummary
        if (-not $progress) { return $null }
        
        $report = [PSCustomObject]@{
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
            Summary = @{
                TotalVMs = $progress.TotalVMs
                ProcessedVMs = $progress.ProcessedVMs
                SuccessfulVMs = $progress.SuccessfulVMs
                FailedVMs = $progress.FailedVMs
                SkippedVMs = $progress.SkippedVMs
                PercentComplete = $progress.PercentComplete
            }
            Timing = @{
                ElapsedMinutes = $progress.ElapsedMinutes
                EstimatedRemainingMinutes = $progress.EstimatedRemainingMinutes
                VMsPerMinute = $progress.VMsPerMinute
                StartTime = $progress.StartTime
            }
            Operations = @{
                TagsAssigned = $progress.TagsAssigned
                PermissionsCreated = $progress.PermissionsCreated
                PermissionsSkipped = $progress.PermissionsSkipped
                PermissionsFailed = $progress.PermissionsFailed
            }
            Batches = @{
                Completed = $progress.BatchesCompleted
                Total = $progress.TotalBatches
                Current = $progress.CurrentBatch
            }
        }
        
        if ($IncludeThreadDetails) {
            $report | Add-Member -NotePropertyName "ThreadDetails" -NotePropertyValue $progress.ThreadMetrics
        }
        
        if ($IncludePerformanceMetrics) {
            $successRate = if ($progress.ProcessedVMs -gt 0) { [math]::Round(($progress.SuccessfulVMs / $progress.ProcessedVMs) * 100, 2) } else { 0 }
            $errorRate = if ($progress.ProcessedVMs -gt 0) { [math]::Round(($progress.FailedVMs / $progress.ProcessedVMs) * 100, 2) } else { 0 }
            
            $performanceMetrics = @{
                SuccessRate = $successRate
                ErrorRate = $errorRate
                SkipRate = if ($progress.ProcessedVMs -gt 0) { [math]::Round(($progress.SkippedVMs / $progress.ProcessedVMs) * 100, 2) } else { 0 }
                OverallEfficiency = [math]::Max(0, 100 - $errorRate)
                AverageTimePerVM = if ($progress.ProcessedVMs -gt 0) { [math]::Round($progress.ElapsedMinutes * 60 / $progress.ProcessedVMs, 2) } else { 0 }
            }
            
            $report | Add-Member -NotePropertyName "PerformanceMetrics" -NotePropertyValue $performanceMetrics
        }
        
        return $report
    }
    catch {
        Write-ThreadSafeLog "Failed to generate detailed progress report: $_" "ERROR"
        return $null
    }
}

function Show-FinalProgressSummary {
    [CmdletBinding()]
    Param()
    
    try {
        $finalReport = Get-DetailedProgressReport -IncludePerformanceMetrics
        if (-not $finalReport) { return }
        
        Write-Host "`n" -ForegroundColor White
        Write-Host "╔══════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                                   FINAL EXECUTION SUMMARY                               ║" -ForegroundColor Green  
        Write-Host "╚══════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        
        # VM Processing Summary
        Write-Host "🎯 VM PROCESSING RESULTS:" -ForegroundColor Cyan
        Write-Host "   Total VMs Processed: $($finalReport.Summary.ProcessedVMs) / $($finalReport.Summary.TotalVMs)" -ForegroundColor White
        Write-Host "   ✅ Successful: $($finalReport.Summary.SuccessfulVMs) ($($finalReport.PerformanceMetrics.SuccessRate)%)" -ForegroundColor Green
        Write-Host "   ❌ Failed: $($finalReport.Summary.FailedVMs) ($($finalReport.PerformanceMetrics.ErrorRate)%)" -ForegroundColor Red
        Write-Host "   ⏭️  Skipped: $($finalReport.Summary.SkippedVMs) ($($finalReport.PerformanceMetrics.SkipRate)%)" -ForegroundColor Yellow
        Write-Host ""
        
        # Performance Metrics
        Write-Host "⚡ PERFORMANCE METRICS:" -ForegroundColor Cyan
        Write-Host "   Total Runtime: $($finalReport.Timing.ElapsedMinutes) minutes" -ForegroundColor White
        Write-Host "   Processing Rate: $($finalReport.Timing.VMsPerMinute) VMs per minute" -ForegroundColor White
        Write-Host "   Average Time per VM: $($finalReport.PerformanceMetrics.AverageTimePerVM) seconds" -ForegroundColor White
        Write-Host "   Overall Efficiency: $($finalReport.PerformanceMetrics.OverallEfficiency)%" -ForegroundColor White
        Write-Host ""
        
        # Operations Summary
        Write-Host "🏷️ OPERATIONS COMPLETED:" -ForegroundColor Cyan
        Write-Host "   Tags Assigned: $($finalReport.Operations.TagsAssigned)" -ForegroundColor White
        Write-Host "   Permissions Created: $($finalReport.Operations.PermissionsCreated)" -ForegroundColor White
        Write-Host "   Permissions Skipped: $($finalReport.Operations.PermissionsSkipped)" -ForegroundColor White
        Write-Host "   Permission Failures: $($finalReport.Operations.PermissionsFailed)" -ForegroundColor White
        Write-Host ""
        
        # Batch Processing
        Write-Host "📦 BATCH PROCESSING:" -ForegroundColor Cyan
        Write-Host "   Batches Completed: $($finalReport.Batches.Completed) / $($finalReport.Batches.Total)" -ForegroundColor White
        Write-Host ""
        
        Write-Host "╔══════════════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                                     EXECUTION COMPLETE                                  ║" -ForegroundColor Green
        Write-Host "╚══════════════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        
    }
    catch {
        Write-ThreadSafeLog "Failed to show final progress summary: $_" "ERROR"
    }
}
#endregion

#region Error Handling for Parallel Operations

# Global error tracking for parallel operations
$script:ParallelErrors = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
$script:RetryAttempts = @{}
$script:MaxRetries = 3
$script:RetryDelaySeconds = 2

function Initialize-ErrorHandling {
    <#
    .SYNOPSIS
    Initializes the error handling system for parallel operations.
    
    .DESCRIPTION
    Sets up concurrent error tracking, retry mechanisms, and recovery strategies
    for robust parallel processing of VM operations.
    #>
    [CmdletBinding()]
    param()
    
    try {
        Write-ThreadSafeLog "Initializing error handling system for parallel operations" "INFO"
        
        # Initialize error tracking collections
        $script:ParallelErrors = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
        $script:RetryAttempts = [System.Collections.Concurrent.ConcurrentDictionary[string, int]]::new()
        
        # Set default retry configuration
        if (-not $script:MaxRetries) { $script:MaxRetries = 3 }
        if (-not $script:RetryDelaySeconds) { $script:RetryDelaySeconds = 2 }
        
        Write-ThreadSafeLog "Error handling system initialized successfully" "INFO"
        Write-ThreadSafeLog "Max retries: $script:MaxRetries, Retry delay: $script:RetryDelaySeconds seconds" "DEBUG"
        
        return $true
    }
    catch {
        Write-ThreadSafeLog "Failed to initialize error handling system: $_" "ERROR"
        return $false
    }
}

function Register-ParallelError {
    <#
    .SYNOPSIS
    Registers an error that occurred during parallel operations.
    
    .DESCRIPTION
    Thread-safely logs and tracks errors from parallel VM processing operations,
    including context information for debugging and recovery.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        
        [Parameter(Mandatory = $false)]
        [int]$ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Context = @{}
    )
    
    try {
        $errorInfo = [PSCustomObject]@{
            Timestamp = Get-Date
            VMName = $VMName
            Operation = $Operation
            ThreadId = $ThreadId
            ErrorMessage = $ErrorRecord.Exception.Message
            ErrorCategory = $ErrorRecord.CategoryInfo.Category
            ScriptStackTrace = $ErrorRecord.ScriptStackTrace
            FullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
            Context = $Context
            RetryCount = $script:RetryAttempts["$VMName-$Operation"]
        }
        
        # Add to concurrent error collection
        $script:ParallelErrors.Add($errorInfo)
        
        # Log the error with thread context
        $contextStr = if ($Context.Count -gt 0) { " Context: $($Context | ConvertTo-Json -Compress)" } else { "" }
        Write-ThreadSafeLog "Thread $ThreadId - VM '$VMName' failed operation '$Operation': $($ErrorRecord.Exception.Message)$contextStr" "ERROR"
        
        # Update progress data with error information
        if ($script:ProgressData.ContainsKey($ThreadId)) {
            $script:ProgressData[$ThreadId].ErrorCount++
            $script:ProgressData[$ThreadId].LastError = $ErrorRecord.Exception.Message
            $script:ProgressData[$ThreadId].LastErrorTime = Get-Date
        }
        
        return $errorInfo
    }
    catch {
        Write-ThreadSafeLog "Failed to register parallel error: $_" "ERROR"
        return $null
    }
}

function Test-ShouldRetry {
    <#
    .SYNOPSIS
    Determines if an operation should be retried based on error type and retry count.
    
    .DESCRIPTION
    Analyzes error conditions to determine if a retry is appropriate and manages
    retry attempt tracking for parallel operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    try {
        $retryKey = "$VMName-$Operation"
        $currentRetries = $script:RetryAttempts.GetOrAdd($retryKey, 0)
        
        # Check if we've exceeded max retries
        if ($currentRetries -ge $script:MaxRetries) {
            Write-ThreadSafeLog "VM '$VMName' operation '$Operation' exceeded max retries ($script:MaxRetries)" "WARN"
            return $false
        }
        
        # Determine if error type is retryable
        $isRetryable = $false
        $errorMessage = $ErrorRecord.Exception.Message
        $errorCategory = $ErrorRecord.CategoryInfo.Category
        
        # Network/connectivity related errors are generally retryable
        if ($errorMessage -match "timeout|connection|network|unavailable|busy|locked" -or
            $errorCategory -in @('ConnectionError', 'ResourceUnavailable', 'OperationTimeout')) {
            $isRetryable = $true
        }
        
        # PowerCLI specific retryable errors
        if ($errorMessage -match "The operation is not allowed in the current state|Server was unable to process request|Service Unavailable") {
            $isRetryable = $true
        }
        
        # Authentication errors might be temporary
        if ($errorMessage -match "authentication|authorization" -and $currentRetries -eq 0) {
            $isRetryable = $true
        }
        
        # Log retry decision
        if ($isRetryable) {
            Write-ThreadSafeLog "VM '$VMName' operation '$Operation' is retryable (attempt $($currentRetries + 1)/$script:MaxRetries)" "INFO"
        } else {
            Write-ThreadSafeLog "VM '$VMName' operation '$Operation' is not retryable or permanent failure" "WARN"
        }
        
        return $isRetryable
    }
    catch {
        Write-ThreadSafeLog "Failed to determine retry eligibility: $_" "ERROR"
        return $false
    }
}

function Invoke-RetryOperation {
    <#
    .SYNOPSIS
    Executes a retry of a failed operation with exponential backoff.
    
    .DESCRIPTION
    Implements retry logic with configurable delays and tracks retry attempts
    for robust error recovery in parallel operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{},
        
        [Parameter(Mandatory = $false)]
        [int]$ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    )
    
    try {
        $retryKey = "$VMName-$Operation"
        
        # Increment retry count
        $retryCount = $script:RetryAttempts.AddOrUpdate($retryKey, 1, { param($key, $oldValue) $oldValue + 1 })
        
        # Calculate exponential backoff delay
        $delaySeconds = $script:RetryDelaySeconds * [Math]::Pow(2, $retryCount - 1)
        $maxDelay = 30 # Cap at 30 seconds
        if ($delaySeconds -gt $maxDelay) { $delaySeconds = $maxDelay }
        
        Write-ThreadSafeLog "Thread $ThreadId - Retrying VM '$VMName' operation '$Operation' (attempt $retryCount) after $delaySeconds second delay" "INFO"
        
        # Wait before retry
        Start-Sleep -Seconds $delaySeconds
        
        # Update progress tracking
        if ($script:ProgressData.ContainsKey($ThreadId)) {
            $script:ProgressData[$ThreadId].RetryCount++
            $script:ProgressData[$ThreadId].CurrentOperation = "Retrying: $Operation"
        }
        
        # Execute the retry
        $result = & $ScriptBlock @Parameters
        
        # If successful, remove from retry tracking
        $script:RetryAttempts.TryRemove($retryKey, [ref]$null) | Out-Null
        
        Write-ThreadSafeLog "Thread $ThreadId - VM '$VMName' operation '$Operation' retry successful" "INFO"
        
        return @{
            Success = $true
            Result = $result
            RetryCount = $retryCount
        }
    }
    catch {
        Write-ThreadSafeLog "Thread $ThreadId - VM '$VMName' operation '$Operation' retry failed: $_" "ERROR"
        
        return @{
            Success = $false
            Error = $_
            RetryCount = $retryCount
        }
    }
}

function Invoke-RobustOperation {
    <#
    .SYNOPSIS
    Executes an operation with built-in error handling and retry logic.
    
    .DESCRIPTION
    Wraps VM operations with comprehensive error handling, retry mechanisms,
    and recovery strategies for robust parallel execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{},
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Context = @{},
        
        [Parameter(Mandatory = $false)]
        [int]$ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    )
    
    try {
        Write-ThreadSafeLog "Thread $ThreadId - Starting robust operation '$Operation' for VM '$VMName'" "DEBUG"
        
        # Initial attempt
        try {
            $result = & $ScriptBlock @Parameters
            Write-ThreadSafeLog "Thread $ThreadId - VM '$VMName' operation '$Operation' completed successfully" "DEBUG"
            
            return @{
                Success = $true
                Result = $result
                RetryCount = 0
            }
        }
        catch {
            # Register the error
            $errorInfo = Register-ParallelError -VMName $VMName -Operation $Operation -ErrorRecord $_ -ThreadId $ThreadId -Context $Context
            
            # Check if we should retry
            if (Test-ShouldRetry -VMName $VMName -Operation $Operation -ErrorRecord $_) {
                # Attempt retry
                $retryResult = Invoke-RetryOperation -VMName $VMName -Operation $Operation -ScriptBlock $ScriptBlock -Parameters $Parameters -ThreadId $ThreadId
                
                if ($retryResult.Success) {
                    Write-ThreadSafeLog "Thread $ThreadId - VM '$VMName' operation '$Operation' recovered after $($retryResult.RetryCount) retries" "INFO"
                    return $retryResult
                } else {
                    Write-ThreadSafeLog "Thread $ThreadId - VM '$VMName' operation '$Operation' failed after all retry attempts" "ERROR"
                    throw $retryResult.Error
                }
            } else {
                Write-ThreadSafeLog "Thread $ThreadId - VM '$VMName' operation '$Operation' failed with non-retryable error" "ERROR"
                throw
            }
        }
    }
    catch {
        # Final error registration
        Register-ParallelError -VMName $VMName -Operation $Operation -ErrorRecord $_ -ThreadId $ThreadId -Context $Context
        
        return @{
            Success = $false
            Error = $_
            RetryCount = $script:RetryAttempts["$VMName-$Operation"]
        }
    }
}

function Get-ParallelErrorSummary {
    <#
    .SYNOPSIS
    Generates a comprehensive summary of all parallel operation errors.
    
    .DESCRIPTION
    Analyzes collected error data to provide insights into failure patterns,
    retry statistics, and recommendations for system improvements.
    #>
    [CmdletBinding()]
    param()
    
    try {
        $errors = $script:ParallelErrors.ToArray()
        
        if ($errors.Count -eq 0) {
            Write-ThreadSafeLog "No parallel operation errors to summarize" "INFO"
            return @{
                TotalErrors = 0
                Summary = "No errors occurred during parallel operations"
            }
        }
        
        # Group errors by various dimensions
        $errorsByVM = $errors | Group-Object VMName
        $errorsByOperation = $errors | Group-Object Operation
        $errorsByCategory = $errors | Group-Object ErrorCategory
        $errorsByThread = $errors | Group-Object ThreadId
        
        # Calculate statistics
        $totalErrors = $errors.Count
        $uniqueVMs = $errorsByVM.Count
        $totalRetries = ($errors | Measure-Object RetryCount -Sum).Sum
        $avgRetriesPerError = if ($totalErrors -gt 0) { [Math]::Round($totalRetries / $totalErrors, 2) } else { 0 }
        
        # Find most problematic VMs
        $topErrorVMs = $errorsByVM | Sort-Object Count -Descending | Select-Object -First 5
        
        # Find most problematic operations
        $topErrorOperations = $errorsByOperation | Sort-Object Count -Descending | Select-Object -First 5
        
        $summary = @"
=== PARALLEL OPERATIONS ERROR SUMMARY ===
Total Errors: $totalErrors
Affected VMs: $uniqueVMs
Total Retry Attempts: $totalRetries
Average Retries per Error: $avgRetriesPerError

TOP PROBLEMATIC VMs:
$($topErrorVMs | ForEach-Object { "  $($_.Name): $($_.Count) errors" } | Out-String)

TOP PROBLEMATIC OPERATIONS:
$($topErrorOperations | ForEach-Object { "  $($_.Name): $($_.Count) errors" } | Out-String)

ERROR CATEGORIES:
$($errorsByCategory | ForEach-Object { "  $($_.Name): $($_.Count) errors" } | Out-String)

THREAD DISTRIBUTION:
$($errorsByThread | ForEach-Object { "  Thread $($_.Name): $($_.Count) errors" } | Out-String)
"@
        
        Write-ThreadSafeLog $summary "INFO"
        
        return @{
            TotalErrors = $totalErrors
            UniqueVMs = $uniqueVMs
            TotalRetries = $totalRetries
            AverageRetriesPerError = $avgRetriesPerError
            TopErrorVMs = $topErrorVMs
            TopErrorOperations = $topErrorOperations
            ErrorsByCategory = $errorsByCategory
            ErrorsByThread = $errorsByThread
            Summary = $summary
        }
    }
    catch {
        Write-ThreadSafeLog "Failed to generate parallel error summary: $_" "ERROR"
        return @{
            TotalErrors = -1
            Summary = "Failed to generate error summary: $_"
        }
    }
}

function Export-ParallelErrorReport {
    <#
    .SYNOPSIS
    Exports detailed error information to CSV for analysis.
    
    .DESCRIPTION
    Creates comprehensive error reports in CSV format for post-execution
    analysis and troubleshooting of parallel operation failures.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExportPath
    )
    
    try {
        $errors = $script:ParallelErrors.ToArray()
        
        if ($errors.Count -eq 0) {
            Write-ThreadSafeLog "No errors to export" "INFO"
            return $false
        }
        
        # Prepare error data for export
        $exportData = $errors | ForEach-Object {
            [PSCustomObject]@{
                Timestamp = $_.Timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff")
                VMName = $_.VMName
                Operation = $_.Operation
                ThreadId = $_.ThreadId
                ErrorMessage = $_.ErrorMessage
                ErrorCategory = $_.ErrorCategory
                RetryCount = $_.RetryCount
                ContextData = ($_.Context | ConvertTo-Json -Compress -ErrorAction SilentlyContinue)
                FullyQualifiedErrorId = $_.FullyQualifiedErrorId
            }
        }
        
        # Export to CSV
        $exportData | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
        
        Write-ThreadSafeLog "Exported $($errors.Count) error records to: $ExportPath" "INFO"
        return $true
    }
    catch {
        Write-ThreadSafeLog "Failed to export error report: $_" "ERROR"
        return $false
    }
}

function Reset-ErrorHandling {
    <#
    .SYNOPSIS
    Resets the error handling system for a fresh start.
    
    .DESCRIPTION
    Clears all error tracking data and retry attempts for a clean slate.
    Typically called at the beginning of a new parallel operation cycle.
    #>
    [CmdletBinding()]
    param()
    
    try {
        Write-ThreadSafeLog "Resetting error handling system" "DEBUG"
        
        # Clear error collections
        $script:ParallelErrors = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
        $script:RetryAttempts = [System.Collections.Concurrent.ConcurrentDictionary[string, int]]::new()
        
        Write-ThreadSafeLog "Error handling system reset successfully" "DEBUG"
        return $true
    }
    catch {
        Write-ThreadSafeLog "Failed to reset error handling system: $_" "ERROR"
        return $false
    }
}

#endregion

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

# Initialize VMTags 2.0 parallel processing systems
Write-Log "=== Initializing VMTags 2.0 Systems ===" "INFO"
Write-Log "Parallel Processing Enabled: $($EnableParallelProcessing.IsPresent)" "INFO"
Write-Log "Max Parallel Threads: $MaxParallelThreads" "INFO"
Write-Log "Batch Strategy: $BatchStrategy" "INFO"
Write-Log "Progress Tracking Enabled: $($EnableProgressTracking.IsPresent)" "INFO"
Write-Log "Error Handling Enabled: $($EnableErrorHandling.IsPresent)" "INFO"

if ($EnableParallelProcessing) {
    # Initialize parallel processing systems
    Write-Log "Initializing parallel processing infrastructure..." "INFO"
    
    # Initialize thread-safe logging
    try {
        Initialize-ThreadSafeLogging
        Write-Log "Thread-safe logging system initialized" "INFO"
    }
    catch {
        Write-Log "Failed to initialize thread-safe logging: $_" "ERROR"
        $EnableParallelProcessing = $false
    }
    
    # Initialize error handling if enabled
    if ($EnableErrorHandling) {
        try {
            # Set global error handling parameters
            $script:MaxRetries = $MaxOperationRetries
            $script:RetryDelaySeconds = $RetryDelaySeconds
            
            Initialize-ErrorHandling
            Write-Log "Error handling system initialized (Max Retries: $MaxOperationRetries, Delay: $RetryDelaySeconds sec)" "INFO"
        }
        catch {
            Write-Log "Failed to initialize error handling: $_" "ERROR"
            $EnableErrorHandling = $false
        }
    }
    
    # Initialize progress tracking if enabled
    if ($EnableProgressTracking) {
        try {
            Write-Log "Progress tracking system will be started during VM processing" "INFO"
        }
        catch {
            Write-Log "Failed to prepare progress tracking: $_" "ERROR"
            $EnableProgressTracking = $false
        }
    }
    
    Write-Log "VMTags 2.0 systems initialization completed successfully" "INFO"
} else {
    Write-Log "Running in sequential mode (parallel processing disabled)" "INFO"
}

Write-Log "=== VMTags 2.0 Initialization Complete ===" "INFO"
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
    param([string]$CategoryName, [string]$Description = "Managed by script", [string]$Cardinality = "MULTIPLE", [string[]]$EntityType = @("VirtualMachine"))
    $existingCat = Get-TagCategory -Name $CategoryName -ErrorAction SilentlyContinue
    if ($existingCat) { return $existingCat }
    Write-Log "Category '$($CategoryName)' not found, creating..." "INFO"
    try {
        return New-TagCategory -Name $CategoryName -Description $Description -Cardinality $Cardinality -EntityType $EntityType -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to create category '$($CategoryName)': $_" "ERROR"
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
        # If creation fails, check if tag was created by another process (race condition)
        Write-Log "Tag creation failed, checking if tag now exists: $_" "WARN"
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
        $role = Get-VIRole -Name $RoleName -ErrorAction SilentlyContinue
        if (-not $role) {
            $role = Clone-RoleFromSupportAdminTemplate -NewRoleName $RoleName
        }
        if (-not $role) { 
            throw "Could not find or create role '$($RoleName)'." 
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
        
        # Check for conflicting permissions (same principal, different role)
        $conflictingPermission = $existingPermissions | Where-Object {
            $_.Principal -eq $Principal -and $_.Role -ne $RoleName
        }
        
        if ($conflictingPermission) {
            Write-Log "WARNING: Conflicting permission found for VM='$($VM.Name)', Principal='$($Principal)'. Existing Role='$($conflictingPermission.Role)', New Role='$($RoleName)'" "WARN"
            # You can choose to skip or replace - for now we'll skip
            return @{
                Action = "Skipped"
                Reason = "Conflicting permission exists"
                Principal = $Principal
                ExistingRole = $conflictingPermission.Role
                RequestedRole = $RoleName
            }
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
            Write-Log "    Error: $errorMessage" "WARN"
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
            Write-Log "Permission analysis progress: $totalChecked/$($VMs.Count) VMs checked" "INFO"
        }
    }
    
    # Generate summary report
    Write-Log "=== Permission Analysis Summary ===" "INFO"
    Write-Log "Total VMs Analyzed: $totalChecked" "INFO"
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
                Write-Log "No OS mapping data found in $OsMappingCsvPath - skipping OS tag assignment for inherited VMs" "WARN"
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
                            Write-Log "Inherited VM '$($vm.Name)' did not match any OS patterns. Available OS info: $osNames" "WARN"
                            $inheritedVMsOSSkipped++
                        }
                    }
                    catch {
                        Write-Log "Error processing inherited VM '$($vmRecord.VMName)' for OS tagging: $_" "ERROR"
                        $inheritedVMsOSSkipped++
                    }
                }
                
                Write-Log "OS tag processing for inherited VMs completed: $inheritedVMsOSTagged tagged, $inheritedVMsOSSkipped skipped" "INFO"
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
            Write-Log "VMs with only inherited permissions saved to: $inheritedOnlyReport" "INFO"
        }
        
        if ($vmsWithoutPermissions.Count -gt 0) {
            $noPermissionsReport = Join-Path $script:reportsFolder "VMsWithNoPermissions_$($Environment)_$timestamp.csv"
            $vmsWithoutPermissions | Export-Csv -Path $noPermissionsReport -NoTypeInformation
            Write-Log "VMs with no permissions saved to: $noPermissionsReport" "INFO"
        }
        
        if ($vmsWithExplicit.Count -gt 0) {
            $explicitPermissionsReport = Join-Path $script:reportsFolder "VMsWithExplicitPermissions_$($Environment)_$timestamp.csv"
            $vmsWithExplicit | Export-Csv -Path $explicitPermissionsReport -NoTypeInformation
            Write-Log "VMs with explicit permissions saved to: $explicitPermissionsReport" "INFO"
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
    
    if (-not (Test-Path $AppPermissionsCsvPath)) { 
        throw "Application Permissions CSV not found: $AppPermissionsCsvPath" 
    }
    if (-not (Test-Path $OsMappingCsvPath)) { 
        throw "OS Mapping CSV not found: $OsMappingCsvPath" 
    }
    
    $appPermissionData = Import-Csv -Path $AppPermissionsCsvPath
    $osMappingData = Import-Csv -Path $OsMappingCsvPath
    
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
    $osCat = Ensure-TagCategory -CategoryName $OsCategoryName -EntityType @("VirtualMachine", "HostSystem")
    
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
    
    # --- Processing Part 1: Application Permissions ---
    Write-Log "=== Processing Application Permissions from $($AppPermissionsCsvPath) ===" "INFO"
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
            Write-Log "Skipping App row with non-matching category: '$($row.TagCategory)' (expected: '$AppCategoryName')" "INFO"
        }
        
        # Progress reporting
        if ($appRowsProcessed % 10 -eq 0) {
            Write-Log "App permissions progress: $appRowsProcessed/$($appPermissionData.Count) rows processed" "INFO"
        }
    }
    
    Write-Log "App Permissions Summary: $appRowsProcessed rows processed, $appTagsCreated tags created, $appPermissionsProcessed permissions assigned" "INFO"
    
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
    
    Write-Log "Pre-created $osTagsCreated OS tags" "INFO"
    
    # Get all VMs for OS processing - excluding system and control VMs
    Write-Log "Getting all VMs for OS processing (excluding vCLS*, VLC*, stCtlVM* VMs)..." "DEBUG"
    $allVms = Get-VM | Where-Object Name -notmatch '^(vCLS|VLC|stCtlVM)'
    Write-Log "Found $($allVms.Count) VMs to check for OS patterns (after filtering system VMs)." "INFO"
    
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
                        
                        switch ($result.Action) {
                            "Created" { 
                                $osPermissionCount++
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
            Write-Log "VM '$($vm.Name)' did not match any OS patterns. Available OS info: $osNames" "WARN"
            $osSkippedCount++
            $script:ExecutionSummary.VMsSkipped++
        }
        
        # Progress reporting
        if ($osProcessedCount % 25 -eq 0) {
            Write-Log "OS processing progress: $osProcessedCount/$($allVms.Count) VMs (Tagged: $osTaggedCount, Permissions: $osPermissionCount, Skipped: $osSkippedCount)" "INFO"
        }
    }
    
    Write-Log "OS Processing Complete - Total VMs: $($allVms.Count), Processed: $osProcessedCount, Tagged: $osTaggedCount, Permissions Assigned: $osPermissionCount, Skipped: $osSkippedCount" "INFO"
    
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
                    Write-Log "Inherited VM '$($vm.Name)' did not match any OS patterns. Available OS info: $osNames" "WARN"
                    $inheritedVMsOSSkipped++
                }
            }
            catch {
                Write-Log "Error processing inherited VM '$($vmRecord.VMName)' for OS tagging: $_" "ERROR"
                $inheritedVMsOSSkipped++
                $script:ExecutionSummary.ErrorsEncountered++
            }
        }
        
        Write-Log "OS tag processing for inherited VMs completed: $inheritedVMsOSTagged tagged, $inheritedVMsOSSkipped skipped" "INFO"
    }
    
    # --- Generate Final Reports and Summary ---
    Write-Log "=== Generating Final Reports and Summary ===" "INFO"
    
    # Calculate final statistics
    $totalPermissionsAssigned = ($script:PermissionResults | Where-Object { $_.Action -eq "Created" }).Count
    $totalPermissionsSkipped = ($script:PermissionResults | Where-Object { $_.Action -eq "Skipped" }).Count
    $totalPermissionsFailed = ($script:PermissionResults | Where-Object { $_.Action -eq "Failed" }).Count
    
    # Generate comprehensive execution summary
    Write-Log "=== FINAL EXECUTION SUMMARY ===" "INFO"
    Write-Log "Environment: $Environment" "INFO"
    Write-Log "vCenter Server: $vCenterServer" "INFO"
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
    Write-Log "Permissions Successfully Assigned: $totalPermissionsAssigned" "INFO"
    Write-Log "Permissions Skipped (duplicates/conflicts): $totalPermissionsSkipped" "INFO"
    Write-Log "Permission Assignment Failures: $totalPermissionsFailed" "INFO"
    Write-Log "=== Permission Analysis Results ===" "INFO"
    Write-Log "VMs with Explicit Permissions: $($permissionAnalysis.WithExplicit.Count)" "INFO"
    Write-Log "VMs with Only Inherited Permissions: $($permissionAnalysis.OnlyInherited.Count)" "INFO"
    Write-Log "VMs with No Permissions: $($permissionAnalysis.WithoutPermissions.Count)" "INFO"
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
    
    Write-Log "=== OVERALL STATUS: $executionStatus ===" "INFO"
    
   # --- Save Detailed Reports ---
Write-Log "=== Saving Detailed Reports ===" "INFO"

try {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    
    # Save permission assignment results
    if ($script:PermissionResults.Count -gt 0) {
        $permissionResultsReport = Join-Path $script:reportsFolder "PermissionAssignmentResults_$($Environment)_$timestamp.csv"
        $script:PermissionResults | Export-Csv -Path $permissionResultsReport -NoTypeInformation
        Write-Log "Permission assignment results saved to: $permissionResultsReport" "INFO"
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
    Write-Log "Execution summary saved to: $summaryReport" "INFO"
    
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
        Write-Log "VMs needing attention saved to: $attentionReport" "INFO"
        Write-Log "ATTENTION: $($vmsNeedingAttention.Count) VMs require manual review for permissions" "WARN"
    }
    
    Write-Log "All reports saved successfully to: $script:reportsFolder" "INFO"
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
    
    # Reset PowerCLI certificate policy
    try { 
        Set-PowerCLIConfiguration -InvalidCertificateAction Warn -Confirm:$false | Out-Null 
        Write-Log "PowerCLI certificate policy reset to Warn." "INFO"
    }
    catch { 
        Write-Log "Failed to reset certificate policy: $_" "WARN" 
    }
    
    Write-Log "Script execution finished." "INFO"
    Write-Log "Log files saved to: $script:logFolder" "INFO"
    Write-Log "Report files saved to: $script:reportsFolder" "INFO"
    
    # Display quick summary to console
    Write-Host "`n=== QUICK SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Permissions Assigned: $totalPermissionsAssigned" -ForegroundColor Green
    Write-Host "Permissions Skipped: $totalPermissionsSkipped" -ForegroundColor Yellow
    Write-Host "Permission Failures: $totalPermissionsFailed" -ForegroundColor Red
    Write-Host "VMs Needing Attention: $($vmsNeedingAttention.Count)" -ForegroundColor Yellow
    Write-Host "Check logs for detailed results: $script:logFolder" -ForegroundColor White
    Write-Host "Check reports for CSV exports: $script:reportsFolder" -ForegroundColor White
}
#endregion