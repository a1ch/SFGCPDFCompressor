# SharePoint-Helpers.psm1
# All SharePoint operations via Microsoft Graph API (Sites.ReadWrite.All)

function Get-SharePointAccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$ResourceHost = $null  # Unused - kept for backward compat
    )

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }

    $response = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method POST `
        -Body $body `
        -ContentType "application/x-www-form-urlencoded"

    return $response.access_token
}

function Get-GraphHeaders {
    param([string]$AccessToken)
    return @{
        Authorization  = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }
}

function Get-SiteId {
    param(
        [string]$SiteUrl,
        [string]$AccessToken
    )

    $uri  = [Uri]$SiteUrl
    $host = $uri.Host
    $path = $uri.AbsolutePath.TrimEnd('/')

    $headers  = Get-GraphHeaders $AccessToken
    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/${host}:${path}" -Headers $headers
    return $response.id
}

function Get-ListId {
    param(
        [string]$SiteId,
        [string]$ListName,
        [string]$AccessToken
    )

    $headers  = Get-GraphHeaders $AccessToken
    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists?`$filter=displayName eq '$ListName'" -Headers $headers
    $list     = $response.value | Where-Object { $_.displayName -eq $ListName } | Select-Object -First 1
    if (-not $list) { throw "List '$ListName' not found on site $SiteId" }
    return $list.id
}

function Get-DriveId {
    param(
        [string]$SiteId,
        [string]$LibraryName,
        [string]$AccessToken
    )

    $headers  = Get-GraphHeaders $AccessToken
    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drives" -Headers $headers
    $drive    = $response.value | Where-Object { $_.name -eq $LibraryName } | Select-Object -First 1
    if (-not $drive) { throw "Drive/Library '$LibraryName' not found on site $SiteId" }
    return $drive.id
}

function Invoke-GraphPagedRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    $allItems = @()
    $nextUri  = $Uri

    do {
        $response  = Invoke-RestMethod -Uri $nextUri -Headers $Headers -Method GET
        $allItems += $response.value
        $nextUri   = $response.'@odata.nextLink'
    } while ($nextUri)

    return $allItems
}

function Read-ConfigList {
    param(
        [string]$SiteUrl,
        [string]$ListName,
        [string]$AccessToken
    )

    $headers = Get-GraphHeaders $AccessToken
    $siteId  = Get-SiteId -SiteUrl $SiteUrl -AccessToken $AccessToken
    $listId  = Get-ListId -SiteId $siteId -ListName $ListName -AccessToken $AccessToken

    $uri   = "https://graph.microsoft.com/v1.0/sites/$siteId/lists/$listId/items?`$expand=fields&`$top=500"
    $items = Invoke-GraphPagedRequest -Uri $uri -Headers $headers

    return $items | Where-Object { $_.fields.Enabled -eq $true }
}

function Update-TargetLastCompressed {
    param(
        [string]$SiteUrl,
        [string]$ListName,
        [string]$AccessToken,
        [string]$ItemId
    )

    $headers = Get-GraphHeaders $AccessToken
    $siteId  = Get-SiteId -SiteUrl $SiteUrl -AccessToken $AccessToken
    $listId  = Get-ListId -SiteId $siteId -ListName $ListName -AccessToken $AccessToken

    $body = @{
        fields = @{
            LastCompressed = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    } | ConvertTo-Json -Depth 4

    $uri = "https://graph.microsoft.com/v1.0/sites/$siteId/lists/$listId/items/$ItemId"
    try {
        Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null
        Write-Host "  LastCompressed updated for item $ItemId"
    } catch {
        Write-Warning "  Could not update LastCompressed: $_"
    }
}

function Download-SharePointFile {
    param(
        [string]$DriveId,
        [string]$DriveItemId,
        [string]$DestinationPath,
        [string]$AccessToken
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $uri     = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/content"
    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $DestinationPath -Method GET
}

function Upload-SharePointFile {
    param(
        [string]$DriveId,
        [string]$DriveItemId,
        [string]$FilePath,
        [string]$AccessToken
    )

    $fileSize = (Get-Item $FilePath).Length

    # 20MB chunks - must be a multiple of 320KB (327680 bytes).
    # 20MB = 20971520 bytes = 64 * 327680 - valid multiple.
    # Gives ~100 chunks for a 2GB file vs 400 chunks at 5MB.
    $chunkSize = 20 * 1024 * 1024

    Write-Host "  Uploading $([math]::Round($fileSize / 1GB, 2)) GB via upload session ($([math]::Ceiling($fileSize / $chunkSize)) chunks)..."

    # 1. Create upload session
    $sessionUri  = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/createUploadSession"
    $sessionBody = @{ item = @{ "@microsoft.graph.conflictBehavior" = "replace" } } | ConvertTo-Json
    $headers     = Get-GraphHeaders $AccessToken

    $session   = Invoke-RestMethod -Uri $sessionUri -Method POST -Headers $headers -Body $sessionBody
    $uploadUrl = $session.uploadUrl

    if (-not $uploadUrl) {
        throw "Failed to create upload session - no uploadUrl returned"
    }

    # 2. Stream file in chunks - never loads more than 20MB into memory at once
    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        $offset    = 0
        $buffer    = New-Object byte[] $chunkSize
        $lastLog   = 0

        while ($offset -lt $fileSize) {
            $bytesRead = $stream.Read($buffer, 0, $chunkSize)
            $chunk     = $buffer[0..($bytesRead - 1)]
            $end       = $offset + $bytesRead - 1

            $chunkHeaders = @{
                "Content-Range" = "bytes $offset-$end/$fileSize"
                "Content-Type"  = "application/octet-stream"
            }

            try {
                Invoke-RestMethod -Uri $uploadUrl -Method PUT -Headers $chunkHeaders -Body $chunk | Out-Null
            } catch {
                # 202 Accepted is normal for intermediate chunks
                if ($_.Exception.Response.StatusCode.value__ -notin @(200, 201, 202)) {
                    throw
                }
            }

            $offset += $bytesRead

            # Log every 10% to avoid flooding the log on a 2GB file
            $pct = [math]::Round($offset * 100 / $fileSize, 0)
            if ($pct -ge $lastLog + 10) {
                Write-Host "  Upload: $pct% ($([math]::Round($offset/1GB,2)) / $([math]::Round($fileSize/1GB,2)) GB)"
                $lastLog = $pct
            }
        }
    } finally {
        $stream.Close()
    }

    Write-Host "  Upload complete"
}

function Remove-OldFileVersions {
    param(
        [string]$DriveId,
        [string]$DriveItemId,
        [string]$AccessToken,
        [int]$KeepVersions = 1
    )

    $headers  = Get-GraphHeaders $AccessToken
    $uri      = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/versions"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
    $versions = $response.value

    # Current version is always first. Never delete it.
    # KeepVersions=0 = current only, KeepVersions=1 = current + 1 previous, etc.
    $toDelete = $versions | Select-Object -Skip 1 | Select-Object -Skip $KeepVersions

    if ($toDelete.Count -eq 0) {
        Write-Host "  No old versions to clean up ($($versions.Count) version(s) total)"
        return
    }

    foreach ($version in $toDelete) {
        $versionId = $version.id
        try {
            Invoke-RestMethod `
                -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/versions/$versionId" `
                -Method DELETE `
                -Headers $headers | Out-Null
        } catch {
            Write-Warning "  Could not delete version $versionId`: $_"
        }
    }

    Write-Host "  Deleted $($toDelete.Count) old version(s)"
}

function Write-LogEntry {
    param(
        [string]$SiteUrl,
        [string]$ListName,
        [string]$AccessToken,
        [string]$FileName,
        [string]$FileSiteUrl,
        [string]$LibraryName,
        [double]$OriginalSizeMB,
        [double]$CompressedSizeMB,
        [double]$SavedMB,
        [int]$SavingsPct
    )

    $headers = Get-GraphHeaders $AccessToken
    $siteId  = Get-SiteId -SiteUrl $SiteUrl -AccessToken $AccessToken
    $listId  = Get-ListId -SiteId $siteId -ListName $ListName -AccessToken $AccessToken

    $body = @{
        fields = @{
            Title             = $FileName
            SiteUrl           = $FileSiteUrl
            LibraryName       = $LibraryName
            OriginalSizeMB    = $OriginalSizeMB
            CompressedSizeMB  = $CompressedSizeMB
            SavedMB           = $SavedMB
            SavingsPct        = $SavingsPct
            ProcessedDate     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    } | ConvertTo-Json -Depth 4

    $uri = "https://graph.microsoft.com/v1.0/sites/$siteId/lists/$listId/items"
    try {
        Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body | Out-Null
        Write-Host "  Log entry written for $FileName"
    } catch {
        Write-Warning "  Could not write log entry for $FileName`: $_"
    }
}

Export-ModuleMember -Function *
