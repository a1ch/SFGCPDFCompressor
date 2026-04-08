param($Timer)

# ============================================================
# SFGCPDFCompressor - Azure Function
# Compresses oversized PDFs in SharePoint libraries while
# preserving all metadata fields dynamically.
# ============================================================

Import-Module "$PSScriptRoot\..\shared\Compress-PDF.psm1"
Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"

# --- Config from App Settings ---
$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$siteUrl      = $env:SHAREPOINT_SITE_URL
$libraryName  = $env:LIBRARY_NAME

# --- Test Mode: limit how many files to process ---
$testMode     = $env:TEST_MODE -eq "true"
$testLimit    = [int]($env:TEST_LIMIT ?? "5")
$minSizeMB    = [double]($env:MIN_SIZE_MB ?? "5")   # Only compress files larger than this

Write-Host "========================================"
Write-Host "SFGCPDFCompressor starting"
Write-Host "Site:      $siteUrl"
Write-Host "Library:   $libraryName"
Write-Host "Test Mode: $testMode (limit: $testLimit files)"
Write-Host "Min Size:  $minSizeMB MB"
Write-Host "========================================"

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

# --- Apply test limit ---
if ($testMode) {
    $files = $files | Select-Object -First $testLimit
    Write-Host "🧪 TEST MODE: Processing $($files.Count) files only"
}

# --- Process each file ---
$results = @{
    Processed = 0
    Skipped   = 0
    Failed    = 0
    TotalSavedMB = 0.0
}

$tempDir = [System.IO.Path]::GetTempPath()

foreach ($file in $files) {
    $fileName    = $file.Name
    $fileId      = $file.Id
    $serverPath  = $file.ServerRelativeUrl
    $originalSizeMB = [math]::Round($file.Length / 1MB, 2)

    Write-Host ""
    Write-Host "--- Processing: $fileName ($originalSizeMB MB) ---"

    $tempInput  = Join-Path $tempDir "$fileId`_input.pdf"
    $tempOutput = Join-Path $tempDir "$fileId`_output.pdf"

    try {
        # 1. Read all metadata before touching the file
        $metadata = Get-FileMetadata -SiteUrl $siteUrl -FileId $fileId -AccessToken $accessToken
        Write-Host "  📋 Read $($metadata.Keys.Count) metadata fields"

        # 2. Download the file
        Download-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                                -DestinationPath $tempInput -AccessToken $accessToken
        Write-Host "  ⬇️  Downloaded"

        # 3. Compress the PDF
        $compressed = Compress-PDFFile -InputPath $tempInput -OutputPath $tempOutput
        $newSizeMB  = [math]::Round((Get-Item $tempOutput).Length / 1MB, 2)
        $savedMB    = [math]::Round($originalSizeMB - $newSizeMB, 2)
        $pct        = [math]::Round(($savedMB / $originalSizeMB) * 100, 0)
        Write-Host "  🗜️  Compressed: $originalSizeMB MB → $newSizeMB MB (saved $savedMB MB / $pct%)"

        # Skip if compression didn't help much
        if ($pct -lt 10) {
            Write-Host "  ⏭️  Skipping upload — less than 10% reduction"
            $results.Skipped++
            continue
        }

        # 4. Upload compressed file back (overwrite)
        Upload-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                              -FilePath $tempOutput -AccessToken $accessToken
        Write-Host "  ⬆️  Uploaded"

        # 5. Restore all metadata
        Set-FileMetadata -SiteUrl $siteUrl -FileId $fileId -Metadata $metadata -AccessToken $accessToken
        Write-Host "  ✅ Metadata restored"

        $results.Processed++
        $results.TotalSavedMB += $savedMB

    } catch {
        Write-Warning "  ❌ Failed: $_"
        $results.Failed++
    } finally {
        # Clean up temp files
        if (Test-Path $tempInput)  { Remove-Item $tempInput  -Force }
        if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force }
    }
}

# --- Summary ---
Write-Host ""
Write-Host "========================================"
Write-Host "✅ Processed : $($results.Processed)"
Write-Host "⏭️  Skipped   : $($results.Skipped)"
Write-Host "❌ Failed    : $($results.Failed)"
Write-Host "💾 Total Saved: $([math]::Round($results.TotalSavedMB, 1)) MB"
Write-Host "========================================"
