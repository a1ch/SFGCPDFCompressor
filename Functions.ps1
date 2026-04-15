# Functions.ps1 - Azure Functions v4 PowerShell programming model
# Both functions defined here using Register-AzFunctionTrigger

using namespace Microsoft.Azure.Functions.Worker
using namespace Microsoft.Azure.Functions.Worker.Http

Import-Module "$PSScriptRoot\shared\SharePoint-Helpers.psm1"
Import-Module "$PSScriptRoot\shared\Graph-Helpers.psm1"
Import-Module "$PSScriptRoot\shared\Compress-PDF.psm1"
Import-Module "$PSScriptRoot\shared\Blob-Helpers.psm1"

# ============================================================
# EnqueuePDFs - Timer Trigger (nightly at 2am)
# ============================================================
Register-AzFunctionTrigger -Name "EnqueuePDFs" -Type TimerTrigger -Schedule "0 0 2 * * *" -ScriptBlock {
    param($Timer)

    $tenantId       = $env:TENANT_ID
    $clientId       = $env:CLIENT_ID
    $clientSecret   = $env:CLIENT_SECRET
    $testMode       = $env:TEST_MODE -eq "true"
    $testLimit      = [int]($env:TEST_LIMIT ?? "5")
    $globalMinMB    = [double]($env:MIN_SIZE_MB ?? "5")
    $configSiteUrl  = $env:CONFIG_SITE_URL
    $configListName = $env:CONFIG_LIST_NAME ?? "SFGCFMCompressor"
    $summaryTo      = $env:SUMMARY_EMAIL_TO ?? "sstubbs@streamflo.com"
    $summaryFrom    = $env:SUMMARY_EMAIL_FROM ?? "sstubbs@streamflo.com"
    $storageConn    = $env:AzureWebJobsStorage
    $queueName      = "pdf-compress-queue"

    if (-not $configSiteUrl) {
        Write-Error "CONFIG_SITE_URL app setting is not set."
        throw "Missing CONFIG_SITE_URL"
    }

    $runDate = (Get-Date).ToString("dddd, MMMM d, yyyy 'at' h:mm tt")

    Write-Host "========================================"
    Write-Host "EnqueuePDFs starting"
    Write-Host "Config site:  $configSiteUrl"
    Write-Host "Config list:  $configListName"
    Write-Host "Test Mode:    $testMode (limit: $testLimit per library)"
    Write-Host "Global Min:   $globalMinMB MB"
    Write-Host "Run date:     $runDate"
    Write-Host "========================================"

    # Authenticate
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
    Write-Host "Authenticated to SharePoint"

    $headers = @{ Authorization = "Bearer $accessToken"; Accept = "application/json;odata=verbose" }

    # Read targets list
    Write-Host "Reading targets from '$configListName'..."
    $configUri = "$configSiteUrl/_api/web/lists/getbytitle('$configListName')/items?" +
                 "`$select=Id,Title,SiteUrl,LibraryName,Enabled,MinSizeMB&" +
                 "`$filter=Enabled eq 1&" +
                 "`$top=500"

    $configResponse = Invoke-RestMethod -Uri $configUri -Headers $headers -Method GET
    $targets = $configResponse.d.results
    Write-Host "Found $($targets.Count) enabled target(s)"

    if ($targets.Count -eq 0) {
        Write-Host "No enabled targets - nothing to do."
        return
    }

    # Set up queue client
    $queueClient = [Microsoft.Azure.Storage.Queue.CloudQueueClient]::new(
        [Microsoft.Azure.Storage.CloudStorageAccount]::Parse($storageConn).CreateCloudQueueClient()
    )
    $queue = $queueClient.GetQueueReference($queueName)
    $queue.CreateIfNotExists() | Out-Null

    $totalQueued     = 0
    $targetSummaries = @()

    foreach ($target in $targets) {
        $siteUrl      = $target.SiteUrl.Trim()
        $libraryName  = $target.LibraryName.Trim()
        $label        = $target.Title
        $itemId       = $target.Id
        $minSizeMB    = if ($target.MinSizeMB -and $target.MinSizeMB -gt 0) { $target.MinSizeMB } else { $globalMinMB }
        $minSizeBytes = [long]($minSizeMB * 1MB)

        Write-Host ""
        Write-Host "--- [$label] $siteUrl / $libraryName (min: $minSizeMB MB) ---"

        $siteToken = $accessToken
        if ($siteUrl.TrimEnd('/') -ne $configSiteUrl.TrimEnd('/')) {
            try {
                $siteToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -ResourceHost ([Uri]$siteUrl).Host
            } catch {
                Write-Warning "  Could not get token for $siteUrl - using config site token"
            }
        }

        $siteHeaders  = @{ Authorization = "Bearer $siteToken"; Accept = "application/json;odata=verbose" }
        $uri          = "$siteUrl/_api/web/lists/getbytitle('$libraryName')/items?" +
                        "`$select=Id,File/Name,File/ServerRelativeUrl,File/Length&" +
                        "`$expand=File&" +
                        "`$filter=File/Name ne null&" +
                        "`$top=500"

        $pageCount   = 0
        $targetCount = 0

        try {
            do {
                $response = Invoke-RestMethod -Uri $uri -Headers $siteHeaders -Method GET
                $items    = $response.d.results
                $pageCount++

                foreach ($item in $items) {
                    $f = $item.File
                    if (-not ($f.Name -like "*.pdf")) { continue }
                    if ([long]$f.Length -le $minSizeBytes) { continue }

                    $message = @{
                        Id                = $item.Id
                        Name              = $f.Name
                        ServerRelativeUrl = $f.ServerRelativeUrl
                        SizeMB            = [math]::Round([long]$f.Length / 1MB, 2)
                        SiteUrl           = $siteUrl
                        LibraryName       = $libraryName
                    } | ConvertTo-Json -Compress

                    $queueMsg = [Microsoft.Azure.Storage.Queue.CloudQueueMessage]::new($message)
                    $queue.AddMessage($queueMsg)

                    $totalQueued++
                    $targetCount++

                    if ($testMode -and $targetCount -ge $testLimit) {
                        Write-Host "  TEST MODE: Reached limit of $testLimit files"
                        $uri = $null
                        break
                    }
                }

                Write-Host "  Page $pageCount - queued $targetCount so far..."
                $uri = $response.d.__next

            } while ($uri)

            Write-Host "  Done - enqueued $targetCount file(s)"

            Update-TargetLastCompressed `
                -SiteUrl     $configSiteUrl `
                -ListName    $configListName `
                -AccessToken $accessToken `
                -ItemId      $itemId

            $targetSummaries += @{
                Label       = $label
                SiteUrl     = $siteUrl
                LibraryName = $libraryName
                Count       = $targetCount
            }

        } catch {
            Write-Warning "  Failed for [$label]: $_"
        }
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Total enqueued: $totalQueued files"
    Write-Host "========================================"

    try {
        $graphToken = Get-GraphAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret
        $htmlBody   = Build-SummaryEmailHtml `
                        -TotalTargets    $targets.Count `
                        -TotalQueued     $totalQueued `
                        -TargetSummaries $targetSummaries `
                        -RunDate         $runDate

        Send-SummaryEmail `
            -GraphToken  $graphToken `
            -FromAddress $summaryFrom `
            -ToAddress   $summaryTo `
            -Subject     "PDF Compressor - Nightly Run $((Get-Date).ToString('yyyy-MM-dd')) - $totalQueued files queued" `
            -HtmlBody    $htmlBody
    } catch {
        Write-Warning "Could not send summary email: $_"
    }
}

# ============================================================
# CompressPDFs - Queue Trigger
# ============================================================
Register-AzFunctionTrigger -Name "CompressPDFs" -Type QueueTrigger -QueueName "pdf-compress-queue" -Connection "AzureWebJobsStorage" -ScriptBlock {
    param($QueueItem)

    $tenantId     = $env:TENANT_ID
    $clientId     = $env:CLIENT_ID
    $clientSecret = $env:CLIENT_SECRET
    $logSiteUrl   = $env:CONFIG_SITE_URL
    $logListName  = $env:LOG_LIST_NAME ?? "SFGCFMCompressorLog"
    $keepVersions = [int]($env:KEEP_VERSIONS ?? "1")

    $file           = $QueueItem | ConvertFrom-Json
    $fileName       = $file.Name
    $fileId         = $file.Id
    $serverPath     = $file.ServerRelativeUrl
    $originalSizeMB = $file.SizeMB
    $siteUrl        = $file.SiteUrl
    $libraryName    = $file.LibraryName

    Write-Host "========================================"
    Write-Host "Processing: $fileName ($originalSizeMB MB)"
    Write-Host "Site:       $siteUrl"
    Write-Host "Library:    $libraryName"
    Write-Host "========================================"

    $blobCtx     = Ensure-BlobContainer -ContainerName "pdf-processing-temp"
    $accessToken = Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -ResourceHost ([Uri]$siteUrl).Host

    $logToken = if ($logSiteUrl -and ([Uri]$logSiteUrl).Host -ne ([Uri]$siteUrl).Host) {
        Get-SharePointAccessToken -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret -ResourceHost ([Uri]$logSiteUrl).Host
    } else {
        $accessToken
    }

    $inputBlobName  = "$fileId`_input.pdf"
    $outputBlobName = "$fileId`_output.pdf"
    $tempDir        = [System.IO.Path]::GetTempPath()
    $tempInput      = Join-Path $tempDir $inputBlobName
    $tempOutput     = Join-Path $tempDir $outputBlobName

    try {
        Write-Host "Downloading from SharePoint..."
        Download-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                                -DestinationPath $tempInput -AccessToken $accessToken

        Write-Host "Staging in blob storage..."
        Upload-ToBlob -FilePath $tempInput -BlobName $inputBlobName -StorageContext $blobCtx
        Remove-Item $tempInput -Force

        Write-Host "Compressing..."
        Download-FromBlob -BlobName $inputBlobName -DestinationPath $tempInput -StorageContext $blobCtx
        Compress-PDFFile -InputPath $tempInput -OutputPath $tempOutput | Out-Null

        $newSizeMB = [math]::Round((Get-Item $tempOutput).Length / 1MB, 2)
        $savedMB   = [math]::Round($originalSizeMB - $newSizeMB, 2)
        $pct       = [math]::Round(($savedMB / $originalSizeMB) * 100, 0)
        Write-Host "$originalSizeMB MB -> $newSizeMB MB (saved $savedMB MB / $pct%)"

        if ($pct -lt 10) {
            Write-Host "Skipping - less than 10% reduction"
            return
        }

        Write-Host "Replacing file in SharePoint..."
        Upload-SharePointFile -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                              -FilePath $tempOutput -AccessToken $accessToken

        Remove-OldFileVersions -SiteUrl $siteUrl -ServerRelativeUrl $serverPath `
                               -AccessToken $accessToken -KeepVersions $keepVersions

        Write-Host "Done - saved $savedMB MB"

        if ($logSiteUrl) {
            Write-LogEntry `
                -SiteUrl          $logSiteUrl `
                -ListName         $logListName `
                -AccessToken      $logToken `
                -FileName         $fileName `
                -FileSiteUrl      $siteUrl `
                -LibraryName      $libraryName `
                -OriginalSizeMB   $originalSizeMB `
                -CompressedSizeMB $newSizeMB `
                -SavedMB          $savedMB `
                -SavingsPct       $pct
        }

    } catch {
        Write-Error "Failed: $_"
        throw
    } finally {
        if (Test-Path $tempInput)  { Remove-Item $tempInput  -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempOutput) { Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue }
        Delete-Blob -BlobName $inputBlobName  -StorageContext $blobCtx
        Delete-Blob -BlobName $outputBlobName -StorageContext $blobCtx
    }
}
