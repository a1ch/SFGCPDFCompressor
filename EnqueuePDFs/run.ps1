param($Timer, $outputQueue)

# ============================================================
# EnqueuePDFs - Timer Trigger
# Reads a SharePoint list ("PDF Compression Targets") to find
# which sites/libraries to process tonight.
# Enqueues files as it pages through SharePoint so it never
# times out on large libraries.
#
# Required App Settings:
#   TENANT_ID, CLIENT_ID, CLIENT_SECRET
#   CONFIG_SITE_URL      - site hosting the targets list
#   CONFIG_LIST_NAME     - list name (default: "PDF Compression Targets")
#   TEST_MODE            - "true" to limit files per library
#   TEST_LIMIT           - max files per library in test mode
#   MIN_SIZE_MB          - global default minimum file size
# ============================================================

Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$testMode     = $env:TEST_MODE -eq "true"
$testLimit    = [int]($env:TEST_LIMIT ?? "5")
$globalMinMB  = [double]($env:MIN_SIZE_MB ?? "5")

$configSiteUrl  = $env:CONFIG_SITE_URL
$configListName = $env:CONFIG_LIST_NAME ?? "PDF Compression Targets"

if (-not $configSiteUrl) {
    Write-Error "❌ CONFIG_SITE_URL app setting is not set."
    throw "Missing CONFIG_SITE_URL"
}

Write-Host "========================================"
Write-Host "EnqueuePDFs starting"
Write-Host "Config site:  $configSiteUrl"
Write-Host "Config list:  $configListName"
Write-Host "Test Mode:    $testMode (limit: $testLimit per library)"
Write-Host "Global Min:   $globalMinMB MB"
Write-Host "========================================"

# --- Authenticate ---
try {
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    Write-Host "✅ Authenticated to SharePoint"
} catch {
    Write-Error "❌ Authentication failed: $_"
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
    Write-Error "❌ Failed to read config list '$configListName' from $configSiteUrl`: $_"
    throw
}

Write-Host "✅ Found $($targets.Count) enabled target(s)"

if ($targets.Count -eq 0) {
    Write-Host "⚠️  No enabled targets in '$configListName' — nothing to do."
    return
}

# --- Process each target ---
$totalQueued = 0

foreach ($target in $targets) {
    $siteUrl     = $target.SiteUrl.Trim()
    $libraryName = $target.LibraryName.Trim()
    $label       = $target.Title
    $minSizeMB   = if ($target.MinSizeMB -and $target.MinSizeMB -gt 0) { $target.MinSizeMB } else { $globalMinMB }
    $minSizeBytes = [long]($minSizeMB * 1MB)

    Write-Host ""
    Write-Host "--- [$label] $siteUrl / $libraryName (min: $minSizeMB MB) ---"

    # Authenticate with target site if different from config site
    $siteToken = $accessToken
    if ($siteUrl.TrimEnd('/') -ne $configSiteUrl.TrimEnd('/')) {
        try {
            $siteToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -ResourceHost ([Uri]$siteUrl).Host
        } catch {
            Write-Warning "  ⚠️  Could not get token for $siteUrl — trying with config site token"
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

                $outputQueue.Add($message)
                $totalQueued++
                $targetCount++

                if ($testMode -and $targetCount -ge $testLimit) {
                    Write-Host "  🧪 TEST MODE: Reached limit of $testLimit files for this library"
                    $uri = $null
                    break
                }
            }

            Write-Host "  📄 Page $pageCount — queued $targetCount so far..."
            $uri = $response.d.__next

        } while ($uri)

        Write-Host "  ✅ Done — enqueued $targetCount file(s) across $pageCount page(s)"

    } catch {
        Write-Warning "  ❌ Failed for [$label] $siteUrl / $libraryName`: $_"
        # Continue with next target rather than failing the whole run
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "✅ Total enqueued: $totalQueued files across $($targets.Count) target(s)"
Write-Host "========================================"
