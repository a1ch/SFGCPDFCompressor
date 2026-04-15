param($QueueItem)

# ============================================================
# CompressPDFs - Queue Trigger
# Processes ONE PDF per execution.
# Downloads the file, compresses it, replaces it in place.
# Writes a log entry to SFGCFMCompressorLog after each file.
# ============================================================

Import-Module "$PSScriptRoot\..\shared\Compress-PDF.psm1"
Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$logSiteUrl   = $env:CONFIG_SITE_URL
$logListName  = $env:LOG_LIST_NAME ?? "SFGCFMCompressorLog"
$keepVersions = [int]($env:KEEP_VERSIONS ?? "1")

# Parse queue message - Azure may base64 encode it
$rawMessage = $QueueItem
try {
    $file = $rawMessage | ConvertFrom-Json
} catch {
    # Try base64 decode
    try {
        $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rawMessage))
        $file = $decoded | ConvertFrom-Json
    } catch {
        Write-Error "Could not parse queue message: $rawMessage"
        throw
    }
}

$fileName       = $file.Name
$driveItemId    = $file.DriveItemId
$driveId        = $file.DriveId
$siteId         = $file.SiteId
$originalSizeMB = $file.SizeMB
$siteUrl        = $file.SiteUrl
$libraryName    = $file.LibraryName

Write-Host "========================================"
Write-Host "Processing: $fileName ($originalSizeMB MB)"
Write-Host "Site:       $siteUrl"
Write-Host "Library:    $libraryName"
Write-Host "========================================"

try {
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
} catch {
    Write-Error "Authentication failed: $_"
    throw
}

$tempDir    = [System.IO.Path]::GetTempPath()
$tempInput  = Join-Path $tempDir "$driveItemId`_input.pdf"
$tempOutput = Join-Path $tempDir "$driveItemId`_output.pdf"

try {
    # 1. Download from SharePoint via Graph
    Write-Host "Downloading from SharePoint..."
    Download-SharePointFile -DriveId $driveId -DriveItemId $driveItemId `
                            -DestinationPath $tempInput -AccessToken $accessToken

    $downloadedSize = (Get-Item $tempInput).Length
    Write-Host "Downloaded: $([math]::Round($downloadedSize / 1MB, 2)) MB"

    # 2. Compress
    Write-Host "Compressing..."
    Compress-PDFFile -InputPath $tempInput -OutputPath $tempOutput | Out-Null

    $newSizeMB = [math]::Round((Get-Item $tempOutput).Length / 1MB, 2)
    $savedMB   = [math]::Round($originalSizeMB - $newSizeMB, 2)
    $pct       = [math]::Round(($savedMB / $originalSizeMB) * 100, 0)
    Write-Host "$originalSizeMB MB -> $newSizeMB MB (saved $savedMB MB / $pct%)"

    if ($pct -lt 10) {
        Write-Host "Skipping - less than 10% reduction"
        return
    }

    # 3. Replace file in SharePoint via Graph
    Write-Host "Replacing file in SharePoint..."
    Upload-SharePointFile -DriveId $driveId -DriveItemId $driveItemId `
                          -FilePath $tempOutput -AccessToken $accessToken

    Remove-OldFileVersions -DriveId $driveId -DriveItemId $driveItemId `
                           -AccessToken $accessToken -KeepVersions $keepVersions

    Write-Host "Done - saved $savedMB MB"

    # 4. Write log entry
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
    if (Test-Path $tempInput)  { Remove-Item $tempInput  -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue }
}
