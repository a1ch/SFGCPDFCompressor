# Remove-OldVersions.ps1
# One-off tool to delete old SharePoint file versions from all compressed libraries.
# Uses device code flow - authenticates as YOUR account, no app registration needed.
#
# Usage:
#   .\Remove-OldVersions.ps1
#   .\Remove-OldVersions.ps1 -KeepVersions 1 -WhatIf   # dry run
#
# Requirements:
#   - Your account must have access to the SharePoint sites in the config list
#   - Client ID from your existing app registration (no secret needed)
#   - PowerShell 5.1+

param(
    [int]$KeepVersions  = 1,
    [switch]$WhatIf
)

# ── CONFIG ───────────────────────────────────────────────────────────────────
if ($env:TENANT_ID)       { $TenantId       = $env:TENANT_ID       } else { $TenantId       = Read-Host "Tenant ID" }
if ($env:CLIENT_ID)       { $ClientId       = $env:CLIENT_ID       } else { $ClientId       = Read-Host "Client ID (app registration)" }
if ($env:CONFIG_SITE_URL) { $ConfigSiteUrl  = $env:CONFIG_SITE_URL } else { $ConfigSiteUrl  = Read-Host "Config site URL (e.g. https://streamflogroup.sharepoint.com/itsp)" }
if ($env:CONFIG_LIST_NAME){ $ConfigListName = $env:CONFIG_LIST_NAME} else { $ConfigListName = "SFGCFMCompressor" }
# ─────────────────────────────────────────────────────────────────────────────

function Get-DeviceCodeToken {
    param([string]$TenantId, [string]$ClientId)

    $scope = "https://graph.microsoft.com/Sites.ReadWrite.All offline_access"

    # Request device code
    $dcResponse = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Method POST `
        -Body @{ client_id = $ClientId; scope = $scope } `
        -ContentType "application/x-www-form-urlencoded"

    Write-Host ""
    Write-Host "=============================================="
    Write-Host $dcResponse.message
    Write-Host "=============================================="
    Write-Host ""

    # Poll for token
    if ($dcResponse.interval)   { $interval  = $dcResponse.interval   } else { $interval  = 5   }
    if ($dcResponse.expires_in) { $expiresIn = $dcResponse.expires_in } else { $expiresIn = 900 }
    $deadline = (Get-Date).AddSeconds($expiresIn)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tokenResponse = Invoke-RestMethod `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Method POST `
                -Body @{
                    grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                    client_id   = $ClientId
                    device_code = $dcResponse.device_code
                } `
                -ContentType "application/x-www-form-urlencoded" `
                -ErrorAction Stop

            Write-Host "Authenticated successfully`n"
            return $tokenResponse.access_token
        } catch {
            $err = $null
            try { $err = $_.ErrorDetails.Message | ConvertFrom-Json } catch {}
            if ($err -and $err.error -eq "authorization_pending") { continue }
            if ($err -and $err.error -eq "authorization_declined") { throw "Authentication declined by user." }
            if ($err -and $err.error -eq "expired_token")          { throw "Device code expired. Please re-run the script." }
            throw $_
        }
    }

    throw "Timed out waiting for authentication."
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

Write-Host "Authenticating as your account via device code flow..."
$token = Get-DeviceCodeToken -TenantId $TenantId -ClientId $ClientId

# Read config list
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
