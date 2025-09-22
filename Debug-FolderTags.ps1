# Quick debug script to test folder tag processing for multiple tags
param(
    [string]$FolderName = "TestAppFolder",
    [string]$AppCategoryName = "vCenter-KLEB-App-team"
)

# This test validates that folders with multiple tags (like domain-admins AND special-domain-admins)
# will have ALL tags processed, not just the first one.

Write-Host "=== Debugging Folder Tag Processing ===" -ForegroundColor Cyan

try {
    # Connect to vCenter (assume already connected)

    # Get the folder
    $folder = Get-Folder -Name $FolderName -Type VM -ErrorAction SilentlyContinue
    if (-not $folder) {
        Write-Host "Folder '$FolderName' not found" -ForegroundColor Red
        return
    }

    Write-Host "Found folder: $($folder.Name)" -ForegroundColor Green

    # Get ALL tag assignments for the folder
    $allFolderTags = Get-TagAssignment -Entity $folder -ErrorAction SilentlyContinue
    Write-Host "Total tags on folder: $($allFolderTags.Count)" -ForegroundColor Yellow

    foreach ($tagAssignment in $allFolderTags) {
        Write-Host "  Tag: '$($tagAssignment.Tag.Name)' Category: '$($tagAssignment.Tag.Category.Name)'" -ForegroundColor White
    }

    # Get app category tags specifically
    $appFolderTags = $allFolderTags | Where-Object { $_.Tag.Category.Name -eq $AppCategoryName }
    Write-Host "`nApp category tags: $($appFolderTags.Count)" -ForegroundColor Yellow

    foreach ($tagAssignment in $appFolderTags) {
        Write-Host "  App Tag: '$($tagAssignment.Tag.Name)'" -ForegroundColor Green
    }

    # Test the exact logic from the script
    Write-Host "`n=== Testing Script Logic ===" -ForegroundColor Cyan
    $folderTags = Get-TagAssignment -Entity $folder -ErrorAction SilentlyContinue |
                  Where-Object { $_.Tag.Category.Name -eq $AppCategoryName }

    Write-Host "Script logic found $($folderTags.Count) tags" -ForegroundColor Yellow

    $tagIndex = 0
    foreach ($folderTagAssignment in $folderTags) {
        $tagIndex++
        $tagName = $folderTagAssignment.Tag.Name
        Write-Host "Processing tag #$tagIndex`: '$tagName'" -ForegroundColor Green

        # Check if this is an array or single object
        if ($folderTags -is [array]) {
            Write-Host "  folderTags is an array with $($folderTags.Count) elements" -ForegroundColor Cyan
        } else {
            Write-Host "  folderTags is a single object" -ForegroundColor Cyan
        }
    }

    # Test if there's a type issue
    Write-Host "`n=== Variable Type Analysis ===" -ForegroundColor Cyan
    Write-Host "folderTags type: $($folderTags.GetType().FullName)" -ForegroundColor White
    Write-Host "folderTags count property: $($folderTags.Count)" -ForegroundColor White
    Write-Host "folderTags length property: $($folderTags.Length)" -ForegroundColor White

}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}