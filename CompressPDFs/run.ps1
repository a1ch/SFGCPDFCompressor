param($QueueItem)

# ============================================================
# CompressPDFs - Queue Trigger
# Processes ONE PDF per execution.
# Downloads the file, compresses it, replaces it in place.
# Reads SharePoint column metadata before upload and restores
# it after so custom columns are never lost.
# Writes a log entry to SFGCFMCompressorLog after each file.
# Token is refreshed after compression so it never expires
# during the upload step.
# ============================================================

Import-Module "$PSScriptRoot/../shared/Compress-PDF.psm1"
Import-Module "$PSScriptRoot/../shared/SharePoint-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$logSiteUrl   = $env:CONFIG_SITE_URL
$logListName  = $env:LOG_LIST_NAME ?? "SFGCFMCompressorLog"
$keepVersions = [int]($env:KEEP_VERSIONS ?? "1")

# Parse queue message
$file = $null
$typeName = $QueueItem.GetType().FullName
Write-Host "QueueItem type: $typeName"

if ($QueueItem -is [System.Collections.Hashtable] -or
    $QueueItem -is [System.Management.Automation.PSCustomObject] -or
    $typeName -eq 'System.Management.Automation.OrderedHashtable') {
    $file = $QueueItem
} elseif ($QueueItem -is [string]) {
    $file = $QueueItem | ConvertFrom-Json
} else {
    $rawString = $QueueItem | Out-String
    $file = $rawString.Trim() | ConvertFrom-Json
}

if (-not $file) {
    Write-Error "Could not parse queue message - file is null after parsing"
    throw "Queue message parse failed"
}

$fileName       = $file.Name
$driveItemId    = $file.DriveItemId
$driveId        = $file.DriveId
$siteId         = $file.SiteId
$listId         = $file.ListId
$listItemId     = $file.ListItemId
$originalSizeMB = $file.SizeMB
$siteUrl        = $file.SiteUrl
$libraryName    = $file.LibraryName

Write-Host "========================================"
Write-Host "Processing: $fileName ($originalSizeMB MB)"
Write-Host "Site:       $siteUrl"
Write-Host "Library:    $libraryName"
Write-Host "========================================"

$rand       = [System.IO.Path]::GetRandomFileName()
$tempDir    = [System.IO.Path]::GetTempPath()
$tempInput  = Join-Path $tempDir "compress_in_$rand.pdf"
$tempOutput = Join-Path $tempDir "compress_out_$rand.pdf"
$skipped    = $false

try {
    # 1. Get fresh token for download + metadata
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    Write-Host "Token acquired"

    # 2. Snapshot column metadata BEFORE touching the file
    $metadata = @{}
    if ($listId -and $listItemId) {
        Write-Host "Reading column metadata..."
        try {
            $metadata = Get-FileMetadata -SiteId $siteId -ListId $listId -ItemId $listItemId -AccessToken $accessToken
            Write-Host "  Captured $($metadata.Count) column value(s)"
        } catch {
            Write-Warning "  Could not read metadata - will proceed but columns may not be preserved: $_"
        }
    } else {
        Write-Warning "  No ListId/ListItemId in queue message - column metadata will not be preserved"
    }

    # 3. Download from SharePoint via Graph
    Write-Host "Downloading from SharePoint..."
    Download-SharePointFile -DriveId $driveId -DriveItemId $driveItemId `
                            -DestinationPath $tempInput -AccessToken $accessToken

    $downloadedSize = (Get-Item $tempInput).Length
    Write-Host "Downloaded: $([math]::Round($downloadedSize / 1MB, 2)) MB"

    # 4. Compress (this can take 2-3 minutes - token will expire during this step)
    Write-Host "Compressing..."
    Compress-PDFFile -InputPath $tempInput -OutputPath $tempOutput | Out-Null

    $newSizeMB = [math]::Round((Get-Item $tempOutput).Length / 1MB, 2)
    $savedMB   = [math]::Round($originalSizeMB - $newSizeMB, 2)
    $pct       = [math]::Round(($savedMB / $originalSizeMB) * 100, 0)
    Write-Host "$originalSizeMB MB -> $newSizeMB MB (saved $savedMB MB / $pct%)"

    if ($pct -lt 10) {
        Write-Host "Skipping - less than 10% reduction"
        $skipped = $true
        return
    }

    # 5. Refresh token before upload - compression takes long enough to expire the old one
    Write-Host "Refreshing token before upload..."
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret

    # 6. Upload compressed file back to SharePoint
    Write-Host "Replacing file in SharePoint..."
    Upload-SharePointFile -DriveId $driveId -DriveItemId $driveItemId `
                          -FilePath $tempOutput -AccessToken $accessToken

    # 7. Restore column metadata immediately after upload
    if ($listId -and $listItemId -and $metadata.Count -gt 0) {
        Write-Host "Restoring column metadata..."
        try {
            Set-FileMetadata -SiteId $siteId -ListId $listId -ItemId $listItemId `
                             -Metadata $metadata -AccessToken $accessToken
        } catch {
            Write-Warning "  Could not restore metadata: $_"
        }
    }

    Remove-OldFileVersions -DriveId $driveId -DriveItemId $driveItemId `
                           -AccessToken $accessToken -KeepVersions $keepVersions

    Write-Host "Done - saved $savedMB MB"

    # 8. Write log entry
    if ($logSiteUrl) {
        Write-LogEntry `
            -SiteUrl          $logSiteUrl `
            -ListName         $logListName `
            -AccessToken      $accessToken `
            -FileName         $fileName `
            -FileSiteUrl      $siteUrl `
            -LibraryName      $libraryName `
            -OriginalSizeMB   $originalSizeMB `
            -CompressedSizeMB $newSizeMB `
            -SavedMB          $savedMB `
            -SavingsPct       $pct
    }

} catch {
    Write-Error "Failed: $_"
    throw
} finally {
    # Always clean up temp files regardless of success, failure, or skip
    if (Test-Path $tempInput)  { Remove-Item $tempInput  -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue }
    if ($skipped) { Write-Host "Temp files cleaned up (skipped file)" }
}
