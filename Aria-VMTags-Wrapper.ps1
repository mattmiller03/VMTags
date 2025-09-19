<#
.SYNOPSIS
    Aria Operations wrapper for VM Tags and Permissions automation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('DEV', 'PROD', 'KLEB', 'OT')]
    [string]$Environment,
    
    [Parameter(Mandatory = $false)]
    [string]$vCenterServer,
    
    [Parameter(Mandatory = $false)]
    [switch]$EnableDebug
)

#region Aria Operations Functions
function Write-AriaLog {
    <#
    .SYNOPSIS
        Writes log entries in Aria Operations compatible format
    .PARAMETER Message
        Log message
    .PARAMETER Level
        Log level (INFO, WARNING, ERROR, SUCCESS)
    .PARAMETER Category
        Log category for Aria classification
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = "INFO",
        
        [Parameter(Mandatory = $false)]
        [string]$Category = "VMTags-Automation"
    )
    
    $ariaLogEntry = @{
        Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
        Level = $Level
        Source = $Category
        Environment = if ($script:Environment) { $script:Environment } else { "Unknown" }
        Message = $Message
        Machine = $env:COMPUTERNAME
        User = $env:USERNAME
        ProcessId = $PID
        ScriptName = Split-Path -Leaf $MyInvocation.PSCommandPath
    }
    
    # Output for Aria Operations to parse
    try {
        $jsonLog = $ariaLogEntry | ConvertTo-Json -Compress -ErrorAction Stop
        Write-Host $jsonLog
    }
    catch {
        # Fallback to simple logging if JSON conversion fails
        Write-Host "[$Level] $Message"
        Write-Warning "Aria JSON conversion failed: $($_.Exception.Message)"
    }
    
    # Also write to Aria-specific log file
    try {
        # Use dynamic log path instead of hardcoded path
        $ariaLogPath = if ($script:AriaConfig -and $script:AriaConfig.LogPath) {
            $script:AriaConfig.LogPath
        } else {
            Join-Path $PSScriptRoot "Logs\Aria"
        }
        $ariaLogFile = Join-Path $ariaLogPath "AriaOperations_$($script:Environment).log"
        $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
        Add-Content -Path $ariaLogFile -Value $logLine -ErrorAction SilentlyContinue
    }
    catch {
        # Ignore file logging errors in Aria context
    }
}

function Write-AriaResult {
    <#
    .SYNOPSIS
        Writes execution results in Aria Operations format
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Result
    )
    
    $ariaResult = @{
        Timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffZ"
        Environment = if ($script:Environment) { $script:Environment } else { "Unknown" }
        ExecutionStatus = if ($Result.ExitCode -eq 0) { "SUCCESS" } else { "FAILED" }
        ExitCode = if ($Result.ExitCode) { $Result.ExitCode } else { -1 }
        ExecutionTime = if ($Result.ExecutionTime) { $Result.ExecutionTime.ToString() } else { "Unknown" }
        Machine = $env:COMPUTERNAME
        User = $env:USERNAME
        Details = @{
            vCenterServer = if ($script:vCenterServer) { $script:vCenterServer } else { "Default" }
            ConfigPath = if ($script:AriaConfig.ConfigPath) { $script:AriaConfig.ConfigPath } else { "Unknown" }
            LauncherScript = if ($script:AriaConfig.LauncherScript) { $script:AriaConfig.LauncherScript } else { "Unknown" }
        }
    }
    
    # Output structured result for Aria
    try {
        $jsonResult = $ariaResult | ConvertTo-Json -Compress -ErrorAction Stop
        Write-Host "ARIA_RESULT: $jsonResult"
    }
    catch {
        # Fallback to simple result if JSON conversion fails
        Write-Host "ARIA_RESULT: Status=$($ariaResult.ExecutionStatus), ExitCode=$($ariaResult.ExitCode)"
        Write-Warning "Aria result JSON conversion failed: $($_.Exception.Message)"
    }
}
#endregion

#region Main Execution
$script:Environment = $Environment

# Get script directory for relative path calculations
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Aria Operations specific settings
$script:AriaConfig = @{
    LauncherScript = Join-Path $scriptRoot "VM_TagPermissions_Launcher.ps1"  # Fixed: was _v2, should be current filename
    ConfigPath = Join-Path $scriptRoot "ConfigFiles"
    LogPath = Join-Path $scriptRoot "Logs\Aria"
    TempPath = Join-Path $scriptRoot "Temp"
}

try {
    Write-AriaLog "Aria Operations VM Tags automation started" -Level "INFO"
    Write-AriaLog "PowerShell Version: $($PSVersionTable.PSVersion)" -Level "INFO"
    Write-AriaLog "Target Environment: $Environment" -Level "INFO"
    
    if ($vCenterServer) {
        Write-AriaLog "vCenter Override: $vCenterServer" -Level "INFO"
    }
    
    # Ensure required directories exist
    @($script:AriaConfig.LogPath, $script:AriaConfig.TempPath) | ForEach-Object {
        if (-not (Test-Path $_)) {
            New-Item -Path $_ -ItemType Directory -Force | Out-Null
            Write-AriaLog "Created directory: $_" -Level "INFO"
        }
    }

    # Check if launcher script exists
    if (-not (Test-Path $script:AriaConfig.LauncherScript)) {
        Write-AriaLog "Launcher script not found: $($script:AriaConfig.LauncherScript)" -Level "ERROR"
        throw "Launcher script not found: $($script:AriaConfig.LauncherScript)"
    }
    
    # Build launcher arguments using hashtable for proper splatting
    $launcherArgs = @{
        Environment = $Environment
        ConfigPath = $script:AriaConfig.ConfigPath
        UseStoredCredentials = $true  # Always use stored credentials in Aria Operations
        AutomationMode = $true  # Enable automation mode for Aria Operations
    }

    if ($vCenterServer) {
        $launcherArgs.OverrideVCenter = $vCenterServer
    }

    if ($EnableDebug) {
        $launcherArgs.ForceDebug = $true
    }

    # Log the command being executed
    $argString = ($launcherArgs.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
    Write-AriaLog "Launching VM Tags automation with args: $argString" -Level "INFO"

    # Set environment variables to suppress interactive prompts
    $env:AUTOMATION_MODE = "ARIA_OPERATIONS"
    $env:NO_PAUSE = "1"
    $env:ARIA_EXECUTION = "1"

    # Ensure we're running non-interactively
    $env:POWERSHELL_TELEMETRY_OPTOUT = "1"
    $env:POWERSHELL_INTERACTIVE = "0"

    # Override functions that might cause interactive prompts
    function Wait-ForUserInput {
        param([string]$Message = "Press any key to exit...")
        Write-AriaLog "Skipping user interaction in Aria Operations: $Message" -Level "INFO"
        # Do nothing - just return immediately
    }

    function Read-Host {
        param([string]$Prompt)
        Write-AriaLog "Skipping Read-Host prompt in Aria Operations: $Prompt" -Level "INFO"
        return "N"  # Default to "No" for any yes/no prompts
    }

    # Execute the launcher script with proper splatting
    $result = & $script:AriaConfig.LauncherScript @launcherArgs
    
    # Process results
    if ($result -and $result.ExitCode -ne $null) {
        Write-AriaResult -Result $result
        
        if ($result.ExitCode -eq 0) {
            Write-AriaLog "VM Tags automation completed successfully" -Level "SUCCESS"
        } else {
            Write-AriaLog "VM Tags automation completed with errors (Exit Code: $($result.ExitCode))" -Level "WARNING"
        }
    } else {
        Write-AriaLog "VM Tags automation completed (no result object returned)" -Level "INFO"
    }
    
    return $result
}
catch {
    Write-AriaLog "FATAL ERROR: $($_.Exception.Message)" -Level "ERROR"
    Write-AriaLog "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    
    # Write error result for Aria
    $errorResult = @{
        ExitCode = 1
        ExecutionTime = "ERROR"
        ErrorMessage = $_.Exception.Message
    }
    Write-AriaResult -Result $errorResult
    
    throw
}
#endregion