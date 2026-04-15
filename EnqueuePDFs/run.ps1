param($Timer)

# ============================================================
# EnqueuePDFs - Timer Trigger
# Reads a SharePoint list ("SFGCFMCompressor") to find which
# sites/libraries to process tonight.
# After scanning each library, writes LastCompressed back to
# the control list row.
# Sends a summary email via Graph API when done.
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

foreach ($target in $targets) {
    $siteUrl      = $target.fields.SiteUrl.Trim()
    $libraryName  = $target.fields.LibraryName.Trim()
    $label        = $target.fields.Title
    $itemId       = $target.id
    $minSizeMB    = if ($target.fields.MinSizeMB -and $target.fields.MinSizeMB -gt 0) { $target.fields.MinSizeMB } else { $globalMinMB }
    $minSizeBytes = [long]($minSizeMB * 1MB)

    Write-Host ""
    Write-Host "--- [$label] $siteUrl / $libraryName (min: $minSizeMB MB) ---"

    $targetCount = 0

    try {
        # Get site and drive IDs
        $siteId  = Get-SiteId -SiteUrl $siteUrl -AccessToken $accessToken
        $driveId = Get-DriveId -SiteId $siteId -LibraryName $libraryName -AccessToken $accessToken

        # Page through all files in the library
        $uri     = "https://graph.microsoft.com/v1.0/drives/$driveId/root/children?`$select=id,name,size&`$top=500"
        $headers = @{ Authorization = "Bearer $accessToken" }

        do {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
            $items    = $response.value

            foreach ($item in $items) {
                if (-not ($item.name -like "*.pdf")) { continue }
                if ([long]$item.size -le $minSizeBytes) { continue }

                $message = @{
                    DriveItemId = $item.id
                    DriveId     = $driveId
                    SiteId      = $siteId
                    Name        = $item.name
                    SizeMB      = [math]::Round([long]$item.size / 1MB, 2)
                    SiteUrl     = $siteUrl
                    LibraryName = $libraryName
                } | ConvertTo-Json -Compress

                Push-OutputBinding -Name outputQueue -Value $message

                $totalQueued++
                $targetCount++

                if ($testMode -and $targetCount -ge $testLimit) {
                    Write-Host "  TEST MODE: Reached limit of $testLimit files"
                    $uri = $null
                    break
                }
            }

            $uri = $response.'@odata.nextLink'

        } while ($uri)

        Write-Host "  Done - enqueued $targetCount file(s)"

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

Write-Host ""
Write-Host "========================================"
Write-Host "Total enqueued: $totalQueued files"
Write-Host "========================================"

# --- Send summary email ---
try {
    $htmlBody = Build-SummaryEmailHtml `
                    -TotalTargets    $targets.Count `
                    -TotalQueued     $totalQueued `
                    -TargetSummaries $targetSummaries `
                    -RunDate         $runDate

    Send-SummaryEmail `
        -GraphToken  $accessToken `
        -FromAddress $summaryFrom `
        -ToAddress   $summaryTo `
        -Subject     "PDF Compressor - Nightly Run $((Get-Date).ToString('yyyy-MM-dd')) - $totalQueued files queued" `
        -HtmlBody    $htmlBody
} catch {
    Write-Warning "Could not send summary email: $_"
}
