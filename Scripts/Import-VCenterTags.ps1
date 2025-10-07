<#
.SYNOPSIS
    Import vCenter tag categories and tags from a backup file

.DESCRIPTION
    This script imports tag categories and tags into a vCenter server from a JSON export file
    created by Export-VCenterTags.ps1.

    The script will:
    - Create missing tag categories with their original properties
    - Create missing tags under the correct categories
    - Skip existing categories/tags (no duplicates)
    - Optionally update existing categories/tags with new properties
    - Provide detailed reporting of import actions

.PARAMETER vCenterServer
    The vCenter server to connect to and import tags into

.PARAMETER Credential
    PSCredential object for vCenter authentication. If not provided, will prompt for credentials.

.PARAMETER ImportPath
    Path to the JSON export file created by Export-VCenterTags.ps1

.PARAMETER UpdateExisting
    If specified, update existing tag categories and tags with properties from the import file.
    By default, existing objects are skipped.

.PARAMETER DryRun
    Perform validation and show what would be imported without making any changes.

.PARAMETER Force
    Skip confirmation prompts and proceed with import automatically.

.EXAMPLE
    .\Import-VCenterTags.ps1 -vCenterServer "vcenter-new.domain.com" -ImportPath "C:\Backup\VCenterTags_Export_20250107.json"

    Imports tags from the backup file into vcenter-new.domain.com

.EXAMPLE
    .\Import-VCenterTags.ps1 -vCenterServer "vcenter.domain.com" -ImportPath "tags.json" -DryRun

    Shows what would be imported without making any changes (validation only)

.EXAMPLE
    .\Import-VCenterTags.ps1 -vCenterServer "vcenter.domain.com" -ImportPath "tags.json" -UpdateExisting

    Imports tags and updates any existing categories/tags with new properties from the file

.EXAMPLE
    $cred = Get-Credential
    .\Import-VCenterTags.ps1 -vCenterServer "vcenter.domain.com" -ImportPath "tags.json" -Credential $cred -Force

    Imports tags using stored credentials without confirmation prompts

.NOTES
    Requires VMware PowerCLI 12.0 or later
    Requires appropriate permissions to create/modify tags in vCenter
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "vCenter server to import tags into")]
    [string]$vCenterServer,

    [Parameter(Mandatory = $false, HelpMessage = "Credential for vCenter authentication")]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $true, HelpMessage = "Path to the import file")]
    [string]$ImportPath,

    [Parameter(Mandatory = $false, HelpMessage = "Update existing categories and tags")]
    [switch]$UpdateExisting,

    [Parameter(Mandatory = $false, HelpMessage = "Validation only - don't make changes")]
    [switch]$DryRun,

    [Parameter(Mandatory = $false, HelpMessage = "Skip confirmation prompts")]
    [switch]$Force
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
    Write-Log "vCenter Tag Import Utility" -Level Info
    Write-Log "========================================" -Level Info
    Write-Log "" -Level Info

    if ($DryRun) {
        Write-Log "DRY RUN MODE - No changes will be made" -Level Warning
        Write-Log "" -Level Warning
    }

    # Check PowerCLI
    Write-Log "Checking PowerCLI modules..." -Level Info
    if (-not (Test-PowerCLIModule)) {
        exit 1
    }

    # Set PowerCLI configuration
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
    Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false -Scope Session | Out-Null

    # Validate import file exists
    if (-not (Test-Path $ImportPath)) {
        Write-Log "Import file not found: $ImportPath" -Level Error
        exit 1
    }

    Write-Log "Loading import file: $ImportPath" -Level Info

    # Load and parse JSON
    $importData = Get-Content -Path $ImportPath -Raw | ConvertFrom-Json

    # Validate import file structure
    if (-not $importData.TagCategories -or -not $importData.Tags) {
        Write-Log "Invalid import file format. Missing TagCategories or Tags sections." -Level Error
        exit 1
    }

    # Display import file metadata
    Write-Log "" -Level Info
    Write-Log "Import File Metadata:" -Level Info
    Write-Log "  Source vCenter: $($importData.ExportMetadata.SourceVCenter)" -Level Info
    Write-Log "  Export Date: $($importData.ExportMetadata.ExportDate)" -Level Info
    Write-Log "  Exported By: $($importData.ExportMetadata.ExportedBy)" -Level Info
    Write-Log "  Categories: $($importData.Statistics.TotalCategories)" -Level Info
    Write-Log "  Tags: $($importData.Statistics.TotalTags)" -Level Info
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

    # Get existing categories and tags
    Write-Log "Reading existing tags from vCenter..." -Level Info
    $existingCategories = Get-TagCategory -Server $connection
    $existingTags = Get-Tag -Server $connection
    Write-Log "Found $($existingCategories.Count) existing categories and $($existingTags.Count) existing tags" -Level Info
    Write-Log "" -Level Info

    # Confirm import if not in Force mode
    if (-not $Force -and -not $DryRun) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "Ready to import:" -ForegroundColor Yellow
        Write-Host "  $($importData.Statistics.TotalCategories) tag categories" -ForegroundColor Yellow
        Write-Host "  $($importData.Statistics.TotalTags) tags" -ForegroundColor Yellow
        Write-Host "" -ForegroundColor Yellow
        $confirmation = Read-Host "Proceed with import? (Y/N)"
        if ($confirmation -ne 'Y') {
            Write-Log "Import cancelled by user" -Level Warning
            Disconnect-VIServer -Server $connection -Confirm:$false
            exit 0
        }
        Write-Log "" -Level Info
    }

    # Import counters
    $stats = @{
        CategoriesCreated = 0
        CategoriesUpdated = 0
        CategoriesSkipped = 0
        CategoriesFailed = 0
        TagsCreated = 0
        TagsUpdated = 0
        TagsSkipped = 0
        TagsFailed = 0
    }

    # Import tag categories
    Write-Log "Importing tag categories..." -Level Info
    foreach ($category in $importData.TagCategories) {
        try {
            $existingCategory = $existingCategories | Where-Object { $_.Name -eq $category.Name }

            if ($existingCategory) {
                if ($UpdateExisting -and -not $DryRun) {
                    # Update existing category
                    $updateParams = @{}
                    if ($category.Description -ne $existingCategory.Description) {
                        $updateParams.Description = $category.Description
                    }
                    if ($category.Cardinality -ne $existingCategory.Cardinality.ToString()) {
                        $updateParams.Cardinality = $category.Cardinality
                    }

                    if ($updateParams.Count -gt 0) {
                        Set-TagCategory -TagCategory $existingCategory @updateParams -Confirm:$false | Out-Null
                        Write-Log "  ✓ Updated category: $($category.Name)" -Level Success
                        $stats.CategoriesUpdated++
                    } else {
                        Write-Log "  ○ Category unchanged: $($category.Name)" -Level Info
                        $stats.CategoriesSkipped++
                    }
                } else {
                    Write-Log "  ○ Category already exists: $($category.Name)" -Level Info
                    $stats.CategoriesSkipped++
                }
            } else {
                # Create new category
                if (-not $DryRun) {
                    $createParams = @{
                        Name = $category.Name
                        Cardinality = $category.Cardinality
                        Server = $connection
                        Confirm = $false
                    }

                    if (-not [string]::IsNullOrEmpty($category.Description)) {
                        $createParams.Description = $category.Description
                    }

                    if ($category.EntityType -and $category.EntityType.Count -gt 0) {
                        $createParams.EntityType = $category.EntityType
                    }

                    $newCategory = New-TagCategory @createParams
                    Write-Log "  ✓ Created category: $($category.Name)" -Level Success
                } else {
                    Write-Log "  [DRY RUN] Would create category: $($category.Name)" -Level Info
                }
                $stats.CategoriesCreated++
            }
        }
        catch {
            Write-Log "  ✗ Failed to process category '$($category.Name)': $($_.Exception.Message)" -Level Error
            $stats.CategoriesFailed++
        }
    }

    Write-Log "" -Level Info

    # Refresh category list after import
    if (-not $DryRun) {
        $existingCategories = Get-TagCategory -Server $connection
    }

    # Import tags
    Write-Log "Importing tags..." -Level Info
    foreach ($tag in $importData.Tags) {
        try {
            $existingTag = $existingTags | Where-Object { $_.Name -eq $tag.Name -and $_.Category.Name -eq $tag.CategoryName }

            if ($existingTag) {
                if ($UpdateExisting -and -not $DryRun) {
                    # Update existing tag
                    if ($tag.Description -ne $existingTag.Description) {
                        Set-Tag -Tag $existingTag -Description $tag.Description -Confirm:$false | Out-Null
                        Write-Log "  ✓ Updated tag: $($tag.Name) (Category: $($tag.CategoryName))" -Level Success
                        $stats.TagsUpdated++
                    } else {
                        Write-Log "  ○ Tag unchanged: $($tag.Name) (Category: $($tag.CategoryName))" -Level Info
                        $stats.TagsSkipped++
                    }
                } else {
                    Write-Log "  ○ Tag already exists: $($tag.Name) (Category: $($tag.CategoryName))" -Level Info
                    $stats.TagsSkipped++
                }
            } else {
                # Find the category for this tag
                $targetCategory = $existingCategories | Where-Object { $_.Name -eq $tag.CategoryName }

                if (-not $targetCategory) {
                    Write-Log "  ✗ Category not found for tag '$($tag.Name)': $($tag.CategoryName)" -Level Error
                    $stats.TagsFailed++
                    continue
                }

                # Create new tag
                if (-not $DryRun) {
                    $createParams = @{
                        Name = $tag.Name
                        Category = $targetCategory
                        Server = $connection
                        Confirm = $false
                    }

                    if (-not [string]::IsNullOrEmpty($tag.Description)) {
                        $createParams.Description = $tag.Description
                    }

                    $newTag = New-Tag @createParams
                    Write-Log "  ✓ Created tag: $($tag.Name) (Category: $($tag.CategoryName))" -Level Success
                } else {
                    Write-Log "  [DRY RUN] Would create tag: $($tag.Name) (Category: $($tag.CategoryName))" -Level Info
                }
                $stats.TagsCreated++
            }
        }
        catch {
            Write-Log "  ✗ Failed to process tag '$($tag.Name)': $($_.Exception.Message)" -Level Error
            $stats.TagsFailed++
        }
    }

    Write-Log "" -Level Info

    # Display summary
    Write-Log "========================================" -Level Info
    Write-Log "Import Summary" -Level Info
    Write-Log "========================================" -Level Info
    Write-Log "Tag Categories:" -Level Info
    Write-Log "  Created: $($stats.CategoriesCreated)" -Level Success
    if ($UpdateExisting) {
        Write-Log "  Updated: $($stats.CategoriesUpdated)" -Level Info
    }
    Write-Log "  Skipped: $($stats.CategoriesSkipped)" -Level Info
    if ($stats.CategoriesFailed -gt 0) {
        Write-Log "  Failed: $($stats.CategoriesFailed)" -Level Error
    }
    Write-Log "" -Level Info
    Write-Log "Tags:" -Level Info
    Write-Log "  Created: $($stats.TagsCreated)" -Level Success
    if ($UpdateExisting) {
        Write-Log "  Updated: $($stats.TagsUpdated)" -Level Info
    }
    Write-Log "  Skipped: $($stats.TagsSkipped)" -Level Info
    if ($stats.TagsFailed -gt 0) {
        Write-Log "  Failed: $($stats.TagsFailed)" -Level Error
    }
    Write-Log "" -Level Info

    if ($DryRun) {
        Write-Log "DRY RUN COMPLETED - No changes were made" -Level Warning
    } else {
        Write-Log "Import completed successfully!" -Level Success
    }

    # Disconnect from vCenter
    Disconnect-VIServer -Server $connection -Confirm:$false
    Write-Log "Disconnected from vCenter" -Level Info

    # Exit code based on failures
    if ($stats.CategoriesFailed -gt 0 -or $stats.TagsFailed -gt 0) {
        exit 1
    } else {
        exit 0
    }
}
catch {
    Write-Log "Import failed: $($_.Exception.Message)" -Level Error
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level Error

    # Disconnect if connected
    if ($connection) {
        Disconnect-VIServer -Server $connection -Confirm:$false -ErrorAction SilentlyContinue
    }

    exit 1
}
