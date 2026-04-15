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

# --- Authenticate to SharePoint ---
try {
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    Write-Host "Authenticated to SharePoint"
} catch {
    Write-Error "Authentication failed: $_"
    throw
}

$headers = @{ Authorization = "Bearer $accessToken"; Accept = "application/json;odata=verbose" }

# --- Read targets from SharePoint list ---
Write-Host ""
Write-Host "Reading targets from '$configListName'..."

$configUri = "$configSiteUrl/_api/web/lists/getbytitle('$configListName')/items?" +
             "`$select=Id,Title,SiteUrl,LibraryName,Enabled,MinSizeMB&" +
             "`$filter=Enabled eq 1&" +
             "`$top=500"

try {
    $configResponse = Invoke-RestMethod -Uri $configUri -Headers $headers -Method GET
    $targets = $configResponse.d.results
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
    $siteUrl      = $target.SiteUrl.Trim()
    $libraryName  = $target.LibraryName.Trim()
    $label        = $target.Title
    $itemId       = $target.Id
    $minSizeMB    = if ($target.MinSizeMB -and $target.MinSizeMB -gt 0) { $target.MinSizeMB } else { $globalMinMB }
    $minSizeBytes = [long]($minSizeMB * 1MB)

    Write-Host ""
    Write-Host "--- [$label] $siteUrl / $libraryName (min: $minSizeMB MB) ---"

    $siteToken = $accessToken
    if ($siteUrl.TrimEnd('/') -ne $configSiteUrl.TrimEnd('/')) {
        try {
            $siteToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -ResourceHost ([Uri]$siteUrl).Host
        } catch {
            Write-Warning "  Could not get token for $siteUrl - trying with config site token"
            $siteToken = $accessToken
        }
    }

    $siteHeaders = @{ Authorization = "Bearer $siteToken"; Accept = "application/json;odata=verbose" }

    $uri = "$siteUrl/_api/web/lists/getbytitle('$libraryName')/items?" +
           "`$select=Id,File/Name,File/ServerRelativeUrl,File/Length&" +
           "`$expand=File&" +
           "`$filter=File/Name ne null&" +
           "`$top=500"

    $pageCount   = 0
    $targetCount = 0

    try {
        do {
            $response = Invoke-RestMethod -Uri $uri -Headers $siteHeaders -Method GET
            $items    = $response.d.results
            $pageCount++

            foreach ($item in $items) {
                $f = $item.File
                if (-not ($f.Name -like "*.pdf")) { continue }
                if ([long]$f.Length -le $minSizeBytes) { continue }

                $message = @{
                    Id                = $item.Id
                    Name              = $f.Name
                    ServerRelativeUrl = $f.ServerRelativeUrl
                    SizeMB            = [math]::Round([long]$f.Length / 1MB, 2)
                    SiteUrl           = $siteUrl
                    LibraryName       = $libraryName
                } | ConvertTo-Json -Compress

                Push-OutputBinding -Name outputQueue -Value $message

                $totalQueued++
                $targetCount++

                if ($testMode -and $targetCount -ge $testLimit) {
                    Write-Host "  TEST MODE: Reached limit of $testLimit files for this library"
                    $uri = $null
                    break
                }
            }

            Write-Host "  Page $pageCount - queued $targetCount so far..."
            $uri = $response.d.__next

        } while ($uri)

        Write-Host "  Done - enqueued $targetCount file(s) across $pageCount page(s)"

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
        Write-Warning "  Failed for [$label] $siteUrl / $libraryName`: $_"
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "Total enqueued: $totalQueued files across $($targets.Count) target(s)"
Write-Host "========================================"

# --- Send summary email ---
try {
    $graphToken = Get-GraphAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    $htmlBody   = Build-SummaryEmailHtml `
                    -TotalTargets    $targets.Count `
                    -TotalQueued     $totalQueued `
                    -TargetSummaries $targetSummaries `
                    -RunDate         $runDate

    Send-SummaryEmail `
        -GraphToken  $graphToken `
        -FromAddress $summaryFrom `
        -ToAddress   $summaryTo `
        -Subject     "PDF Compressor - Nightly Run $((Get-Date).ToString('yyyy-MM-dd')) - $totalQueued files queued" `
        -HtmlBody    $htmlBody

} catch {
    Write-Warning "Could not send summary email: $_"
}
