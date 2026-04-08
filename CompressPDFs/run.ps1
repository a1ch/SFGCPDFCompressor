param($Timer)

# ============================================================
# SFGCPDFCompressor - Azure Function
# Compresses oversized PDFs in SharePoint libraries while
# preserving all metadata. Uses Azure Blob Storage as temp
# space to safely handle very large files (1GB+).
# ============================================================

Import-Module "$PSScriptRoot\..\shared\Compress-PDF.psm1"
Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"
Import-Module "$PSScriptRoot\..\shared\Blob-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$siteUrl      = $env:SHAREPOINT_SITE_URL
$libraryName  = $env:LIBRARY_NAME
$testMode     = $env:TEST_MODE -eq "true"
$testLimit    = [int]($env:TEST_LIMIT ?? "5")
$minSizeMB    = [double]($env:MIN_SIZE_MB ?? "5")

Write-Host "========================================"
Write-Host "SFGCPDFCompressor starting"
Write-Host "Site:      $siteUrl"
Write-Host "Library:   $libraryName"
Write-Host "Test Mode: $testMode (limit: $testLimit files)"
Write-Host "Min Size:  $minSizeMB MB"
Write-Host "========================================"

# --- Set up Blob Storage temp container ---
try {
    $blobCtx = Ensure-BlobContainer -ContainerName "pdf-processing-temp"
    Write-Host "✅ Blob storage ready"
} catch {
    Write-Error "❌ Blob storage setup failed: $_"
    throw
}

# --- Authenticate to SharePoint ---
try {
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    Write-Host "✅ Authenticated to SharePoint"
} catch {
    Write-Error "❌ Authentication failed: $_"
    throw
}

# --- Get PDF files from library ---
try {
    $files = Get-LargePDFFiles -SiteUrl $siteUrl -LibraryName $libraryName `
                               -AccessToken $accessToken -MinSizeMB $minSizeMB
    Write-Host "📄 Found $($files.Count) PDF files larger than $minSizeMB MB"
} catch {
    Write-Error "❌ Failed to get files: $_"
    throw
}

if ($files.Count -eq 0) {
    Write-Host "✅ No files to process."
    return
}

if ($testMode) {
    $files = $files | Select-Object -First $testLimit
    Write-Host "🧪 TEST MODE: Processing $($files.Count) files only"
}

# --- Process each file ---
$results = @{ Processed = 0; Skipped = 0; Failed = 0; TotalSavedMB = 0.0 }

foreach ($file in $files) {
    $fileName       = $file.Name
    $fileId         = $file.Id
    $serverPath     = $file.ServerRelativeUrl
    $originalSizeMB = [math]::Round($file.Length / 1MB, 2)

    Write-Host ""
    Write-Host "--- Processing: $fileName ($originalSizeMB MB) ---"

    $inputBlobName  = "$fileId`_input.pdf"
    $outputBlobName = "$fileId`_output.pdf"
    $tempDir        = [System.IO.Path]::GetTempPath()
    $tempInput      = Join-Path $tempDir $inputBlobName
    $tempOutput     = Join-Path $tempDir $outputBlobName

    try {
        # 1. Read all metadata before touching the file
        $metadata = Get-FileMetadata -SiteUrl $siteUrl -FileId $fileId -AccessToken $accessToken
        Write-Host "  📋 Read $($metadata.Keys.Count) metadata fields"

        # 2. Download from SharePoint then stage in blob storage
        Write-Host "  ⬇️  Downloading from SharePoint..."
        Download-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                                -DestinationPath $tempInput -AccessToken $accessToken
        Write-Host "  ☁️  Staging in blob storage..."
        Upload-ToBlob -FilePath $tempInput -BlobName $inputBlobName -StorageContext $blobCtx
        Remove-Item $tempInput -Force

        # 3. Download from blob and compress
        Write-Host "  🗜️  Compressing..."
        Download-FromBlob -BlobName $inputBlobName -DestinationPath $tempInput -StorageContext $blobCtx
        Compress-PDFFile -InputPath $tempInput -OutputPath $tempOutput | Out-Null

        $newSizeMB = [math]::Round((Get-Item $tempOutput).Length / 1MB, 2)
        $savedMB   = [math]::Round($originalSizeMB - $newSizeMB, 2)
        $pct       = [math]::Round(($savedMB / $originalSizeMB) * 100, 0)
        Write-Host "  📉 $originalSizeMB MB → $newSizeMB MB (saved $savedMB MB / $pct%)"

        if ($pct -lt 10) {
            Write-Host "  ⏭️  Skipping — less than 10% reduction"
            $results.Skipped++
            continue
        }

        # 4. Upload compressed file back to SharePoint
        Write-Host "  ⬆️  Uploading to SharePoint..."
        Upload-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                              -FilePath $tempOutput -AccessToken $accessToken

        # 5. Restore all metadata
        Set-FileMetadata -SiteUrl $siteUrl -FileId $fileId -Metadata $metadata -AccessToken $accessToken
        Write-Host "  ✅ Done"

        $results.Processed++
        $results.TotalSavedMB += $savedMB

    } catch {
        Write-Warning "  ❌ Failed: $_"
        $results.Failed++
    } finally {
        if (Test-Path $tempInput)  { Remove-Item $tempInput  -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue }
        Delete-Blob -BlobName $inputBlobName  -StorageContext $blobCtx
        Delete-Blob -BlobName $outputBlobName -StorageContext $blobCtx
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "✅ Processed : $($results.Processed)"
Write-Host "⏭️  Skipped   : $($results.Skipped)"
Write-Host "❌ Failed    : $($results.Failed)"
Write-Host "💾 Total Saved: $([math]::Round($results.TotalSavedMB, 1)) MB"
Write-Host "========================================"
