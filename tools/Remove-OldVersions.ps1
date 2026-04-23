# Remove-OldVersions.ps1
# One-off tool to delete old SharePoint file versions from compressed libraries.
# Authenticates using app registration client credentials (same as the function app).
# Token is refreshed before each library to handle long runs.
#
# Usage:
#   .\Remove-OldVersions.ps1
#   .\Remove-OldVersions.ps1 -WhatIf                          # dry run all enabled targets
#   .\Remove-OldVersions.ps1 -SiteFilter "FileMagicUK"        # only sites whose URL contains "FileMagicUK"
#   .\Remove-OldVersions.ps1 -LibraryFilter "DESIGN_REVIEW"   # only libraries with this exact name
#   .\Remove-OldVersions.ps1 -SiteFilter "itsp" -LibraryFilter "Documents"
#   .\Remove-OldVersions.ps1 -MaxFiles 500                    # stop after processing 500 files total
#   .\Remove-OldVersions.ps1 -ThrottleMs 200                  # wait 200ms between each version delete
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
    [int]$ThrottleMs  = 100,     # ms to wait between each version delete call
    [int]$MaxFiles    = 0,       # 0 = unlimited; set to cap total files processed this run
    [int]$MaxRetries  = 5        # how many times to retry a 429 before giving up
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
                # Try to read Retry-After header; default to exponential backoff
                $retryAfter = 10
                try {
                    $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"]
                } catch {}
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
    param([string]$DriveId, [string]$Token)
    $headers  = Get-GraphHeaders $Token
    $allItems = @()
    $nextUri  = "https://graph.microsoft.com/v1.0/drives/$DriveId/root/search(q='')?`$select=id,name,file,size&`$top=500"
    do {
        $resp     = Invoke-GraphRequest -Uri $nextUri -Headers $headers
        $allItems += $resp.value | Where-Object { $_.file }
        $nextUri  = $resp.'@odata.nextLink'
    } while ($nextUri)
    return $allItems
}

function Remove-OldVersions {
    param([string]$DriveId, [string]$ItemId, [string]$ItemName, [string]$Token, [int]$Keep, [bool]$DryRun)

    $headers  = Get-GraphHeaders $Token
    $resp     = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/versions" -Headers $headers
    $versions = $resp.value  # newest first

    if ($versions.Count -le $Keep) {
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

# ── MAIN ─────────────────────────────────────────────────────────────────────

if ($WhatIf) { Write-Host "*** DRY RUN MODE - no versions will be deleted ***`n" -ForegroundColor Yellow }
if ($SiteFilter)    { Write-Host "Site filter:    '$SiteFilter'" -ForegroundColor Cyan }
if ($LibraryFilter) { Write-Host "Library filter: '$LibraryFilter'" -ForegroundColor Cyan }
if ($MaxFiles -gt 0){ Write-Host "Max files:      $MaxFiles" -ForegroundColor Cyan }
Write-Host "Throttle:       $ThrottleMs ms between deletes" -ForegroundColor Cyan
Write-Host ""

Write-Host "Authenticating..."
$token = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
Write-Host "Authenticated successfully`n"

Write-Host "Reading compression targets from '$ConfigListName'..."
$configSiteId = Get-SiteId -SiteUrl $ConfigSiteUrl -Token $token
$configListId = ""
$listResp = Invoke-GraphRequest -Uri "https://graph.microsoft.com/v1.0/sites/$configSiteId/lists?`$filter=displayName eq '$ConfigListName'" -Headers (Get-GraphHeaders $token)
$configList = $listResp.value | Where-Object { $_.displayName -eq $ConfigListName } | Select-Object -First 1
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
    if ($SiteFilter    -and $_.fields.SiteUrl     -notlike "*$SiteFilter*")    { return $false }
    if ($LibraryFilter -and $_.fields.LibraryName -ne $LibraryFilter)          { return $false }
    return $true
}

Write-Host "Found $($targets.Count) matching target(s) (of $($items.Count) total)`n"

$totalDeleted = 0
$totalFiles   = 0
$hitMaxFiles  = $false

foreach ($target in $targets) {
    if ($hitMaxFiles) { break }

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
        $files   = Get-AllDriveItems -DriveId $driveId -Token $token

        Write-Host "  Files:   $($files.Count)"

        foreach ($file in $files) {
            if ($MaxFiles -gt 0 -and $totalFiles -ge $MaxFiles) {
                Write-Host "`n  MaxFiles ($MaxFiles) reached - stopping." -ForegroundColor Yellow
                $hitMaxFiles = $true
                break
            }
            $deleted      = Remove-OldVersions -DriveId $driveId -ItemId $file.id -ItemName $file.name `
                                               -Token $token -Keep $KeepVersions -DryRun $WhatIf.IsPresent
            $totalDeleted += $deleted
            $totalFiles++
        }
    } catch {
        Write-Warning "  Failed to process '$label': $_"
    }
}

Write-Host ""
Write-Host "=============================================="
if ($hitMaxFiles) { Write-Host "Stopped early at MaxFiles limit ($MaxFiles)." -ForegroundColor Yellow }
Write-Host "Complete. $totalFiles file(s) checked, $totalDeleted version(s) deleted."
if ($WhatIf) { Write-Host "(Dry run - nothing was actually deleted)" -ForegroundColor Yellow }
Write-Host "=============================================="
