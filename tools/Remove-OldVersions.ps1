# Remove-OldVersions.ps1
# Deletes all previous versions from SharePoint files in compressed libraries,
# keeping only the current live file. No versions are ever retained.
#
# Authenticates using app registration client credentials (same as the function app).
# Token is refreshed before each library to handle long runs.
#
# After each library completes, writes the current timestamp to the LastCleaned
# column in the SFGCFMCompressor config list. On subsequent runs, any library
# that has a LastCleaned value is skipped entirely — no file scanning, no API calls.
# Use -Force to override and rescan everything regardless of LastCleaned.
#
# Usage:
#   .\Remove-OldVersions.ps1                        # skip libraries already cleaned
#   .\Remove-OldVersions.ps1 -Force                 # rescan everything, ignore LastCleaned
#   .\Remove-OldVersions.ps1 -WhatIf                # dry run (does not write LastCleaned)
#   .\Remove-OldVersions.ps1 -SiteFilter "FileMagicUK"
#   .\Remove-OldVersions.ps1 -LibraryFilter "DESIGN_REVIEW"
#   .\Remove-OldVersions.ps1 -PauseBatchSize 5000 -PauseMinutes 10
#   .\Remove-OldVersions.ps1 -ThrottleMs 50
#
# Requirements:
#   - PowerShell 5.1+
#   - TENANT_ID, CLIENT_ID, CLIENT_SECRET env vars (or script will prompt)

param(
    [switch]$WhatIf,
    [switch]$Force,

    [string]$SiteFilter    = "",
    [string]$LibraryFilter = "",

    [int]$ThrottleMs     = 50,
    [int]$MaxRetries     = 5,
    [int]$PauseBatchSize = 5000,
    [int]$PauseMinutes   = 10
)

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

function Invoke-GraphRequest {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers,
        [string]$Body = $null,
        [int]$Retries = $MaxRetries
    )
    $attempt = 0
    while ($true) {
        try {
            $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers }
            if ($Body) { $params.Body = $Body }
            return Invoke-RestMethod @params
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
    # Simple file listing — no expand, works on all library types
    param([string]$DriveId, [string]$Token)
    $headers  = Get-GraphHeaders $Token
    $allItems = @()
    $nextUri  = "https://graph.microsoft.com/v1.0/drives/$DriveId/root/search(q='')" +
                "?`$select=id,name,file,size&`$top=500"
    do {
        $resp     = Invoke-GraphRequest -Uri $nextUri -Headers $headers
        $allItems += $resp.value | Where-Object { $_.file }
        $nextUri  = $resp.'@odata.nextLink'
    } while ($nextUri)
    return $allItems
}

function Set-LastCleaned {
    param([string]$ConfigSiteId, [string]$ConfigListId, [string]$ListItemId, [string]$Token)
    $now  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $body = @{ LastCleaned = $now } | ConvertTo-Json
    $uri  = "https://graph.microsoft.com/v1.0/sites/$ConfigSiteId/lists/$ConfigListId/items/$ListItemId/fields"
    try {
        Invoke-GraphRequest -Uri $uri -Method PATCH -Headers (Get-GraphHeaders $Token) -Body $body | Out-Null
        Write-Host "  LastCleaned set: $now" -ForegroundColor DarkGray
    } catch {
        Write-Warning "  Could not update LastCleaned: $_"
    }
}

function Remove-AllOldVersions {
    param([string]$DriveId, [string]$ItemId, [string]$ItemName, [string]$Token, [bool]$DryRun)
    $headers  = Get-GraphHeaders $Token
    $resp     = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/versions" -Headers $headers
    $versions = $resp.value  # newest first

    if ($versions.Count -le $KEEP) {
        return 0  # already clean — silent skip, no output spam
    }

    $toDelete = $versions | Select-Object -Skip $KEEP

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

if ($WhatIf) { Write-Host "*** DRY RUN MODE - no versions will be deleted, LastCleaned will not be updated ***`n" -ForegroundColor Yellow }
if ($Force)  { Write-Host "*** FORCE MODE - ignoring LastCleaned, all libraries will be scanned ***`n"           -ForegroundColor Yellow }
if ($SiteFilter)           { Write-Host "Site filter:    '$SiteFilter'"                                           -ForegroundColor Cyan }
if ($LibraryFilter)        { Write-Host "Library filter: '$LibraryFilter'"                                        -ForegroundColor Cyan }
if ($PauseBatchSize -gt 0) { Write-Host "Batch pause:    every $PauseBatchSize files cleaned, $PauseMinutes min"  -ForegroundColor Cyan }
Write-Host "Throttle:       $ThrottleMs ms between deletes"                                                       -ForegroundColor Cyan
Write-Host "Keeping:        live file only (all previous versions deleted)"                                       -ForegroundColor Cyan
Write-Host "Skip logic:     libraries with LastCleaned set are skipped (use -Force to override)"                  -ForegroundColor Cyan
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
$totalSkipped  = 0
$dirtyForPause = 0

foreach ($target in $targets) {
    $siteUrl     = $target.fields.SiteUrl
    $libraryName = $target.fields.LibraryName
    $listItemId  = $target.id
    if ($target.fields.Title) { $label = $target.fields.Title } else { $label = "$siteUrl / $libraryName" }

    Write-Host "----------------------------------------"
    Write-Host "Library: $label"
    Write-Host "  Site:    $siteUrl"
    Write-Host "  Library: $libraryName"

    if (-not $Force -and $target.fields.LastCleaned) {
        Write-Host "  SKIPPED - already cleaned on $($target.fields.LastCleaned) (use -Force to rescan)" -ForegroundColor DarkGray
        $totalSkipped++
        continue
    }

    $token = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    try {
        $siteId  = Get-SiteId -SiteUrl $siteUrl -Token $token
        $driveId = Get-DriveId -SiteId $siteId -LibraryName $libraryName -Token $token

        Write-Host "  Scanning files..."
        $files = Get-AllDriveItems -DriveId $driveId -Token $token
        Write-Host "  Files found: $($files.Count)"

        $totalFiles += $files.Count

        foreach ($file in $files) {
            if ($PauseBatchSize -gt 0 -and $dirtyForPause -gt 0 -and ($dirtyForPause % $PauseBatchSize) -eq 0) {
                Invoke-BatchPause -Minutes $PauseMinutes -FilesProcessed $totalDirty -Token ([ref]$token)
            }

            $deleted       = Remove-AllOldVersions -DriveId $driveId -ItemId $file.id -ItemName $file.name `
                                                   -Token $token -DryRun $WhatIf.IsPresent
            $totalDeleted += $deleted
            if ($deleted -gt 0) {
                $totalDirty++
                $dirtyForPause++
            }
        }

        Write-Host "  Library done - $totalDirty file(s) cleaned so far"

        if (-not $WhatIf) {
            Set-LastCleaned -ConfigSiteId $configSiteId -ConfigListId $configListId `
                            -ListItemId $listItemId -Token $token
        }

    } catch {
        Write-Warning "  Failed to process '$label': $_"
    }
}

Write-Host ""
Write-Host "=============================================="
Write-Host "Complete."
Write-Host "  Libraries skipped:    $totalSkipped (LastCleaned already set)"
Write-Host "  Files scanned:        $totalFiles"
Write-Host "  Files with old vers:  $totalDirty"
Write-Host "  Versions deleted:     $totalDeleted"
if ($WhatIf) { Write-Host "(Dry run - nothing was deleted, LastCleaned not updated)" -ForegroundColor Yellow }
Write-Host "=============================================="
