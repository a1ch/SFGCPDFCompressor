# Graph-Helpers.psm1
# Handles Microsoft Graph API authentication and email sending

function Get-GraphAccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
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

function Send-SummaryEmail {
    param(
        [string]$GraphToken,
        [string]$FromAddress,
        [string]$ToAddress,
        [string]$Subject,
        [string]$HtmlBody,
        [string]$AttachmentName = $null,   # e.g. "queued-files.txt"
        [string]$AttachmentContent = $null  # plain text content to attach
    )

    $headers = @{
        Authorization  = "Bearer $GraphToken"
        "Content-Type" = "application/json"
    }

    $message = @{
        subject = $Subject
        body    = @{
            contentType = "HTML"
            content     = $HtmlBody
        }
        toRecipients = @(
            @{ emailAddress = @{ address = $ToAddress } }
        )
    }

    # Add attachment if provided
    if ($AttachmentName -and $AttachmentContent) {
        $encodedContent = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($AttachmentContent))
        $message.attachments = @(
            @{
                "@odata.type"  = "#microsoft.graph.fileAttachment"
                name           = $AttachmentName
                contentType    = "text/plain"
                contentBytes   = $encodedContent
            }
        )
    }

    $payload = @{
        message         = $message
        saveToSentItems = $false
    } | ConvertTo-Json -Depth 8

    $uri = "https://graph.microsoft.com/v1.0/users/$FromAddress/sendMail"
    Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $payload | Out-Null
    Write-Host "Summary email sent to $ToAddress"
}

function Build-SummaryEmailHtml {
    param(
        [int]$TotalTargets,
        [int]$TotalQueued,
        [array]$TargetSummaries,
        [string]$RunDate
    )

    $rows = ""
    foreach ($t in $TargetSummaries) {
        $rows += "<tr><td style='padding:6px 12px;border-bottom:1px solid #eee;'>$($t.Label)</td><td style='padding:6px 12px;border-bottom:1px solid #eee;'>$($t.LibraryName)</td><td style='padding:6px 12px;border-bottom:1px solid #eee;text-align:center;'>$($t.Count)</td></tr>"
    }

    return @"
<html><body style='font-family:Arial,sans-serif;color:#333;max-width:700px;margin:0 auto;'>
  <div style='background:#1F4E79;padding:20px 24px;'>
    <h2 style='color:#fff;margin:0;font-size:20px;'>SFGCPDFCompressor - Nightly Run Summary</h2>
    <p style='color:#BDD7EE;margin:4px 0 0;font-size:13px;'>$RunDate</p>
  </div>
  <div style='padding:20px 24px;background:#f9f9f9;'>
    <table style='width:100%;border-collapse:collapse;background:#fff;border:1px solid #ddd;border-radius:4px;'>
      <tr>
        <td style='padding:16px 20px;border-right:1px solid #eee;text-align:center;'>
          <div style='font-size:32px;font-weight:bold;color:#1F4E79;'>$TotalTargets</div>
          <div style='font-size:12px;color:#888;margin-top:4px;'>Libraries Scanned</div>
        </td>
        <td style='padding:16px 20px;text-align:center;'>
          <div style='font-size:32px;font-weight:bold;color:#2E75B6;'>$TotalQueued</div>
          <div style='font-size:12px;color:#888;margin-top:4px;'>Files Queued for Compression</div>
        </td>
      </tr>
    </table>
  </div>
  <div style='padding:0 24px 20px;'>
    <h3 style='font-size:14px;color:#1F4E79;margin-bottom:8px;'>Breakdown by Library</h3>
    <table style='width:100%;border-collapse:collapse;font-size:13px;'>
      <tr style='background:#1F4E79;color:#fff;'>
        <th style='padding:8px 12px;text-align:left;'>Name</th>
        <th style='padding:8px 12px;text-align:left;'>Library</th>
        <th style='padding:8px 12px;text-align:center;'>Files Queued</th>
      </tr>
      $rows
    </table>
  </div>
  <div style='padding:12px 24px;background:#f0f0f0;font-size:11px;color:#999;'>
    See attached queued-files.txt for the full file manifest. Compression results will appear in the SFGCFMCompressorLog SharePoint list.
  </div>
</body></html>
"@
}

Export-ModuleMember -Function *
