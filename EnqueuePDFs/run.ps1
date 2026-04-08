param($Timer, $outputQueue)

# ============================================================
# EnqueuePDFs - Timer Trigger
# Reads compression-targets.json to find which sites/libraries
# to process tonight. Enqueues files as it pages through
# SharePoint so it never times out on large libraries.
# ============================================================

Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$testMode     = $env:TEST_MODE -eq "true"
$testLimit    = [int]($env:TEST_LIMIT ?? "5")
$minSizeMB    = [double]($env:MIN_SIZE_MB ?? "5")
$minSizeBytes = [long]($minSizeMB * 1MB)

# --- Read targets config ---
$configPath = Join-Path $PSScriptRoot "..\compression-targets.json"
if (-not (Test-Path $configPath)) {
    Write-Error "❌ compression-targets.json not found"
    throw "Missing config file"
}

$targets        = Get-Content $configPath -Raw | ConvertFrom-Json
$enabledTargets = $targets | Where-Object { $_.enabled -eq $true }

Write-Host "========================================"
Write-Host "EnqueuePDFs starting"
Write-Host "Total targets:   $($targets.Count)"
Write-Host "Enabled targets: $($enabledTargets.Count)"
Write-Host "Test Mode:       $testMode (limit: $testLimit per library)"
Write-Host "Min Size:        $minSizeMB MB"
Write-Host "========================================"

if ($enabledTargets.Count -eq 0) {
    Write-Host "⚠️  No enabled targets in compression-targets.json — nothing to do."
    return
}

# --- Authenticate once ---
try {
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    Write-Host "✅ Authenticated to SharePoint"
} catch {
    Write-Error "❌ Authentication failed: $_"
    throw
}

# --- Process each enabled target ---
$totalQueued = 0
$headers     = @{ Authorization = "Bearer $accessToken"; Accept = "application/json;odata=verbose" }

foreach ($target in $enabledTargets) {
    $siteUrl     = $target.siteUrl
    $libraryName = $target.libraryName

    Write-Host ""
    Write-Host "--- Target: $siteUrl / $libraryName ---"

    $uri = "$siteUrl/_api/web/lists/getbytitle('$libraryName')/items?" +
           "`$select=Id,File/Name,File/ServerRelativeUrl,File/Length&" +
           "`$expand=File&" +
           "`$filter=File/Name ne null&" +
           "`$top=500"

    $pageCount   = 0
    $targetCount = 0

    try {
        do {
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
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

                # Stop early in test mode
                if ($testMode -and $targetCount -ge $testLimit) {
                    Write-Host "  🧪 TEST MODE: Reached limit of $testLimit files"
                    $uri = $null
                    break
                }
            }

            Write-Host "  📄 Page $pageCount — queued $targetCount so far..."
            $uri = $response.d.__next

        } while ($uri)

        Write-Host "  ✅ Done — enqueued $targetCount files across $pageCount page(s)"

    } catch {
        Write-Warning "  ❌ Failed for $siteUrl / $libraryName`: $_"
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "✅ Total enqueued: $totalQueued files"
Write-Host "========================================"
