# Remove-OldVersions.ps1
# One-off tool to delete old SharePoint file versions from compressed libraries.
# Authenticates using app registration client credentials (same as the function app).
# Token is refreshed before each library to handle long runs.
#
# How API calls are minimised:
#   - Get-AllDriveItems fetches each page of files WITH versions expanded ($top=2 per file).
#     This gives us enough to know if a file has more than KeepVersions versions in a single
#     paged request — no extra per-file API call needed just to check.
#   - Files that already have <= KeepVersions are skipped entirely (no versions endpoint hit,
#     no delete calls). On a library that's already mostly clean this saves the vast majority
#     of API calls.
#   - Only files that actually need cleanup proceed to the full versions list + delete loop.
#
# Usage:
#   .\Remove-OldVersions.ps1
#   .\Remove-OldVersions.ps1 -WhatIf                                   # dry run all enabled targets
#   .\Remove-OldVersions.ps1 -SiteFilter "FileMagicUK"                 # only sites whose URL contains "FileMagicUK"
#   .\Remove-OldVersions.ps1 -LibraryFilter "DESIGN_REVIEW"            # only libraries with this exact name
#   .\Remove-OldVersions.ps1 -SiteFilter "itsp" -LibraryFilter "Docs"
#   .\Remove-OldVersions.ps1 -PauseBatchSize 1000 -PauseMinutes 15     # pause 15 min every 1000 files NEEDING cleanup
#   .\Remove-OldVersions.ps1 -ThrottleMs 200                           # wait 200ms between each version delete
#
# Requirements:
#   - PowerShell 5.1+
#   - TENANT_ID, CLIENT_ID, CLIENT_SECRET env vars (or it will prompt)

param(
    [int]$KeepVersions  = 1,
    [switch]$WhatIf,

    # Targeting - leave blank to process all enabled targets
    [string]$SiteFilter     = "",   # substring match on SiteUrl  (e.g. "FileMagicUK")
    [string]$LibraryFilter  = "",   # exact match on LibraryName  (e.g. "DESIGN_REVIEW")

    # Throttle / safety controls
    [int]$ThrottleMs      = 100,   # ms to wait between each version delete call
    [int]$MaxRetries      = 5,     # how many times to retry a 429 before giving up

    # Batch pause - pause for PauseMinutes after every PauseBatchSize files NEEDING cleanup
    # (files that are already clean don't count toward this — they're skipped for free)
    [int]$PauseBatchSize  = 1000,  # 0 = never pause
    [int]$PauseMinutes    = 15
)

# ── CONFIG ───────────────────────────────────────────────────────────────────
if ($env:TENANT_ID)        { $TenantId       = $env:TENANT_ID        } else { $TenantId       = Read-Host "Tenant ID" }
if ($env:CLIENT_ID)        { $ClientId       = $env:CLIENT_ID        } else { $ClientId       = Read-Host "Client ID" }
if ($env:CLIENT_SECRET)    { $ClientSecret   = $env:CLIENT_SECRET    } else { $ClientSecret   = Read-Host "Client Secret" }
if ($env:CONFIG_SITE_URL)  { $ConfigSiteUrl  = $env:CONFIG_SITE_URL  } else { $ConfigSiteUrl  = Read-Host "Config site URL (e.g. https://streamflogroup.sharepoint.com/itsp)" }
if ($env:CONFIG_LIST_NAME) { $ConfigListName = $env:CONFIG_LIST_NAME } else { $ConfigListName = "SFGCFMCompressor" }
# ─────────────────────────────────────────────────────────────────────────────

function Get-AppToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $response = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method POST `
        -Body @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
        } `
        -ContentType "application/x-www-form-urlencoded"
    return $response.access_token
}

function Get-GraphHeaders {
    param([string]$Token)
    return @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
}

# Invoke-RestMethod wrapper that retries on 429 with Retry-After backoff
function Invoke-GraphRequest {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers,
        [int]$Retries = $MaxRetries
    )
    $attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers
        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -eq 429 -and $attempt -lt $Retries) {
                $retryAfter = 10
                try { $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"] } catch {}
                if ($retryAfter -lt 1) { $retryAfter = [math]::Pow(2, $attempt + 1) }
                Write-Warning "  429 Too Many Requests - waiting $retryAfter s before retry ($($attempt+1)/$Retries)..."
                Start-Sleep -Seconds $retryAfter
                $attempt++
            } else {
                throw
            }
        }
    }
}

function Get-SiteId {
    param([string]$SiteUrl, [string]$Token)
    $uri  = [Uri]$SiteUrl
    $resp = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/sites/$($uri.Host):$($uri.AbsolutePath.TrimEnd('/'))" -Headers (Get-GraphHeaders $Token)
    return $resp.id
}

function Get-DriveId {
    param([string]$SiteId, [string]$LibraryName, [string]$Token)
    $resp  = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drives" -Headers (Get-GraphHeaders $Token)
    $drive = $resp.value | Where-Object { $_.name -eq $LibraryName } | Select-Object -First 1
    if (-not $drive) { throw "Library '$LibraryName' not found on site $SiteId" }
    return $drive.id
}

function Get-AllDriveItems {
    # Fetches all files in the drive.
    # Expands versions with $top=KeepVersions+1 so we can tell immediately whether
    # a file needs cleanup without a separate API call per file.
    # A file comes back with versions.Count > KeepVersions only if it has old versions to delete.
    param([string]$DriveId, [string]$Token, [int]$KeepVersions)

    $headers  = Get-GraphHeaders $Token
    $allItems = @()
    $expandTop = $KeepVersions + 1   # fetch just one more than we want to keep — enough to know cleanup is needed

    # $expand=versions with $top scoped to the expand so we don't pull the full version list here
    $nextUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root/search(q='')" +
               "?`$select=id,name,file,size" +
               "&`$expand=versions(`$select=id;`$top=$expandTop)" +
               "&`$top=500"

    do {
        $resp     = Invoke-GraphRequest -Uri $nextUri -Headers $headers
        $allItems += $resp.value | Where-Object { $_.file }
        $nextUri  = $resp.'@odata.nextLink'
    } while ($nextUri)

    return $allItems
}

function Remove-OldVersions {
    param([string]$DriveId, [string]$ItemId, [string]$ItemName, [string]$Token, [int]$Keep, [bool]$DryRun)

    $headers = Get-GraphHeaders $Token

    # Fetch full version list now — we only reach here for files that need cleanup
    $resp     = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/versions" -Headers $headers
    $versions = $resp.value  # newest first

    if ($versions.Count -le $Keep) {
        # Shouldn't normally reach here given the pre-filter, but guard anyway
        Write-Host "  SKIP  $ItemName ($($versions.Count) version(s))"
        return 0
    }

    $toDelete = $versions | Select-Object -Skip $Keep

    if ($DryRun) {
        Write-Host "  DRYRUN  $ItemName - would delete $($toDelete.Count) version(s) (keeping $Keep)"
        return $toDelete.Count
    }

    $deleted = 0
    foreach ($v in $toDelete) {
        try {
            Invoke-GraphRequest `
                -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/versions/$($v.id)" `
                -Method DELETE -Headers $headers | Out-Null
            $deleted++
            if ($ThrottleMs -gt 0) { Start-Sleep -Milliseconds $ThrottleMs }
        } catch {
            Write-Warning "  Could not delete version $($v.id) on $ItemName`: $_"
        }
    }

    Write-Host "  DONE  $ItemName - deleted $deleted version(s)"
    return $deleted
}

function Invoke-BatchPause {
    param([int]$Minutes, [int]$FilesProcessed, [ref]$Token)
    $pauseSecs = $Minutes * 60
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  Batch pause after $FilesProcessed files needing cleanup" -ForegroundColor Cyan
    Write-Host "  Cooling down for $Minutes minutes..." -ForegroundColor Cyan

    $resume = (Get-Date).AddSeconds($pauseSecs)
    while ((Get-Date) -lt $resume) {
        $remaining = [math]::Ceiling(($resume - (Get-Date)).TotalSeconds)
        Write-Host "  Resuming in $remaining s...   " -NoNewline
        "`r" | Write-Host -NoNewline
        Start-Sleep -Seconds 15
    }

    Write-Host "  Pause complete - refreshing token and resuming." -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    $Token.Value = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
}

# ── MAIN ─────────────────────────────────────────────────────────────────────

if ($WhatIf) { Write-Host "*** DRY RUN MODE - no versions will be deleted ***`n" -ForegroundColor Yellow }
if ($SiteFilter)           { Write-Host "Site filter:      '$SiteFilter'"                                        -ForegroundColor Cyan }
if ($LibraryFilter)        { Write-Host "Library filter:   '$LibraryFilter'"                                     -ForegroundColor Cyan }
if ($PauseBatchSize -gt 0) { Write-Host "Batch pause:      every $PauseBatchSize dirty files for $PauseMinutes min" -ForegroundColor Cyan }
Write-Host "Throttle:         $ThrottleMs ms between deletes"                                                    -ForegroundColor Cyan
Write-Host "Version pre-scan: enabled (skips clean files without extra API calls)"                               -ForegroundColor Cyan
Write-Host ""

Write-Host "Authenticating..."
$token = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
Write-Host "Authenticated successfully`n"

Write-Host "Reading compression targets from '$ConfigListName'..."
$configSiteId = Get-SiteId -SiteUrl $ConfigSiteUrl -Token $token
$listResp     = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/sites/$configSiteId/lists?`$filter=displayName eq '$ConfigListName'" -Headers (Get-GraphHeaders $token)
$configList   = $listResp.value | Where-Object { $_.displayName -eq $ConfigListName } | Select-Object -First 1
if (-not $configList) { throw "List '$ConfigListName' not found" }
$configListId = $configList.id

$items   = @()
$nextUri = "https://graph.microsoft.com/v1.0/sites/$configSiteId/lists/$configListId/items?`$expand=fields&`$top=500"
do {
    $resp    = Invoke-GraphRequest -Uri $nextUri -Headers (Get-GraphHeaders $token)
    $items  += $resp.value
    $nextUri = $resp.'@odata.nextLink'
} while ($nextUri)

# Apply enabled + optional site/library filters
$targets = $items | Where-Object {
    if ($_.fields.Enabled -ne $true) { return $false }
    if ($SiteFilter    -and $_.fields.SiteUrl     -notlike "*$SiteFilter*") { return $false }
    if ($LibraryFilter -and $_.fields.LibraryName -ne $LibraryFilter)       { return $false }
    return $true
}

Write-Host "Found $($targets.Count) matching target(s) (of $($items.Count) total)`n"

$totalDeleted    = 0
$totalFiles      = 0   # all files scanned
$totalDirty      = 0   # files that actually needed cleanup
$dirtyForPause   = 0   # dirty file counter for batch pause

foreach ($target in $targets) {
    $siteUrl     = $target.fields.SiteUrl
    $libraryName = $target.fields.LibraryName
    if ($target.fields.Title) { $label = $target.fields.Title } else { $label = "$siteUrl / $libraryName" }

    Write-Host "----------------------------------------"
    Write-Host "Library: $label"
    Write-Host "  Site:    $siteUrl"
    Write-Host "  Library: $libraryName"

    # Refresh token before each library (tokens expire after 1 hour)
    $token = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    try {
        $siteId  = Get-SiteId -SiteUrl $siteUrl -Token $token
        $driveId = Get-DriveId -SiteId $siteId -LibraryName $libraryName -Token $token

        Write-Host "  Scanning files (with version pre-check)..."
        $files = Get-AllDriveItems -DriveId $driveId -Token $token -KeepVersions $KeepVersions

        # Split into dirty (needs cleanup) vs clean (already fine) right from the expanded data
        $dirtyFiles = $files | Where-Object { $_.versions -and $_.versions.Count -gt $KeepVersions }
        $cleanFiles = $files | Where-Object { -not $_.versions -or $_.versions.Count -le $KeepVersions }

        Write-Host "  Files:   $($files.Count) total  |  $($dirtyFiles.Count) need cleanup  |  $($cleanFiles.Count) already clean (skipped)"

        $totalFiles += $files.Count

        foreach ($file in $dirtyFiles) {
            # Pause check - only dirty files count toward the batch pause threshold
            if ($PauseBatchSize -gt 0 -and $dirtyForPause -gt 0 -and ($dirtyForPause % $PauseBatchSize) -eq 0) {
                Invoke-BatchPause -Minutes $PauseMinutes -FilesProcessed $totalDirty -Token ([ref]$token)
            }

            $deleted       = Remove-OldVersions -DriveId $driveId -ItemId $file.id -ItemName $file.name `
                                                -Token $token -Keep $KeepVersions -DryRun $WhatIf.IsPresent
            $totalDeleted += $deleted
            $totalDirty++
            $dirtyForPause++
        }
    } catch {
        Write-Warning "  Failed to process '$label': $_"
    }
}

Write-Host ""
Write-Host "=============================================="
Write-Host "Complete."
Write-Host "  Files scanned:       $totalFiles"
Write-Host "  Files needing work:  $totalDirty"
Write-Host "  Versions deleted:    $totalDeleted"
if ($WhatIf) { Write-Host "(Dry run - nothing was actually deleted)" -ForegroundColor Yellow }
Write-Host "=============================================="
