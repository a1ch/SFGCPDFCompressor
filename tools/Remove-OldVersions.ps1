# Remove-OldVersions.ps1
# Deletes all previous versions from SharePoint files in compressed libraries,
# keeping only the current live file. No versions are ever retained.
#
# Authenticates using app registration client credentials (same as the function app).
# Token is refreshed before each library to handle long runs.
#
# How API calls are minimised:
#   - Get-AllDriveItems fetches each page of files WITH versions expanded ($top=2).
#     This tells us immediately whether a file has any old versions at all — no
#     separate per-file API call needed just to check.
#   - Files that are already on version 1 only are skipped with zero extra API calls.
#   - Only files that actually have old versions proceed to the full delete loop.
#
# Usage:
#   .\Remove-OldVersions.ps1
#   .\Remove-OldVersions.ps1 -WhatIf                                    # dry run
#   .\Remove-OldVersions.ps1 -SiteFilter "FileMagicUK"                  # one site
#   .\Remove-OldVersions.ps1 -LibraryFilter "DESIGN_REVIEW"             # one library
#   .\Remove-OldVersions.ps1 -PauseBatchSize 1000 -PauseMinutes 15      # pace the run
#   .\Remove-OldVersions.ps1 -ThrottleMs 200                            # slower deletes
#
# Requirements:
#   - PowerShell 5.1+
#   - TENANT_ID, CLIENT_ID, CLIENT_SECRET env vars (or script will prompt)

param(
    [switch]$WhatIf,

    # Targeting - leave blank to process all enabled targets
    [string]$SiteFilter    = "",   # substring match on SiteUrl  (e.g. "FileMagicUK")
    [string]$LibraryFilter = "",   # exact match on LibraryName  (e.g. "DESIGN_REVIEW")

    # Throttle / safety controls
    [int]$ThrottleMs   = 100,   # ms to wait between each version delete call
    [int]$MaxRetries   = 5,     # how many times to retry a 429 before giving up

    # Batch pause - pause for PauseMinutes after every PauseBatchSize files that needed cleanup
    # Files already on version 1 are skipped for free and don't count toward this
    [int]$PauseBatchSize = 1000,  # 0 = never pause
    [int]$PauseMinutes   = 15
)

# Always keep only the live file — no previous versions ever retained
$KEEP = 1

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
    # Fetches all files, expanding versions with $top=2.
    # If a file comes back with 2 versions it has at least one old version to delete.
    # If it comes back with 1 version it is already clean — skip it for free.
    param([string]$DriveId, [string]$Token)

    $headers  = Get-GraphHeaders $Token
    $allItems = @()

    $nextUri = "https://graph.microsoft.com/v1.0/drives/$DriveId/root/search(q='')" +
               "?`$select=id,name,file,size" +
               "&`$expand=versions(`$select=id;`$top=2)" +
               "&`$top=500"

    do {
        $resp     = Invoke-GraphRequest -Uri $nextUri -Headers $headers
        $allItems += $resp.value | Where-Object { $_.file }
        $nextUri  = $resp.'@odata.nextLink'
    } while ($nextUri)

    return $allItems
}

function Remove-AllOldVersions {
    # Deletes every version except the current one (index 0, newest first).
    param([string]$DriveId, [string]$ItemId, [string]$ItemName, [string]$Token, [bool]$DryRun)

    $headers  = Get-GraphHeaders $Token
    $resp     = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/versions" -Headers $headers
    $versions = $resp.value  # newest first — index 0 is the live file

    if ($versions.Count -le $KEEP) {
        Write-Host "  SKIP  $ItemName (already on version 1 only)"
        return 0
    }

    $toDelete = $versions | Select-Object -Skip $KEEP   # everything after the live version

    if ($DryRun) {
        Write-Host "  DRYRUN  $ItemName - would delete $($toDelete.Count) old version(s)"
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

    Write-Host "  DONE  $ItemName - deleted $deleted old version(s)"
    return $deleted
}

function Invoke-BatchPause {
    param([int]$Minutes, [int]$FilesProcessed, [ref]$Token)
    $pauseSecs = $Minutes * 60
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  Batch pause after $FilesProcessed files cleaned" -ForegroundColor Cyan
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
if ($SiteFilter)           { Write-Host "Site filter:    '$SiteFilter'"                                          -ForegroundColor Cyan }
if ($LibraryFilter)        { Write-Host "Library filter: '$LibraryFilter'"                                       -ForegroundColor Cyan }
if ($PauseBatchSize -gt 0) { Write-Host "Batch pause:    every $PauseBatchSize files cleaned, $PauseMinutes min" -ForegroundColor Cyan }
Write-Host "Throttle:       $ThrottleMs ms between deletes"                                                      -ForegroundColor Cyan
Write-Host "Keeping:        live file only (all previous versions deleted)"                                      -ForegroundColor Cyan
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

$targets = $items | Where-Object {
    if ($_.fields.Enabled -ne $true) { return $false }
    if ($SiteFilter    -and $_.fields.SiteUrl     -notlike "*$SiteFilter*") { return $false }
    if ($LibraryFilter -and $_.fields.LibraryName -ne $LibraryFilter)       { return $false }
    return $true
}

Write-Host "Found $($targets.Count) matching target(s) (of $($items.Count) total)`n"

$totalDeleted  = 0
$totalFiles    = 0
$totalDirty    = 0
$dirtyForPause = 0

foreach ($target in $targets) {
    $siteUrl     = $target.fields.SiteUrl
    $libraryName = $target.fields.LibraryName
    if ($target.fields.Title) { $label = $target.fields.Title } else { $label = "$siteUrl / $libraryName" }

    Write-Host "----------------------------------------"
    Write-Host "Library: $label"
    Write-Host "  Site:    $siteUrl"
    Write-Host "  Library: $libraryName"

    $token = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    try {
        $siteId  = Get-SiteId -SiteUrl $siteUrl -Token $token
        $driveId = Get-DriveId -SiteId $siteId -LibraryName $libraryName -Token $token

        Write-Host "  Scanning files..."
        $files = Get-AllDriveItems -DriveId $driveId -Token $token

        $dirtyFiles = $files | Where-Object { $_.versions -and $_.versions.Count -gt $KEEP }
        $cleanCount = $files.Count - $dirtyFiles.Count

        Write-Host "  Files: $($files.Count) total  |  $($dirtyFiles.Count) have old versions  |  $cleanCount already clean"

        $totalFiles += $files.Count

        foreach ($file in $dirtyFiles) {
            if ($PauseBatchSize -gt 0 -and $dirtyForPause -gt 0 -and ($dirtyForPause % $PauseBatchSize) -eq 0) {
                Invoke-BatchPause -Minutes $PauseMinutes -FilesProcessed $totalDirty -Token ([ref]$token)
            }

            $deleted       = Remove-AllOldVersions -DriveId $driveId -ItemId $file.id -ItemName $file.name `
                                                   -Token $token -DryRun $WhatIf.IsPresent
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
Write-Host "  Files scanned:        $totalFiles"
Write-Host "  Files with old vers:  $totalDirty"
Write-Host "  Versions deleted:     $totalDeleted"
if ($WhatIf) { Write-Host "(Dry run - nothing was actually deleted)" -ForegroundColor Yellow }
Write-Host "=============================================="
