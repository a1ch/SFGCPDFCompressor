# SharePoint-Helpers.psm1
# All SharePoint operations via Microsoft Graph API (Sites.ReadWrite.All)

# Central retry wrapper - handles 429 and 503 with backoff for all Graph calls
function Invoke-GraphWithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 7
    )
    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
            # Also check error message for activityLimitReached
            $isThrottle = ($statusCode -eq 429 -or $statusCode -eq 503 -or
                           $_.ToString() -match 'activityLimitReached' -or
                           $_.ToString() -match 'throttled')
            if ($isThrottle -and $attempt -lt $MaxRetries) {
                $retryAfter = 30
                try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
                if ($retryAfter -lt 5)  { $retryAfter = 5 }
                if ($retryAfter -gt 120) { $retryAfter = 120 }
                $wait = $retryAfter + [math]::Pow(2, $attempt)
                Write-Warning "  Graph throttled ($statusCode) - waiting $wait s (attempt $($attempt+1)/$MaxRetries)..."
                Start-Sleep -Seconds $wait
                $attempt++
            } else {
                throw
            }
        }
    }
}

function Get-SharePointAccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$ResourceHost = $null
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

    $headers = Get-GraphHeaders $AccessToken
    $response = Invoke-GraphWithRetry { Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/${host}:${path}" -Headers $headers }
    return $response.id
}

function Get-ListId {
    param(
        [string]$SiteId,
        [string]$ListName,
        [string]$AccessToken
    )

    $headers  = Get-GraphHeaders $AccessToken
    $response = Invoke-GraphWithRetry { Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists?`$filter=displayName eq '$ListName'" -Headers $headers }
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

    $headers = Get-GraphHeaders $AccessToken

    # 1. Try display name match via drives endpoint
    $drivesResp = Invoke-GraphWithRetry { Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/drives" -Headers $headers }
    $drive = $drivesResp.value | Where-Object { $_.name -eq $LibraryName } | Select-Object -First 1
    if ($drive) { return $drive.id }

    # 2. Try matching via lists endpoint webUrl internal path segment
    $listsResp = Invoke-GraphWithRetry { Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$SiteId/lists?`$select=id,displayName,webUrl&`$filter=list/template eq 'documentLibrary'" -Headers $headers }
    $matchedList = $listsResp.value | Where-Object {
        $segment = ($_.webUrl -split '/')[-1]
        $segment -ieq $LibraryName
    } | Select-Object -First 1

    if ($matchedList) {
        $drive = $drivesResp.value | Where-Object { $_.name -eq $matchedList.displayName } | Select-Object -First 1
        if ($drive) {
            Write-Host "  Matched '$LibraryName' to library '$($matchedList.displayName)' via internal URL"
            return $drive.id
        }
    }

    $availableDrives = ($drivesResp.value | ForEach-Object { $_.name }) -join ', '
    $availableLists  = ($listsResp.value | ForEach-Object { "$($_.displayName) [$(($_.webUrl -split '/')[-1])]" }) -join ', '
    throw "Drive/Library '$LibraryName' not found on site $SiteId.`n  Drive names: $availableDrives`n  List internal names: $availableLists"
}

function Invoke-GraphPagedRequest {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    $allItems = @()
    $nextUri  = $Uri

    do {
        $response  = Invoke-GraphWithRetry { Invoke-RestMethod -Uri $nextUri -Headers $Headers -Method GET }
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

    Write-Host "  Read-ConfigList: $($items.Count) total items from Graph"

    if ($items.Count -gt 0) {
        $sample = $items[0].fields.Enabled
        Write-Host "  Read-ConfigList: Enabled field sample value='$sample' type=$($sample.GetType().Name)"
    }

    # Handle both boolean true and integer 1 - Graph API returns Yes/No fields inconsistently
    $enabled = $items | Where-Object {
        $val = $_.fields.Enabled
        $val -eq $true -or $val -eq 1 -or $val -eq "true" -or $val -eq "1" -or $val -eq "Yes"
    }

    Write-Host "  Read-ConfigList: $($enabled.Count) enabled targets after filter"
    return $enabled
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
        Invoke-GraphWithRetry { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null }
        Write-Host "  LastCompressed updated for item $ItemId"
    } catch {
        Write-Warning ("  Could not update LastCompressed: " + $_)
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
    $uri      = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId/items/$ItemId/fields"
    $response = Invoke-GraphWithRetry { Invoke-RestMethod -Uri $uri -Headers $headers -Method GET }

    # System fields + all known read-only/calculated SharePoint fields
    $systemFields = @(
        'id', 'ID', 'Title', 'Created', 'Modified', 'AuthorLookupId', 'EditorLookupId',
        'FileLeafRef', 'FileDirRef', 'FileRef', 'FSObjType', 'ContentTypeId',
        '_UIVersionString', '_UIVersion', 'Edit', 'LinkFilenameNoMenu', 'LinkFilename',
        'DocIcon', 'SelectTitle', 'SelectFilename', 'ItemChildCount', 'FolderChildCount',
        'SMTotalSize', 'SMLastModifiedDate', 'SMTotalFileStreamSize', 'SMTotalFileCount',
        '_ComplianceFlags', '_ComplianceTag', '_ComplianceTagWrittenTime', '_ComplianceTagUserId',
        'AccessPolicy', '_VirusStatus', '_VirusVendorID', '_VirusInfo',
        'AppAuthorLookupId', 'AppEditorLookupId',
        # Read-only calculated file fields
        'FileSizeDisplay', 'FileSize', 'File_x0020_Size',
        'CheckoutUser', 'CheckedOutUserId', 'IsCheckedoutToLocal',
        'UniqueId', 'SyncClientId', 'ProgId', 'ScopeId',
        'HTML_x0020_File_x0020_Type', 'MetaInfo',
        'owshiddenversion', 'WorkflowVersion', 'WorkflowInstanceID',
        'ParentVersionString', 'ParentLeafName',
        'ContentVersion', 'UIVersion', 'UIVersionString'
    )

    $metadata = @{}
    $response.PSObject.Properties | Where-Object {
        $_.Name -notin $systemFields -and
        $_.Name -notmatch '^_' -and
        $_.Name -notmatch 'LookupId$' -and
        $_.Name -notmatch 'Display$' -and
        $null -ne $_.Value
    } | ForEach-Object {
        $metadata[$_.Name] = $_.Value
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

    if ($Metadata.Count -eq 0) { return }

    $headers = Get-GraphHeaders $AccessToken
    $uri     = "https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId/items/$ItemId/fields"
    $body    = $Metadata | ConvertTo-Json -Depth 4

    Invoke-GraphWithRetry { Invoke-RestMethod -Uri $uri -Method PATCH -Headers $headers -Body $body | Out-Null }
    Write-Host "  Metadata restored ($($Metadata.Count) field(s))"
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
    Invoke-GraphWithRetry { Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $DestinationPath -Method GET }
}

function Upload-SharePointFile {
    param(
        [string]$DriveId,
        [string]$DriveItemId,
        [string]$FilePath,
        [string]$AccessToken
    )

    $fileSize  = (Get-Item $FilePath).Length
    $chunkSize = 10 * 1024 * 1024  # 10 MB chunks

    Write-Host "  Uploading $([math]::Round($fileSize / 1MB, 2)) MB via upload session ($([math]::Ceiling($fileSize / $chunkSize)) chunks)..."

    $sessionUri  = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/createUploadSession"
    $sessionBody = @{ item = @{ "@microsoft.graph.conflictBehavior" = "replace" } } | ConvertTo-Json
    $headers     = Get-GraphHeaders $AccessToken

    $session   = Invoke-GraphWithRetry { Invoke-RestMethod -Uri $sessionUri -Method POST -Headers $headers -Body $sessionBody }
    $uploadUrl = $session.uploadUrl

    if (-not $uploadUrl) {
        throw "Failed to create upload session - no uploadUrl returned"
    }

    $httpClient = [System.Net.Http.HttpClient]::new()

    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        $offset  = 0
        $buffer  = New-Object byte[] $chunkSize
        $lastLog = 0

        while ($offset -lt $fileSize) {
            $bytesRead = $stream.Read($buffer, 0, $chunkSize)
            $end       = $offset + $bytesRead - 1

            $content = [System.Net.Http.ByteArrayContent]::new($buffer, 0, $bytesRead)
            $content.Headers.Add("Content-Range", "bytes $offset-$end/$fileSize")
            $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/octet-stream")

            $request         = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $uploadUrl)
            $request.Content = $content

            $response   = $httpClient.SendAsync($request).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode

            if (-not $response.IsSuccessStatusCode -and $statusCode -notin @(200, 201, 202, 206)) {
                $errBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                throw "Upload chunk failed ($statusCode): $errBody"
            }

            $offset += $bytesRead

            $pct = [math]::Round($offset * 100 / $fileSize, 0)
            if ($pct -ge $lastLog + 10) {
                Write-Host "  Upload: $pct% ($([math]::Round($offset/1MB,2)) / $([math]::Round($fileSize/1MB,2)) MB)"
                $lastLog = $pct
            }
        }
    } finally {
        $stream.Close()
        $httpClient.Dispose()
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
    $response = Invoke-GraphWithRetry { Invoke-RestMethod -Uri $uri -Headers $headers -Method GET }
    $versions = $response.value

    $toDelete = $versions | Select-Object -Skip $KeepVersions

    if ($toDelete.Count -eq 0) {
        Write-Host "  No old versions to clean up ($($versions.Count) version(s) total)"
        return
    }

    foreach ($version in $toDelete) {
        $encodedVersionId = $version.id -replace '\.', '%2E'
        try {
            Invoke-GraphWithRetry {
                Invoke-RestMethod `
                    -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$DriveItemId/versions/$encodedVersionId" `
                    -Method DELETE `
                    -Headers $headers | Out-Null
            }
        } catch {
            Write-Warning ("  Could not delete version $($version.id): " + $_)
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
        Invoke-GraphWithRetry { Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body | Out-Null }
        Write-Host "  Log entry written for $FileName"
    } catch {
        Write-Warning ("  Could not write log entry for ${FileName}: " + $_)
    }
}

Export-ModuleMember -Function *
