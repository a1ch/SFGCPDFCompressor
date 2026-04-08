# Blob-Helpers.psm1
# Handles Azure Blob Storage for temp PDF processing
# Uses the storage account already attached to the Function App (AzureWebJobsStorage)

function Ensure-BlobContainer {
    param([string]$ContainerName = "pdf-processing-temp")

    $ctx = Get-StorageParts
    $date = (Get-Date).ToUniversalTime().ToString('R')
    $headers = New-BlobHeaders -AccountName $ctx.AccountName -AccountKey $ctx.AccountKey `
                               -Method "PUT" -Resource "/$ContainerName" `
                               -Date $date -ContentType "" -ContentLength 0

    $uri = "https://$($ctx.AccountName).blob.core.windows.net/$ContainerName`?restype=container"
    try {
        Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers | Out-Null
    } catch {
        if ($_.Exception.Response.StatusCode -ne 409) {
            Write-Warning "Container note: $_"
        }
    }
    $ctx['Container'] = $ContainerName
    return $ctx
}

function Upload-ToBlob {
    param([string]$FilePath, [string]$BlobName, [hashtable]$StorageContext)

    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)
    $date      = (Get-Date).ToUniversalTime().ToString('R')
    $resource  = "/$($StorageContext.Container)/$BlobName"
    $headers   = New-BlobHeaders -AccountName $StorageContext.AccountName `
                                 -AccountKey $StorageContext.AccountKey `
                                 -Method "PUT" -Resource $resource -Date $date `
                                 -ContentType "application/pdf" `
                                 -ContentLength $fileBytes.Length -BlobType "BlockBlob"

    $uri = "https://$($StorageContext.AccountName).blob.core.windows.net$resource"
    Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $fileBytes | Out-Null
}

function Download-FromBlob {
    param([string]$BlobName, [string]$DestinationPath, [hashtable]$StorageContext)

    $date     = (Get-Date).ToUniversalTime().ToString('R')
    $resource = "/$($StorageContext.Container)/$BlobName"
    $headers  = New-BlobHeaders -AccountName $StorageContext.AccountName `
                                -AccountKey $StorageContext.AccountKey `
                                -Method "GET" -Resource $resource -Date $date `
                                -ContentType "" -ContentLength 0

    $uri = "https://$($StorageContext.AccountName).blob.core.windows.net$resource"
    Invoke-WebRequest -Uri $uri -Method GET -Headers $headers -OutFile $DestinationPath
}

function Delete-Blob {
    param([string]$BlobName, [hashtable]$StorageContext)
    try {
        $date     = (Get-Date).ToUniversalTime().ToString('R')
        $resource = "/$($StorageContext.Container)/$BlobName"
        $headers  = New-BlobHeaders -AccountName $StorageContext.AccountName `
                                    -AccountKey $StorageContext.AccountKey `
                                    -Method "DELETE" -Resource $resource -Date $date `
                                    -ContentType "" -ContentLength 0

        $uri = "https://$($StorageContext.AccountName).blob.core.windows.net$resource"
        Invoke-RestMethod -Uri $uri -Method DELETE -Headers $headers | Out-Null
    } catch {
        Write-Warning "Could not delete blob $BlobName`: $_"
    }
}

function Get-StorageParts {
    $cs = $env:AzureWebJobsStorage
    if (-not $cs) { throw "AzureWebJobsStorage not set" }
    $parts = @{}
    foreach ($p in $cs.Split(';')) {
        $kv = $p.Split('=', 2)
        if ($kv.Count -eq 2) { $parts[$kv[0]] = $kv[1] }
    }
    return @{ AccountName = $parts['AccountName']; AccountKey = $parts['AccountKey'] }
}

function New-BlobHeaders {
    param(
        [string]$AccountName, [string]$AccountKey,
        [string]$Method, [string]$Resource, [string]$Date,
        [string]$ContentType, [long]$ContentLength, [string]$BlobType = ""
    )

    $msHeaders = if ($BlobType) {
        "x-ms-blob-type:$BlobType`nx-ms-date:$Date`nx-ms-version:2020-04-08"
    } else {
        "x-ms-date:$Date`nx-ms-version:2020-04-08"
    }

    $clStr        = if ($ContentLength -gt 0) { $ContentLength.ToString() } else { "" }
    $stringToSign = "$Method`n`n`n$clStr`n`n$ContentType`n`n`n`n`n`n`n$msHeaders`n/$AccountName$Resource"
    $keyBytes     = [Convert]::FromBase64String($AccountKey)
    $hmac         = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key     = $keyBytes
    $sig          = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign)))

    $h = @{
        "x-ms-date"     = $Date
        "x-ms-version"  = "2020-04-08"
        "Authorization" = "SharedKey $AccountName`:$sig"
    }
    if ($ContentType)         { $h["Content-Type"]   = $ContentType }
    if ($ContentLength -gt 0) { $h["Content-Length"] = $ContentLength.ToString() }
    if ($BlobType)            { $h["x-ms-blob-type"] = $BlobType }
    return $h
}

Export-ModuleMember -Function *
