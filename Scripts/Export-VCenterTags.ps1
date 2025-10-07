<#
.SYNOPSIS
    Export all vCenter tag categories and tags to a backup file

.DESCRIPTION
    This script exports all tag categories and tags from a vCenter server to a JSON file.
    The exported file can be used to restore tags to the same vCenter or import into a different vCenter.

    Exports include:
    - Tag Category properties (Name, Description, Cardinality, EntityType)
    - Tag properties (Name, Description, Category)
    - Complete metadata for accurate restoration

.PARAMETER vCenterServer
    The vCenter server to connect to and export tags from

.PARAMETER Credential
    PSCredential object for vCenter authentication. If not provided, will prompt for credentials.

.PARAMETER OutputPath
    Path where the JSON export file will be saved. Default is current directory with timestamp.

.PARAMETER IncludeUsage
    Include tag usage information (which VMs/objects have each tag assigned).
    WARNING: This can significantly increase export time and file size in large environments.

.PARAMETER ExcludeSystemCategories
    Exclude system-managed tag categories from the export (categories starting with "urn:").

.EXAMPLE
    .\Export-VCenterTags.ps1 -vCenterServer "vcenter.domain.com"

    Exports all tags and categories from vcenter.domain.com to a timestamped JSON file.

.EXAMPLE
    .\Export-VCenterTags.ps1 -vCenterServer "vcenter.domain.com" -OutputPath "C:\Backup\vcenter-tags.json"

    Exports tags to a specific file path.

.EXAMPLE
    .\Export-VCenterTags.ps1 -vCenterServer "vcenter.domain.com" -IncludeUsage

    Exports tags including usage information (which objects have each tag assigned).

.EXAMPLE
    $cred = Get-Credential
    .\Export-VCenterTags.ps1 -vCenterServer "vcenter.domain.com" -Credential $cred -ExcludeSystemCategories

    Exports tags using stored credentials and excludes system categories.

.NOTES
    Requires VMware PowerCLI 12.0 or later
    Requires appropriate permissions to read tags in vCenter
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "vCenter server to export tags from")]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false, HelpMessage = "Credential for vCenter authentication")]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false, HelpMessage = "Path for the export file")]
    [string]$OutputPath,

    [Parameter(Mandatory = $false, HelpMessage = "Include tag usage information (slower)")]
    [switch]$IncludeUsage,

    [Parameter(Mandatory = $false, HelpMessage = "Exclude system-managed tag categories")]
    [switch]$ExcludeSystemCategories
)

# Function to write log messages
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }

    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Function to check PowerCLI module
function Test-PowerCLIModule {
    try {
        if (-not (Get-Module -Name VMware.PowerCLI -ListAvailable)) {
            Write-Log "VMware PowerCLI module not found. Please install it first:" -Level Error
            Write-Log "Install-Module -Name VMware.PowerCLI -Scope CurrentUser" -Level Error
            return $false
        }

        # Import required modules
        $modulesToImport = @(
            'VMware.VimAutomation.Core',
            'VMware.VimAutomation.Cis.Core'
        )

        foreach ($module in $modulesToImport) {
            if (-not (Get-Module -Name $module)) {
                Import-Module $module -ErrorAction Stop
                Write-Log "Imported module: $module" -Level Info
            }
        }

        return $true
    }
    catch {
        Write-Log "Failed to load PowerCLI modules: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Main script execution
try {
    Write-Log "========================================" -Level Info
    Write-Log "vCenter Tag Export Utility" -Level Info
    Write-Log "========================================" -Level Info
    Write-Log "" -Level Info

    # Check PowerCLI
    Write-Log "Checking PowerCLI modules..." -Level Info
    if (-not (Test-PowerCLIModule)) {
        exit 1
    }

    # Set PowerCLI configuration
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
    Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null

    # Generate default output path if not specified
    if ([string]::IsNullOrEmpty($OutputPath)) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $OutputPath = Join-Path (Get-Location) "VCenterTags_Export_${timestamp}.json"
    }

    # Ensure output directory exists
    $outputDir = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrEmpty($outputDir) -and -not (Test-Path $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        Write-Log "Created output directory: $outputDir" -Level Info
    }

    Write-Log "Export file will be saved to: $OutputPath" -Level Info
    Write-Log "" -Level Info

    # Connect to vCenter
    Write-Log "Connecting to vCenter: $vCenterServer" -Level Info

    $connectParams = @{
        Server = $vCenterServer
        ErrorAction = 'Stop'
    }

    if ($Credential) {
        $connectParams.Credential = $Credential
    }

    $connection = Connect-VIServer @connectParams
    Write-Log "Successfully connected to $vCenterServer" -Level Success
    Write-Log "" -Level Info

    # Export tag categories
    Write-Log "Exporting tag categories..." -Level Info
    $tagCategories = Get-TagCategory -Server $connection

    if ($ExcludeSystemCategories) {
        $originalCount = $tagCategories.Count
        $tagCategories = $tagCategories | Where-Object { $_.Name -notmatch '^urn:' }
        $excludedCount = $originalCount - $tagCategories.Count
        Write-Log "Excluded $excludedCount system tag categories" -Level Info
    }

    Write-Log "Found $($tagCategories.Count) tag categories" -Level Success

    $exportedCategories = @()
    foreach ($category in $tagCategories) {
        $categoryData = [PSCustomObject]@{
            Name = $category.Name
            Description = $category.Description
            Cardinality = $category.Cardinality.ToString()
            EntityType = @($category.EntityType)
            Id = $category.Id
        }

        $exportedCategories += $categoryData
        Write-Log "  - Category: $($category.Name) (Cardinality: $($category.Cardinality), Types: $($category.EntityType -join ', '))" -Level Info
    }

    Write-Log "" -Level Info

    # Export tags
    Write-Log "Exporting tags..." -Level Info
    $allTags = Get-Tag -Server $connection

    if ($ExcludeSystemCategories) {
        $categoryNames = $exportedCategories | Select-Object -ExpandProperty Name
        $originalCount = $allTags.Count
        $allTags = $allTags | Where-Object { $_.Category.Name -in $categoryNames }
        $excludedCount = $originalCount - $allTags.Count
        Write-Log "Excluded $excludedCount tags from system categories" -Level Info
    }

    Write-Log "Found $($allTags.Count) tags" -Level Success

    $exportedTags = @()
    foreach ($tag in $allTags) {
        $tagData = [PSCustomObject]@{
            Name = $tag.Name
            Description = $tag.Description
            CategoryName = $tag.Category.Name
            Id = $tag.Id
        }

        # Include usage information if requested
        if ($IncludeUsage) {
            $assignments = Get-TagAssignment -Tag $tag -Server $connection
            $tagData | Add-Member -MemberType NoteProperty -Name 'AssignmentCount' -Value $assignments.Count

            # Store entity types that have this tag
            $entityTypes = $assignments | Select-Object -ExpandProperty Entity |
                           ForEach-Object { $_.GetType().Name } |
                           Select-Object -Unique
            $tagData | Add-Member -MemberType NoteProperty -Name 'AssignedEntityTypes' -Value @($entityTypes)
        }

        $exportedTags += $tagData
        Write-Log "  - Tag: $($tag.Name) (Category: $($tag.Category.Name))" -Level Info
    }

    Write-Log "" -Level Info

    # Build export object
    $exportData = [PSCustomObject]@{
        ExportMetadata = [PSCustomObject]@{
            ExportDate = Get-Date -Format "o"
            SourceVCenter = $vCenterServer
            PowerCLIVersion = (Get-Module VMware.VimAutomation.Core).Version.ToString()
            ExportedBy = $env:USERNAME
            IncludesUsageData = $IncludeUsage.IsPresent
            ExcludedSystemCategories = $ExcludeSystemCategories.IsPresent
        }
        Statistics = [PSCustomObject]@{
            TotalCategories = $exportedCategories.Count
            TotalTags = $exportedTags.Count
        }
        TagCategories = $exportedCategories
        Tags = $exportedTags
    }

    # Export to JSON
    Write-Log "Writing export file..." -Level Info
    $jsonContent = $exportData | ConvertTo-Json -Depth 10
    $jsonContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

    $fileSize = (Get-Item $OutputPath).Length / 1KB
    Write-Log "Export completed successfully!" -Level Success
    Write-Log "File: $OutputPath" -Level Success
    Write-Log "Size: $([math]::Round($fileSize, 2)) KB" -Level Success
    Write-Log "" -Level Info

    # Display summary
    Write-Log "========================================" -Level Info
    Write-Log "Export Summary" -Level Info
    Write-Log "========================================" -Level Info
    Write-Log "Tag Categories: $($exportedCategories.Count)" -Level Info
    Write-Log "Tags: $($exportedTags.Count)" -Level Info

    if ($IncludeUsage) {
        $totalAssignments = ($exportedTags | Measure-Object -Property AssignmentCount -Sum).Sum
        Write-Log "Total Tag Assignments: $totalAssignments" -Level Info
    }

    Write-Log "" -Level Info
    Write-Log "To import these tags to another vCenter, use Import-VCenterTags.ps1" -Level Info

    # Disconnect from vCenter
    Disconnect-VIServer -Server $connection -Confirm:$false
    Write-Log "Disconnected from vCenter" -Level Info

    exit 0
}
catch {
    Write-Log "Export failed: $($_.Exception.Message)" -Level Error
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level Error

    # Disconnect if connected
    if ($connection) {
        Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
    }

    exit 1
}
