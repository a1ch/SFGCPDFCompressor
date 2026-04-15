# SharePoint-Helpers.psm1
# Handles all SharePoint REST API operations

function Get-SharePointAccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$ResourceHost = "streamflogroup.sharepoint.com"
    )

    # Use SharePoint-specific scope so the token is accepted by the SharePoint REST API
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://$ResourceHost/.default"
    }

    $response = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method POST `
        -Body $body `
        -ContentType "application/x-www-form-urlencoded"

    return $response.access_token
}

function Get-LargePDFFiles {
    param(
        [string]$SiteUrl,
        [string]$LibraryName,
        [string]$AccessToken,
        [double]$MinSizeMB = 5
    )

    $minSizeBytes = [long]($MinSizeMB * 1MB)
    $headers = @{ Authorization = "Bearer $AccessToken"; Accept = "application/json;odata=verbose" }

    $uri = "$SiteUrl/_api/web/lists/getbytitle('$LibraryName')/items?" +
           "`$select=Id,File/Name,File/ServerRelativeUrl,File/Length,File/UniqueId&" +
           "`$expand=File&" +
           "`$filter=File/Name ne null&" +
           "`$top=500"

    $allFiles = @()

    do {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
        $items = $response.d.results

        foreach ($item in $items) {
            $file = $item.File
            if ($file.Name -like "*.pdf" -and [long]$file.Length -gt $minSizeBytes) {
                $allFiles += [PSCustomObject]@{
                    Id                = $item.Id
                    Name              = $file.Name
                    ServerRelativeUrl = $file.ServerRelativeUrl
                    Length            = [long]$file.Length
                    UniqueId          = $file.UniqueId
                }
            }
        }

        $uri = $response.d.__next
    } while ($uri)

    return $allFiles
}

function Get-FileMetadata {
    param(
        [string]$SiteUrl,
        [string]$FileId,
        [string]$LibraryName,
        [string]$AccessToken
    )

    $headers  = @{ Authorization = "Bearer $AccessToken"; Accept = "application/json;odata=verbose" }
    $uri      = "$SiteUrl/_api/web/lists/getbytitle('$LibraryName')/items($FileId)"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET

    $skipFields = @(
        "ID", "Id", "GUID", "Created", "Modified", "Author", "Editor",
        "FileRef", "FileDirRef", "FileLeafRef", "FSObjType", "ContentTypeId",
        "UniqueId", "ProgId", "ScopeId", "File_x0020_Type", "HTML_x0020_File_x0020_Type",
        "_Level", "_IsCurrentVersion", "owshiddenversion", "CheckedOutUserId",
        "IsCheckedoutToLocal", "CheckoutUser", "EncodedAbsUrl", "BaseName",
        "MetaInfo", "Last_x0020_Modified", "Created_x0020_Date",
        "_EditMenuTableStart", "_EditMenuTableStart2", "_EditMenuTableEnd",
        "LinkFilenameNoMenu", "LinkFilename", "LinkFilename2",
        "DocIcon", "ServerUrl", "EncodedAbsUrl", "Title"
    )

    $metadata = @{}
    $item     = $response.d

    foreach ($prop in $item.PSObject.Properties) {
        $name = $prop.Name
        if ($name -notin $skipFields -and
            $name -notlike "__*" -and
            $name -notlike "odata*" -and
            $prop.Value -ne $null -and
            $prop.Value -isnot [System.Management.Automation.PSCustomObject]) {
            $metadata[$name] = $prop.Value
        }
    }

    return $metadata
}

function Set-FileMetadata {
    param(
        [string]$SiteUrl,
        [string]$FileId,
        [string]$LibraryName,
        [hashtable]$Metadata,
        [string]$AccessToken
    )

    if ($Metadata.Count -eq 0) {
        Write-Host "  No metadata to restore"
        return
    }

    $listItemType = "SP.Data." + ($LibraryName -replace " ", "_x0020_") + "Item"

    $headers = @{
        Authorization   = "Bearer $AccessToken"
        Accept          = "application/json;odata=verbose"
        "Content-Type"  = "application/json;odata=verbose"
        "X-HTTP-Method" = "MERGE"
        "IF-MATCH"      = "*"
    }

    $body = @{ "__metadata" = @{ "type" = $listItemType } }
    $body += $Metadata

    $uri = "$SiteUrl/_api/web/lists/getbytitle('$LibraryName')/items($FileId)"
    Invoke-RestMethod -Uri $uri -Headers $headers -Method POST -Body ($body | ConvertTo-Json -Depth 5) | Out-Null
}

function Download-SharePointFile {
    param(
        [string]$SiteUrl,
        [string]$ServerRelativeUrl,
        [string]$DestinationPath,
        [string]$AccessToken
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    $uri     = "$SiteUrl/_api/web/getfilebyserverrelativeurl('$([Uri]::EscapeDataString($ServerRelativeUrl))')/`$value"
    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $DestinationPath -Method GET
}

function Upload-SharePointFile {
    param(
        [string]$SiteUrl,
        [string]$ServerRelativeUrl,
        [string]$FilePath,
        [string]$AccessToken
    )

    $headers   = @{ Authorization = "Bearer $AccessToken"; Accept = "application/json;odata=verbose" }
    $fileName  = [System.IO.Path]::GetFileName($ServerRelativeUrl)
    $folderUrl = [System.IO.Path]::GetDirectoryName($ServerRelativeUrl).Replace("\", "/")

    $uri = "$SiteUrl/_api/web/getfolderbyserverrelativeurl('$([Uri]::EscapeDataString($folderUrl))')" +
           "/files/add(overwrite=true,url='$([Uri]::EscapeDataString($fileName))')"

    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    Invoke-RestMethod -Uri $uri -Headers $headers -Method POST -Body $fileBytes | Out-Null
}

function Remove-OldFileVersions {
    param(
        [string]$SiteUrl,
        [string]$ServerRelativeUrl,
        [string]$AccessToken,
        [int]$KeepVersions = 1
    )

    $headers  = @{ Authorization = "Bearer $AccessToken"; Accept = "application/json;odata=verbose" }
    $uri      = "$SiteUrl/_api/web/getfilebyserverrelativeurl('$([Uri]::EscapeDataString($ServerRelativeUrl))')/versions"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
    $versions = $response.d.results

    if ($versions.Count -le $KeepVersions) {
        Write-Host "  Only $($versions.Count) version(s) - nothing to clean up"
        return
    }

    $toDelete = $versions | Sort-Object { [double]$_.VersionLabel } -Descending | Select-Object -Skip $KeepVersions

    foreach ($version in $toDelete) {
        $versionId  = $version.ID
        $deleteUri  = "$SiteUrl/_api/web/getfilebyserverrelativeurl('$([Uri]::EscapeDataString($ServerRelativeUrl))')/versions/deletebyid(vid=$versionId)"
        $delHeaders = @{
            Authorization   = "Bearer $AccessToken"
            Accept          = "application/json;odata=verbose"
            "X-HTTP-Method" = "DELETE"
            "IF-MATCH"      = "*"
        }
        try {
            Invoke-RestMethod -Uri $deleteUri -Headers $delHeaders -Method POST | Out-Null
        } catch {
            Write-Warning "  Could not delete version $versionId`: $_"
        }
    }

    Write-Host "  Deleted $($toDelete.Count) old version(s), kept $KeepVersions"
}

function Write-LogEntry {
    param(
        [string]$SiteUrl,
        [string]$ListName = "SFGCFMCompressorLog",
        [string]$AccessToken,
        [string]$FileName,
        [string]$FileSiteUrl,
        [string]$LibraryName,
        [double]$OriginalSizeMB,
        [double]$CompressedSizeMB,
        [double]$SavedMB,
        [int]$SavingsPct
    )

    $listItemType = "SP.Data." + ($ListName -replace " ", "_x0020_") + "Item"

    $headers = @{
        Authorization  = "Bearer $AccessToken"
        Accept         = "application/json;odata=verbose"
        "Content-Type" = "application/json;odata=verbose"
    }

    $body = @{
        "__metadata"       = @{ "type" = $listItemType }
        "Title"            = $FileName
        "SiteUrl"          = $FileSiteUrl
        "LibraryName"      = $LibraryName
        "OriginalSizeMB"   = $OriginalSizeMB
        "CompressedSizeMB" = $CompressedSizeMB
        "SavedMB"          = $SavedMB
        "SavingsPct"       = $SavingsPct
        "ProcessedDate"    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json -Depth 4

    $uri = "$SiteUrl/_api/web/lists/getbytitle('$ListName')/items"
    try {
        Invoke-RestMethod -Uri $uri -Headers $headers -Method POST -Body $body | Out-Null
        Write-Host "  Log entry written for $FileName"
    } catch {
        Write-Warning "  Could not write log entry for $FileName`: $_"
    }
}

function Update-TargetLastCompressed {
    param(
        [string]$SiteUrl,
        [string]$ListName = "SFGCFMCompressor",
        [string]$AccessToken,
        [int]$ItemId
    )

    $listItemType = "SP.Data." + ($ListName -replace " ", "_x0020_") + "Item"

    $headers = @{
        Authorization   = "Bearer $AccessToken"
        Accept          = "application/json;odata=verbose"
        "Content-Type"  = "application/json;odata=verbose"
        "X-HTTP-Method" = "MERGE"
        "IF-MATCH"      = "*"
    }

    $body = @{
        "__metadata"     = @{ "type" = $listItemType }
        "LastCompressed" = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    } | ConvertTo-Json -Depth 3

    $uri = "$SiteUrl/_api/web/lists/getbytitle('$ListName')/items($ItemId)"
    try {
        Invoke-RestMethod -Uri $uri -Headers $headers -Method POST -Body $body | Out-Null
        Write-Host "  LastCompressed updated for item $ItemId"
    } catch {
        Write-Warning "  Could not update LastCompressed for item $ItemId`: $_"
    }
}

Export-ModuleMember -Function *
