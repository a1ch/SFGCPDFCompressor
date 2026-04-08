param($QueueItem)

# ============================================================
# CompressPDFs - Queue Trigger
# Processes ONE PDF per execution.
# Downloads the file, compresses it, replaces it in place.
# The SharePoint list item row is never touched.
# ============================================================

Import-Module "$PSScriptRoot\..\shared\Compress-PDF.psm1"
Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"
Import-Module "$PSScriptRoot\..\shared\Blob-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET

# Parse queue message
$file           = $QueueItem | ConvertFrom-Json
$fileName       = $file.Name
$fileId         = $file.Id
$serverPath     = $file.ServerRelativeUrl
$originalSizeMB = $file.SizeMB
$siteUrl        = $file.SiteUrl
$libraryName    = $file.LibraryName

Write-Host "========================================"
Write-Host "Processing: $fileName ($originalSizeMB MB)"
Write-Host "Site:       $siteUrl"
Write-Host "Library:    $libraryName"
Write-Host "========================================"

try {
    $blobCtx = Ensure-BlobContainer -ContainerName "pdf-processing-temp"
} catch {
    Write-Error "❌ Blob storage setup failed: $_"
    throw
}

try {
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
} catch {
    Write-Error "❌ Authentication failed: $_"
    throw
}

$inputBlobName  = "$fileId`_input.pdf"
$outputBlobName = "$fileId`_output.pdf"
$tempDir        = [System.IO.Path]::GetTempPath()
$tempInput      = Join-Path $tempDir $inputBlobName
$tempOutput     = Join-Path $tempDir $outputBlobName

try {
    # 1. Download file from SharePoint
    Write-Host "⬇️  Downloading from SharePoint..."
    Download-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                            -DestinationPath $tempInput -AccessToken $accessToken

    # Stage in blob storage to handle large files safely
    Write-Host "☁️  Staging in blob storage..."
    Upload-ToBlob -FilePath $tempInput -BlobName $inputBlobName -StorageContext $blobCtx
    Remove-Item $tempInput -Force

    # 2. Compress
    Write-Host "🗜️  Compressing..."
    Download-FromBlob -BlobName $inputBlobName -DestinationPath $tempInput -StorageContext $blobCtx
    Compress-PDFFile -InputPath $tempInput -OutputPath $tempOutput | Out-Null

    $newSizeMB = [math]::Round((Get-Item $tempOutput).Length / 1MB, 2)
    $savedMB   = [math]::Round($originalSizeMB - $newSizeMB, 2)
    $pct       = [math]::Round(($savedMB / $originalSizeMB) * 100, 0)
    Write-Host "📉 $originalSizeMB MB → $newSizeMB MB (saved $savedMB MB / $pct%)"

    if ($pct -lt 10) {
        Write-Host "⏭️  Skipping — less than 10% reduction"
        return
    }

    # 3. Replace the file in SharePoint (same path, same name, row untouched)
    Write-Host "⬆️  Replacing file in SharePoint..."
    Upload-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                          -FilePath $tempOutput -AccessToken $accessToken

    Write-Host "✅ Done — saved $savedMB MB"

} catch {
    Write-Error "❌ Failed: $_"
    throw
} finally {
    if (Test-Path $tempInput)  { Remove-Item $tempInput  -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue }
    Delete-Blob -BlobName $inputBlobName  -StorageContext $blobCtx
    Delete-Blob -BlobName $outputBlobName -StorageContext $blobCtx
}
