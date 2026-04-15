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

    # Convert https://streamflogroup.sharepoint.com/sites/FileMagicUK
    # to Graph site lookup: /sites/streamflogroup.sharepoint.com:/sites/FileMagicUK
    $uri = [Uri]$SiteUrl
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
    $encoded  = [Uri]::EscapeDataString($ListName)
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

function Get-LargePDFsFromLibrary {
    param(
        [string]$SiteUrl,
        [string]$LibraryName,
        [string]$AccessToken,
        [double]$MinSizeMB = 5
    )

    $minSizeBytes = [long]($MinSizeMB * 1MB)
    $headers      = Get-GraphHeaders $AccessToken
    $siteId       = Get-SiteId -SiteUrl $SiteUrl -AccessToken $AccessToken
    $driveId      = Get-DriveId -SiteId $siteId -LibraryName $LibraryName -AccessToken $AccessToken

    $uri   = "https://graph.microsoft.com/v1.0/drives/$driveId/root/children?`$select=id,name,size,parentReference&`$top=500"
    $items = Invoke-GraphPagedRequest -Uri $uri -Headers $headers

    $pdfs = @()
    foreach ($item in $items) {
        if ($item.name -like "*.pdf" -and [long]$item.size -gt $minSizeBytes) {
            $pdfs += [PSCustomObject]@{
                DriveItemId = $item.id
                DriveId     = $driveId
                SiteId      = $siteId
                Name        = $item.name
                SizeMB      = [math]::Round([long]$item.size / 1MB, 2)
                SiteUrl     = $SiteUrl
                LibraryName = $LibraryName
            }
        }
    }

    return $pdfs
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

function Get-FileMetadata {
    param(
        [string]$SiteId,
        [string]$ListId,
        [string]$ItemId,
        [string]$AccessToken
    )

    $headers  = Get-GraphHeaders $AccessToken
    $uri      = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId/items/$ItemId?`$expand=fields"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers

    $skipFields = @(
        "id", "createdDateTime", "lastModifiedDateTime", "eTag", "cTag",
        "createdBy", "lastModifiedBy", "parentReference", "fileSystemInfo",
        "ContentType", "Modified", "Created", "Author", "Editor",
        "_UIVersionString", "Attachments", "Edit", "LinkTitleNoMenu",
        "LinkTitle", "DocIcon", "FileLeafRef", "FileRef", "FileDirRef",
        "FSObjType", "SortBehavior", "ProgId", "ScopeId", "UniqueId",
        "HTML_x0020_File_x0020_Type", "File_x0020_Type", "MetaInfo",
        "owshiddenversion", "_Level", "_IsCurrentVersion", "ItemChildCount",
        "FolderChildCount", "SMTotalSize", "SMLastModifiedDate"
    )

    $metadata = @{}
    foreach ($prop in $response.fields.PSObject.Properties) {
        if ($prop.Name -notin $skipFields -and
            $prop.Name -notlike "@*" -and
            $prop.Name -notlike "odata*" -and
            $null -ne $prop.Value) {
            $metadata[$prop.Name] = $prop.Value
        }
    }

    return $metadata
}

function Set-FileMetadata {
    param(
        [string]$SiteId,
        [string]$ListId,
        [string]$ItemId,
        [hashtable]$Metadata,
        [string]$AccessToken
    )

    if ($Metadata.Count -eq 0) {
        Write-Host "  No metadata to restore"
        return
    }

    $headers = Get-GraphHeaders $AccessToken
    $body    = @{ fields = $Metadata } | ConvertTo-Json -Depth 5
    $uri     = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId/items/$ItemId"

    try {
        Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null
        Write-Host "  Metadata restored"
    } catch {
        Write-Warning "  Could not restore metadata: $_"
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

    $headers   = @{ Authorization = "Bearer $AccessToken"; "Content-Type" = "application/octet-stream" }
    $uri       = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/content"
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $fileBytes | Out-Null
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

    if ($versions.Count -le $KeepVersions) {
        Write-Host "  Only $($versions.Count) version(s) - nothing to clean up"
        return
    }

    $toDelete = $versions | Sort-Object lastModifiedDateTime -Descending | Select-Object -Skip $KeepVersions

    foreach ($version in $toDelete) {
        $versionId = $version.id
        try {
            Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/versions/$versionId/restoreVersion" -Method POST -Headers $headers | Out-Null
        } catch {
            Write-Warning "  Could not delete version $versionId`: $_"
        }
    }

    Write-Host "  Cleaned up $($toDelete.Count) old version(s)"
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
