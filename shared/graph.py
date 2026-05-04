# graph.py - All Microsoft Graph / SharePoint operations
import os
import time
import requests
from urllib.parse import urlparse

GRAPH = "https://graph.microsoft.com/v1.0"

SYSTEM_FIELDS = {
    'id','ID','Title','Created','Modified','AuthorLookupId','EditorLookupId',
    'FileLeafRef','FileDirRef','FileRef','FSObjType','ContentTypeId',
    '_UIVersionString','_UIVersion','Edit','LinkFilenameNoMenu','LinkFilename',
    'DocIcon','SelectTitle','SelectFilename','ItemChildCount','FolderChildCount',
    'SMTotalSize','SMLastModifiedDate','SMTotalFileStreamSize','SMTotalFileCount',
    '_ComplianceFlags','_ComplianceTag','_ComplianceTagWrittenTime','_ComplianceTagUserId',
    'AccessPolicy','_VirusStatus','_VirusVendorID','_VirusInfo',
    'AppAuthorLookupId','AppEditorLookupId',
    'FileSizeDisplay','FileSize','File_x0020_Size',
    'CheckoutUser','CheckedOutUserId','IsCheckedoutToLocal',
    'UniqueId','SyncClientId','ProgId','ScopeId',
    'HTML_x0020_File_x0020_Type','MetaInfo',
    'owshiddenversion','WorkflowVersion','WorkflowInstanceID',
    'ParentVersionString','ParentLeafName',
    'ContentVersion','UIVersion','UIVersionString'
}


def get_token(tenant_id, client_id, client_secret):
    resp = requests.post(
        f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token",
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": "https://graph.microsoft.com/.default",
        }
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def graph_request(method, url, token, max_retries=7, **kwargs):
    """Graph API call with throttle retry."""
    headers = kwargs.pop("headers", {})
    headers["Authorization"] = f"Bearer {token}"
    for attempt in range(max_retries + 1):
        resp = requests.request(method, url, headers=headers, **kwargs)
        if resp.status_code in (429, 503):
            retry_after = int(resp.headers.get("Retry-After", 30))
            wait = max(5, min(120, retry_after)) + (2 ** attempt)
            print(f"  Throttled ({resp.status_code}) - waiting {wait}s (attempt {attempt+1}/{max_retries})")
            time.sleep(wait)
            continue
        resp.raise_for_status()
        return resp
    resp.raise_for_status()


def graph_get(url, token, **kwargs):
    return graph_request("GET", url, token, **kwargs)


def graph_post(url, token, **kwargs):
    return graph_request("POST", url, token, **kwargs)


def graph_patch(url, token, **kwargs):
    return graph_request("PATCH", url, token, **kwargs)


def graph_delete(url, token, **kwargs):
    return graph_request("DELETE", url, token, **kwargs)


def graph_paged(url, token):
    """Fetch all pages from a Graph list endpoint."""
    items = []
    while url:
        data = graph_get(url, token).json()
        items.extend(data.get("value", []))
        url = data.get("@odata.nextLink")
    return items


def get_site_id(site_url, token):
    parsed = urlparse(site_url)
    host = parsed.netloc
    path = parsed.path.rstrip("/")
    return graph_get(f"{GRAPH}/sites/{host}:{path}", token).json()["id"]


def get_list_id(site_id, list_name, token):
    data = graph_get(f"{GRAPH}/sites/{site_id}/lists?$filter=displayName eq '{list_name}'", token).json()
    for item in data.get("value", []):
        if item["displayName"] == list_name:
            return item["id"]
    raise ValueError(f"List '{list_name}' not found on site {site_id}")


def get_drive_id(site_id, library_name, token):
    drives = graph_get(f"{GRAPH}/sites/{site_id}/drives", token).json().get("value", [])
    # 1. Exact drive name match
    for d in drives:
        if d["name"] == library_name:
            print(f"  Matched '{library_name}' by drive display name")
            return d["id"]
    # 2. Match by URL segment or display name via lists
    lists = graph_get(
        f"{GRAPH}/sites/{site_id}/lists?$select=id,displayName,webUrl&$filter=list/template eq 'documentLibrary'",
        token
    ).json().get("value", [])
    for lst in lists:
        segment = lst["webUrl"].split("/")[-1]
        if segment.lower() == library_name.lower() or lst["displayName"].lower() == library_name.lower():
            try:
                drive = graph_get(f"{GRAPH}/sites/{site_id}/lists/{lst['id']}/drive", token).json()
                if drive.get("id"):
                    print(f"  Matched '{library_name}' via list '{lst['displayName']}' -> drive")
                    return drive["id"]
            except Exception as e:
                print(f"  Warning: could not get drive for list '{lst['displayName']}': {e}")
    raise ValueError(f"Drive/Library '{library_name}' not found on site {site_id}")


def read_config_list(site_url, list_name, token):
    site_id = get_site_id(site_url, token)
    list_id = get_list_id(site_id, list_name, token)
    items = graph_paged(
        f"{GRAPH}/sites/{site_id}/lists/{list_id}/items?$expand=fields&$top=500",
        token
    )
    print(f"  read_config_list: {len(items)} total items")
    enabled = []
    for item in items:
        val = item.get("fields", {}).get("Enabled")
        if val in (True, 1, "true", "1", "Yes"):
            enabled.append(item)
    print(f"  read_config_list: {len(enabled)} enabled targets")
    return enabled


def update_last_compressed(site_url, list_name, item_id, token):
    from datetime import datetime, timezone
    site_id = get_site_id(site_url, token)
    list_id = get_list_id(site_id, list_name, token)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        graph_patch(
            f"{GRAPH}/sites/{site_id}/lists/{list_id}/items/{item_id}",
            token,
            json={"fields": {"LastCompressed": now}}
        )
        print(f"  LastCompressed updated for item {item_id}")
    except Exception as e:
        print(f"  Warning: could not update LastCompressed: {e}")


def get_file_metadata(site_id, list_id, item_id, token):
    resp = graph_get(f"{GRAPH}/sites/{site_id}/lists/{list_id}/items/{item_id}/fields", token)
    fields = resp.json()
    return {
        k: v for k, v in fields.items()
        if k not in SYSTEM_FIELDS
        and not k.startswith("_")
        and not k.endswith("LookupId")
        and not k.endswith("Display")
        and v is not None
    }


def set_file_metadata(site_id, list_id, item_id, metadata, token):
    if not metadata:
        return
    graph_patch(
        f"{GRAPH}/sites/{site_id}/lists/{list_id}/items/{item_id}/fields",
        token,
        json=metadata
    )
    print(f"  Metadata restored ({len(metadata)} field(s))")


def download_file(drive_id, item_id, dest_path, token):
    resp = graph_get(
        f"{GRAPH}/drives/{drive_id}/items/{item_id}/content",
        token,
        allow_redirects=True,
        stream=True
    )
    with open(dest_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=8 * 1024 * 1024):
            f.write(chunk)


def upload_file(drive_id, item_id, file_path, token):
    file_size = os.path.getsize(file_path)
    chunk_size = 10 * 1024 * 1024  # 10 MB
    print(f"  Uploading {round(file_size/1024/1024, 2)} MB via upload session ({-(-file_size//chunk_size)} chunks)...")

    session = graph_post(
        f"{GRAPH}/drives/{drive_id}/items/{item_id}/createUploadSession",
        token,
        json={"item": {"@microsoft.graph.conflictBehavior": "replace"}}
    ).json()
    upload_url = session["uploadUrl"]

    offset = 0
    last_log = 0
    with open(file_path, "rb") as f:
        while offset < file_size:
            chunk = f.read(chunk_size)
            end = offset + len(chunk) - 1
            resp = requests.put(
                upload_url,
                data=chunk,
                headers={
                    "Content-Range": f"bytes {offset}-{end}/{file_size}",
                    "Content-Length": str(len(chunk))
                }
            )
            if resp.status_code not in (200, 201, 202, 206):
                raise RuntimeError(f"Upload chunk failed ({resp.status_code}): {resp.text}")
            offset += len(chunk)
            pct = round(offset * 100 / file_size)
            if pct >= last_log + 10:
                print(f"  Upload: {pct}% ({round(offset/1024/1024,2)} / {round(file_size/1024/1024,2)} MB)")
                last_log = pct
    print("  Upload complete")


def remove_old_versions(drive_id, item_id, token, keep=1):
    resp = graph_get(f"{GRAPH}/drives/{drive_id}/items/{item_id}/versions", token)
    versions = resp.json().get("value", [])
    to_delete = versions[keep:]
    if not to_delete:
        print(f"  No old versions to clean ({len(versions)} total)")
        return
    for v in to_delete:
        vid = v["id"].replace(".", "%2E")
        try:
            graph_delete(f"{GRAPH}/drives/{drive_id}/items/{item_id}/versions/{vid}", token)
        except Exception as e:
            print(f"  Warning: could not delete version {v['id']}: {e}")
    print(f"  Deleted {len(to_delete)} old version(s)")


def write_log_entry(site_url, list_name, token, file_name, file_site_url,
                    library_name, original_mb, compressed_mb, saved_mb, savings_pct):
    from datetime import datetime, timezone
    site_id = get_site_id(site_url, token)
    list_id = get_list_id(site_id, list_name, token)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        graph_post(
            f"{GRAPH}/sites/{site_id}/lists/{list_id}/items",
            token,
            json={"fields": {
                "Title": file_name,
                "SiteUrl": file_site_url,
                "LibraryName": library_name,
                "OriginalSizeMB": original_mb,
                "CompressedSizeMB": compressed_mb,
                "SavedMB": saved_mb,
                "SavingsPct": savings_pct,
                "ProcessedDate": now
            }}
        )
        print(f"  Log entry written for {file_name}")
    except Exception as e:
        print(f"  Warning: could not write log entry for {file_name}: {e}")


def send_summary_email(token, from_addr, to_addr, subject, html_body,
                       attachment_name=None, attachment_content=None):
    import base64
    message = {
        "subject": subject,
        "body": {"contentType": "HTML", "content": html_body},
        "toRecipients": [{"emailAddress": {"address": to_addr}}]
    }
    if attachment_name and attachment_content:
        encoded = base64.b64encode(attachment_content.encode("utf-8")).decode("utf-8")
        message["attachments"] = [{
            "@odata.type": "#microsoft.graph.fileAttachment",
            "name": attachment_name,
            "contentType": "text/plain",
            "contentBytes": encoded
        }]
    graph_post(
        f"{GRAPH}/users/{from_addr}/sendMail",
        token,
        json={"message": message, "saveToSentItems": False}
    )
    print(f"Summary email sent to {to_addr}")


def build_summary_email_html(total_targets, total_queued, target_summaries, run_date):
    rows = "".join(
        f"<tr><td style='padding:6px 12px;border-bottom:1px solid #eee;'>{t['label']}</td>"
        f"<td style='padding:6px 12px;border-bottom:1px solid #eee;'>{t['library_name']}</td>"
        f"<td style='padding:6px 12px;border-bottom:1px solid #eee;text-align:center;'>{t['count']}</td></tr>"
        for t in target_summaries
    )
    return f"""
<html><body style='font-family:Arial,sans-serif;color:#333;max-width:700px;margin:0 auto;'>
  <div style='background:#1F4E79;padding:20px 24px;'>
    <h2 style='color:#fff;margin:0;font-size:20px;'>SFGCPDFCompressor - Nightly Run Summary</h2>
    <p style='color:#BDD7EE;margin:4px 0 0;font-size:13px;'>{run_date}</p>
  </div>
  <div style='padding:20px 24px;background:#f9f9f9;'>
    <table style='width:100%;border-collapse:collapse;background:#fff;border:1px solid #ddd;border-radius:4px;'>
      <tr>
        <td style='padding:16px 20px;border-right:1px solid #eee;text-align:center;'>
          <div style='font-size:32px;font-weight:bold;color:#1F4E79;'>{total_targets}</div>
          <div style='font-size:12px;color:#888;margin-top:4px;'>Libraries Scanned</div>
        </td>
        <td style='padding:16px 20px;text-align:center;'>
          <div style='font-size:32px;font-weight:bold;color:#2E75B6;'>{total_queued}</div>
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
      {rows}
    </table>
  </div>
  <div style='padding:12px 24px;background:#f0f0f0;font-size:11px;color:#999;'>
    See attached queued-files.txt for the full file manifest. Compression results will appear in the SFGCFMCompressorLog SharePoint list.
  </div>
</body></html>
"""
