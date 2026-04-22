# Remove-OldVersions.ps1
# One-off tool to delete old SharePoint file versions from all compressed libraries.
# Authenticates using app registration client credentials (same as the function app).
# Token is refreshed before each library to handle long runs without expiry.
#
# Usage:
#   .\Remove-OldVersions.ps1
#   .\Remove-OldVersions.ps1 -KeepVersions 1 -WhatIf   # dry run
#
# Requirements:
#   - PowerShell 5.1+
#   - TENANT_ID, CLIENT_ID, CLIENT_SECRET env vars (or it will prompt)

param(
    [int]$KeepVersions = 1,
    [switch]$WhatIf
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

function Get-SiteId {
    param([string]$SiteUrl, [string]$Token)
    $uri  = [Uri]$SiteUrl
    $resp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$($uri.Host):$($uri.AbsolutePath.TrimEnd('/'))" -Headers (Get-GraphHeaders $Token)
    return $resp.id
}

function Get-ListId {
    param([string]$SiteId, [string]$ListName, [string]$Token)
    $resp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists?`$filter=displayName eq '$ListName'" -Headers (Get-GraphHeaders $Token)
    $list = $resp.value | Where-Object { $_.displayName -eq $ListName } | Select-Object -First 1
    if (-not $list) { throw "List '$ListName' not found on site $SiteId" }
    return $list.id
}

function Get-DriveId {
    param([string]$SiteId, [string]$LibraryName, [string]$Token)
    $resp  = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drives" -Headers (Get-GraphHeaders $Token)
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
        $resp     = Invoke-RestMethod -Uri $nextUri -Headers $headers
        $allItems += $resp.value | Where-Object { $_.file }
        $nextUri  = $resp.'@odata.nextLink'
    } while ($nextUri)

    return $allItems
}

function Remove-OldVersions {
    param([string]$DriveId, [string]$ItemId, [string]$ItemName, [string]$Token, [int]$Keep, [bool]$DryRun)

    $headers  = Get-GraphHeaders $Token
    $resp     = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/versions" -Headers $headers
    $versions = $resp.value  # newest first

    if ($versions.Count -le $Keep) {
        Write-Host "  SKIP  $ItemName ($($versions.Count) version(s), nothing to delete)"
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
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ItemId/versions/$($v.id)" `
                -Method DELETE -Headers $headers | Out-Null
            $deleted++
        } catch {
            Write-Warning "  Could not delete version $($v.id) on $ItemName`: $_"
        }
    }

    Write-Host "  DONE  $ItemName - deleted $deleted version(s)"
    return $deleted
}

# ── MAIN ─────────────────────────────────────────────────────────────────────

if ($WhatIf) { Write-Host "*** DRY RUN MODE - no versions will be deleted ***`n" -ForegroundColor Yellow }

# Read config list using a fresh token
Write-Host "Authenticating..."
$token = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
Write-Host "Authenticated successfully`n"

Write-Host "Reading compression targets from '$ConfigListName'..."
$configSiteId = Get-SiteId -SiteUrl $ConfigSiteUrl -Token $token
$configListId = Get-ListId -SiteId $configSiteId -ListName $ConfigListName -Token $token

$items   = @()
$nextUri = "https://graph.microsoft.com/v1.0/sites/$configSiteId/lists/$configListId/items?`$expand=fields&`$top=500"
do {
    $resp    = Invoke-RestMethod -Uri $nextUri -Headers (Get-GraphHeaders $token)
    $items  += $resp.value
    $nextUri = $resp.'@odata.nextLink'
} while ($nextUri)

$targets = $items | Where-Object { $_.fields.Enabled -eq $true }
Write-Host "Found $($targets.Count) enabled target(s)`n"

$totalDeleted = 0
$totalFiles   = 0

foreach ($target in $targets) {
    $siteUrl     = $target.fields.SiteUrl
    $libraryName = $target.fields.LibraryName
    if ($target.fields.Title) { $label = $target.fields.Title } else { $label = "$siteUrl / $libraryName" }

    Write-Host "----------------------------------------"
    Write-Host "Library: $label"
    Write-Host "  Site:    $siteUrl"
    Write-Host "  Library: $libraryName"

    # Refresh token before each library - runs can take hours and tokens expire after 1 hour
    Write-Host "  Refreshing token..."
    $token = Get-AppToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    try {
        $siteId  = Get-SiteId -SiteUrl $siteUrl -Token $token
        $driveId = Get-DriveId -SiteId $siteId -LibraryName $libraryName -Token $token
        $files   = Get-AllDriveItems -DriveId $driveId -Token $token

        Write-Host "  Files:   $($files.Count)"

        foreach ($file in $files) {
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
Write-Host "Complete. $totalFiles file(s) checked, $totalDeleted version(s) deleted."
if ($WhatIf) { Write-Host "(Dry run - nothing was actually deleted)" -ForegroundColor Yellow }
Write-Host "=============================================="
