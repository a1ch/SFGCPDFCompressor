param($Timer)

# ============================================================
# EnqueuePDFs - Timer Trigger
# Reads a SharePoint list ("SFGCFMCompressor") to find which
# sites/libraries to process tonight.
# Skips any row where LastCompressed is already set.
# Recursively scans ALL subfolders in each library.
# Includes ListId and ListItemId in queue messages so
# CompressPDFs can preserve column metadata.
# After scanning each library, writes LastCompressed back to
# the control list row.
# Sends a summary email with a queued file manifest attached.
# ============================================================

Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"
Import-Module "$PSScriptRoot\..\shared\Graph-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$testMode     = $env:TEST_MODE -eq "true"
$testLimit    = [int]($env:TEST_LIMIT ?? "5")
$globalMinMB  = [double]($env:MIN_SIZE_MB ?? "5")

$configSiteUrl  = $env:CONFIG_SITE_URL
$configListName = $env:CONFIG_LIST_NAME ?? "SFGCFMCompressor"
$summaryTo      = $env:SUMMARY_EMAIL_TO ?? "sstubbs@streamflo.com"
$summaryFrom    = $env:SUMMARY_EMAIL_FROM ?? "sstubbs@streamflo.com"

if (-not $configSiteUrl) {
    Write-Error "CONFIG_SITE_URL app setting is not set."
    throw "Missing CONFIG_SITE_URL"
}

$runDate = (Get-Date).ToString("dddd, MMMM d, yyyy 'at' h:mm tt")

Write-Host "========================================"
Write-Host "EnqueuePDFs starting"
Write-Host "Config site:  $configSiteUrl"
Write-Host "Config list:  $configListName"
Write-Host "Test Mode:    $testMode (limit: $testLimit per library)"
Write-Host "Global Min:   $globalMinMB MB"
Write-Host "Run date:     $runDate"
Write-Host "========================================"

# --- Authenticate ---
try {
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    Write-Host "Authenticated to Graph API"
} catch {
    Write-Error "Authentication failed: $_"
    throw
}

# --- Helper: recursively scan a folder and enqueue matching PDFs ---
function Scan-Folder {
    param(
        [string]$FolderUri,
        [string]$DriveId,
        [string]$SiteId,
        [string]$ListId,
        [string]$SiteUrl,
        [string]$LibraryName,
        [long]$MinSizeBytes,
        [ref]$Count,
        [ref]$Done,
        [ref]$FileLog   # accumulates lines for the attachment
    )

    $headers = @{ Authorization = "Bearer $accessToken" }
    $uri = $FolderUri

    do {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
        foreach ($item in $response.value) {

            if ($Done.Value) { return }

            if ($item.folder) {
                $subUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($item.id)/children?`$select=id,name,size,folder,listItem&`$expand=listItem(`$select=id)&`$top=500"
                Scan-Folder -FolderUri $subUri -DriveId $DriveId -SiteId $SiteId -ListId $ListId `
                            -SiteUrl $SiteUrl -LibraryName $LibraryName `
                            -MinSizeBytes $MinSizeBytes -Count $Count -Done $Done -FileLog $FileLog
                if ($Done.Value) { return }
                continue
            }

            if (-not ($item.name -like "*.pdf")) { continue }
            if ([long]$item.size -le $MinSizeBytes) { continue }

            $sizeMB = [math]::Round([long]$item.size / 1MB, 2)

            $message = @{
                DriveItemId = $item.id
                DriveId     = $DriveId
                SiteId      = $SiteId
                ListId      = $ListId
                ListItemId  = $item.listItem.id
                Name        = $item.name
                SizeMB      = $sizeMB
                SiteUrl     = $SiteUrl
                LibraryName = $LibraryName
            } | ConvertTo-Json -Compress

            Push-OutputBinding -Name outputQueue -Value $message
            $Count.Value++

            # Add to file manifest log
            $FileLog.Value += "$($item.name)`t$sizeMB MB`t$LibraryName`t$SiteUrl`n"

            if ($testMode -and $Count.Value -ge $testLimit) {
                Write-Host "  TEST MODE: Reached limit of $testLimit files"
                $Done.Value = $true
                return
            }
        }
        $uri = $response.'@odata.nextLink'
    } while ($uri)
}

# --- Read targets from SharePoint list via Graph ---
Write-Host ""
Write-Host "Reading targets from '$configListName'..."

try {
    $targets = Read-ConfigList -SiteUrl $configSiteUrl -ListName $configListName -AccessToken $accessToken
} catch {
    Write-Error "Failed to read config list '$configListName' from $configSiteUrl`: $_"
    throw
}

Write-Host "Found $($targets.Count) enabled target(s)"

if ($targets.Count -eq 0) {
    Write-Host "No enabled targets - nothing to do."
    return
}

# --- Process each target ---
$totalQueued     = 0
$targetSummaries = @()
$skippedCount    = 0
$fileLog         = "SFGCPDFCompressor - Queued File Manifest`n"
$fileLog        += "Run: $runDate`n"
$fileLog        += "=" * 80 + "`n"
$fileLog        += "File`tSize`tLibrary`tSite`n"
$fileLog        += "-" * 80 + "`n"

foreach ($target in $targets) {
    $siteUrl        = $target.fields.SiteUrl.Trim()
    $libraryName    = $target.fields.LibraryName.Trim()
    $label          = $target.fields.Title
    $itemId         = $target.id
    $lastCompressed = $target.fields.LastCompressed
    $minSizeMB      = if ($target.fields.MinSizeMB -and $target.fields.MinSizeMB -gt 0) { $target.fields.MinSizeMB } else { $globalMinMB }
    $minSizeBytes   = [long]($minSizeMB * 1MB)

    Write-Host ""
    Write-Host "--- [$label] $siteUrl / $libraryName ---"

    if ($lastCompressed) {
        Write-Host "  SKIPPED - already compressed on $lastCompressed"
        $skippedCount++
        continue
    }

    $targetCount = 0
    $done        = $false

    try {
        $siteId  = Get-SiteId -SiteUrl $siteUrl -AccessToken $accessToken
        $driveId = Get-DriveId -SiteId $siteId -LibraryName $libraryName -AccessToken $accessToken
        $listId  = Get-ListId -SiteId $siteId -ListName $libraryName -AccessToken $accessToken

        $rootUri = "https://graph.microsoft.com/v1.0/drives/$driveId/root/children?`$select=id,name,size,folder,listItem&`$expand=listItem(`$select=id)&`$top=500"

        Scan-Folder -FolderUri $rootUri -DriveId $driveId -SiteId $siteId -ListId $listId `
                    -SiteUrl $siteUrl -LibraryName $libraryName `
                    -MinSizeBytes $minSizeBytes -Count ([ref]$targetCount) -Done ([ref]$done) -FileLog ([ref]$fileLog)

        Write-Host "  Done - enqueued $targetCount file(s)"
        $totalQueued += $targetCount

        Update-TargetLastCompressed `
            -SiteUrl     $configSiteUrl `
            -ListName    $configListName `
            -AccessToken $accessToken `
            -ItemId      $itemId

        $targetSummaries += @{
            Label       = $label
            SiteUrl     = $siteUrl
            LibraryName = $libraryName
            Count       = $targetCount
        }

    } catch {
        Write-Warning "  Failed for [$label]: $_"
    }
}

$fileLog += "-" * 80 + "`n"
$fileLog += "Total queued: $totalQueued files`n"

Write-Host ""
Write-Host "========================================"
Write-Host "Total enqueued: $totalQueued files"
Write-Host "Skipped (already compressed): $skippedCount"
Write-Host "========================================"

# --- Send summary email with manifest attached ---
try {
    $htmlBody    = Build-SummaryEmailHtml `
                        -TotalTargets    $targets.Count `
                        -TotalQueued     $totalQueued `
                        -TargetSummaries $targetSummaries `
                        -RunDate         $runDate

    $attachName  = "queued-files-$((Get-Date).ToString('yyyy-MM-dd')).txt"

    Send-SummaryEmail `
        -GraphToken       $accessToken `
        -FromAddress      $summaryFrom `
        -ToAddress        $summaryTo `
        -Subject          "PDF Compressor - Nightly Run $((Get-Date).ToString('yyyy-MM-dd')) - $totalQueued files queued" `
        -HtmlBody         $htmlBody `
        -AttachmentName   $attachName `
        -AttachmentContent $fileLog
} catch {
    Write-Warning "Could not send summary email: $_"
}
