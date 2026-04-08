param($Timer, $outputQueue)

# ============================================================
# EnqueuePDFs - Timer Trigger
# Reads compression-targets.json to find which sites/libraries
# to process tonight. Edit that file to control what runs.
# ============================================================

Import-Module "$PSScriptRoot\..\shared\SharePoint-Helpers.psm1"

$tenantId     = $env:TENANT_ID
$clientId     = $env:CLIENT_ID
$clientSecret = $env:CLIENT_SECRET
$testMode     = $env:TEST_MODE -eq "true"
$testLimit    = [int]($env:TEST_LIMIT ?? "5")
$minSizeMB    = [double]($env:MIN_SIZE_MB ?? "5")

# --- Read targets config ---
$configPath = Join-Path $PSScriptRoot "..\compression-targets.json"
if (-not (Test-Path $configPath)) {
    Write-Error "❌ compression-targets.json not found at $configPath"
    throw "Missing config file"
}

$targets = Get-Content $configPath -Raw | ConvertFrom-Json
$enabledTargets = $targets | Where-Object { $_.enabled -eq $true }

Write-Host "========================================"
Write-Host "EnqueuePDFs starting"
Write-Host "Total targets:   $($targets.Count)"
Write-Host "Enabled targets: $($enabledTargets.Count)"
Write-Host "Test Mode:       $testMode (limit: $testLimit per library)"
Write-Host "Min Size:        $minSizeMB MB"
Write-Host "========================================"

if ($enabledTargets.Count -eq 0) {
    Write-Host "⚠️  No enabled targets found in compression-targets.json — nothing to do."
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

foreach ($target in $enabledTargets) {
    $siteUrl     = $target.siteUrl
    $libraryName = $target.libraryName

    Write-Host ""
    Write-Host "--- Target: $siteUrl / $libraryName ---"

    try {
        $files = Get-LargePDFFiles -SiteUrl $siteUrl -LibraryName $libraryName `
                                   -AccessToken $accessToken -MinSizeMB $minSizeMB
        Write-Host "  📄 Found $($files.Count) PDFs larger than $minSizeMB MB"

        if ($testMode) {
            $files = $files | Select-Object -First $testLimit
            Write-Host "  🧪 TEST MODE: Limiting to $($files.Count) files"
        }

        foreach ($file in $files) {
            $message = @{
                Id                = $file.Id
                Name              = $file.Name
                ServerRelativeUrl = $file.ServerRelativeUrl
                SizeMB            = [math]::Round($file.Length / 1MB, 2)
                SiteUrl           = $siteUrl
                LibraryName       = $libraryName
            } | ConvertTo-Json -Compress

            $outputQueue.Add($message)
            $totalQueued++
        }

        Write-Host "  ✅ Enqueued $($files.Count) files"

    } catch {
        Write-Warning "  ❌ Failed for $siteUrl / $libraryName`: $_"
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "✅ Total enqueued: $totalQueued files"
Write-Host "========================================"
