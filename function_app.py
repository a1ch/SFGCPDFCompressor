import azure.functions as func
import os
import sys
import json
import logging
import traceback
import tempfile
from datetime import datetime, timezone
from shared import graph, compress

app = func.FunctionApp()


def log(msg):
    print(msg, flush=True)
    logging.info(msg)


def logerr(msg):
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    logging.error(msg)


@app.timer_trigger(schedule="0 15 1 * * *", arg_name="mytimer", run_on_startup=False)
@app.queue_output(arg_name="outputQueue", queue_name="pdf-compress-queue", connection="AzureWebJobsStorage")
def EnqueuePDFs(mytimer: func.TimerRequest, outputQueue: func.Out[str]) -> None:
    now_utc = datetime.now(timezone.utc)
    run_date = now_utc.strftime("%Y-%m-%d %H:%M:%S UTC")
    today = now_utc.date()

    log("========================================")
    log(f">>> EnqueuePDFs TRIGGERED at {run_date}")
    if mytimer.past_due:
        log(">>> WARNING: Timer is past due")
    log("========================================")

    tenant_id     = os.environ["TENANT_ID"]
    client_id     = os.environ["CLIENT_ID"]
    client_secret = os.environ["CLIENT_SECRET"]
    config_site   = os.environ["CONFIG_SITE_URL"]
    config_list   = os.environ.get("CONFIG_LIST_NAME", "SFGCFMCompressor")
    summary_to    = os.environ.get("SUMMARY_EMAIL_TO", "sstubbs@streamflo.com")
    summary_from  = os.environ.get("SUMMARY_EMAIL_FROM", "sstubbs@streamflo.com")
    test_mode     = os.environ.get("TEST_MODE", "").lower() == "true"
    test_limit    = int(os.environ.get("TEST_LIMIT", "5"))
    global_min_mb = float(os.environ.get("MIN_SIZE_MB", "5"))

    log(f"Config site:  {config_site}")
    log(f"Config list:  {config_list}")
    log(f"Test Mode:    {test_mode} (limit: {test_limit})")
    log(f"Global Min:   {global_min_mb} MB")

    try:
        log("Authenticating to Graph API...")
        token = graph.get_token(tenant_id, client_id, client_secret)
        log(">>> Authentication OK")
    except Exception as e:
        logerr(f"FATAL: Authentication failed: {e}")
        logerr(traceback.format_exc())
        raise

    try:
        log(f"Reading config list '{config_list}'...")
        targets = graph.read_config_list(config_site, config_list, token)
        log(f">>> Found {len(targets)} enabled target(s)")
    except Exception as e:
        logerr(f"FATAL: Could not read config list: {e}")
        logerr(traceback.format_exc())
        raise

    if not targets:
        log(">>> No enabled targets - nothing to do. Exiting.")
        return

    total_queued = 0
    target_summaries = []
    skipped_count = 0
    file_log_lines = [
        "SFGCPDFCompressor - Queued File Manifest",
        f"Run: {run_date}",
        "=" * 80,
        "File\tSize\tLibrary\tSite",
        "-" * 80,
    ]
    messages = []

    for target in targets:
        fields       = target.get("fields", {})
        site_url     = fields.get("SiteUrl", "").strip()
        library_name = fields.get("LibraryName", "").strip()
        label        = fields.get("Title", f"{site_url}/{library_name}")
        item_id      = target["id"]
        last_compressed = fields.get("LastCompressed")
        min_mb       = float(fields.get("MinSizeMB") or 0) or global_min_mb
        min_bytes    = int(min_mb * 1024 * 1024)

        log(f"--- Processing [{label}] {site_url} / {library_name} ---")

        if last_compressed:
            try:
                lc_date = datetime.fromisoformat(last_compressed.rstrip("Z")).date()
                if lc_date >= today:
                    log(f"  SKIPPED - already compressed today ({last_compressed})")
                    skipped_count += 1
                    continue
            except Exception as e:
                log(f"  Warning: Could not parse LastCompressed '{last_compressed}': {e}")

        target_messages = []
        done = [False]

        try:
            log(f"  Getting site ID for {site_url}...")
            site_id = graph.get_site_id(site_url, token)
            log(f"  site_id: {site_id}")

            log(f"  Getting drive ID for library '{library_name}'...")
            drive_id = graph.get_drive_id(site_id, library_name, token)
            log(f"  drive_id: {drive_id}")

            log(f"  Getting list ID for '{library_name}'...")
            list_id = graph.get_list_id(site_id, library_name, token)
            log(f"  list_id: {list_id}")

            log(f"  Scanning for PDFs > {min_mb} MB...")

            def scan_folder(folder_url):
                uri = folder_url
                while uri:
                    data = graph.graph_get(uri, token).json()
                    for item in data.get("value", []):
                        if done[0]:
                            return
                        if "folder" in item:
                            sub_uri = f"https://graph.microsoft.com/v1.0/drives/{drive_id}/items/{item['id']}/children?$select=id,name,size,folder,listItem&$expand=listItem($select=id)&$top=500"
                            scan_folder(sub_uri)
                            continue
                        if not item.get("name", "").lower().endswith(".pdf"):
                            continue
                        if int(item.get("size", 0)) <= min_bytes:
                            continue

                        size_mb = round(item["size"] / 1024 / 1024, 2)
                        list_item_id = (item.get("listItem") or {}).get("id")
                        log(f"  Queuing: {item['name']} ({size_mb} MB)")

                        msg = json.dumps({
                            "DriveItemId": item["id"],
                            "DriveId":     drive_id,
                            "SiteId":      site_id,
                            "ListId":      list_id,
                            "ListItemId":  list_item_id,
                            "Name":        item["name"],
                            "SizeMB":      size_mb,
                            "SiteUrl":     site_url,
                            "LibraryName": library_name
                        })
                        target_messages.append(msg)
                        file_log_lines.append(f"{item['name']}\t{size_mb} MB\t{library_name}\t{site_url}")

                        if test_mode and len(target_messages) >= test_limit:
                            log(f"  TEST MODE: Reached limit of {test_limit} files")
                            done[0] = True
                            return

                    uri = data.get("@odata.nextLink")

            root_uri = f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root/children?$select=id,name,size,folder,listItem&$expand=listItem($select=id)&$top=500"
            scan_folder(root_uri)

            target_count = len(target_messages)
            messages.extend(target_messages)
            total_queued += target_count

            log(f"  >>> Enqueued {target_count} file(s) for [{label}]")

            if target_count > 0:
                log("  Refreshing token...")
                token = graph.get_token(tenant_id, client_id, client_secret)
                graph.update_last_compressed(config_site, config_list, item_id, token)
            else:
                log("  No files queued - LastCompressed not updated")

            target_summaries.append({
                "label": label,
                "site_url": site_url,
                "library_name": library_name,
                "count": target_count
            })

        except Exception as e:
            logerr(f"ERROR processing [{label}]: {e}")
            logerr(traceback.format_exc())

    log(f"Pushing {len(messages)} message(s) to queue...")
    for msg in messages:
        outputQueue.set(msg)

    file_log_lines.append("-" * 80)
    file_log_lines.append(f"Total queued: {total_queued} files")
    file_log = "\n".join(file_log_lines)

    log("========================================")
    log(f">>> EnqueuePDFs COMPLETE")
    log(f">>> Total enqueued: {total_queued} files")
    log(f">>> Skipped today:  {skipped_count}")
    log("========================================")

    try:
        log("Sending summary email...")
        token = graph.get_token(tenant_id, client_id, client_secret)
        html = graph.build_summary_email_html(len(targets), total_queued, target_summaries, run_date)
        attach_name = f"queued-files-{now_utc.strftime('%Y-%m-%d')}.txt"
        graph.send_summary_email(
            token, summary_from, summary_to,
            subject=f"PDF Compressor - Nightly Run {now_utc.strftime('%Y-%m-%d')} - {total_queued} files queued",
            html_body=html,
            attachment_name=attach_name,
            attachment_content=file_log
        )
        log(">>> Summary email sent")
    except Exception as e:
        logerr(f"ERROR sending summary email: {e}")
        logerr(traceback.format_exc())


@app.queue_trigger(arg_name="msg", queue_name="pdf-compress-queue", connection="AzureWebJobsStorage")
def CompressPDFs(msg: func.QueueMessage) -> None:
    raw = msg.get_body().decode("utf-8")

    log("========================================")
    log(">>> CompressPDFs TRIGGERED")
    log(f">>> Message ID:     {msg.id}")
    log(f">>> Dequeue count:  {msg.dequeue_count}")
    log("========================================")

    try:
        file = json.loads(raw)
    except Exception as e:
        logerr(f"FATAL: Could not parse queue message: {e}")
        logerr(f"Raw: {raw}")
        raise

    file_name      = file["Name"]
    drive_item_id  = file["DriveItemId"]
    drive_id       = file["DriveId"]
    site_id        = file["SiteId"]
    list_id        = file["ListId"]
    list_item_id   = file.get("ListItemId")
    original_mb    = file["SizeMB"]
    site_url       = file["SiteUrl"]
    library_name   = file["LibraryName"]

    log(f">>> File:     {file_name}")
    log(f">>> Size:     {original_mb} MB")
    log(f">>> Site:     {site_url}")
    log(f">>> Library:  {library_name}")

    tenant_id     = os.environ["TENANT_ID"]
    client_id     = os.environ["CLIENT_ID"]
    client_secret = os.environ["CLIENT_SECRET"]
    log_site_url  = os.environ.get("CONFIG_SITE_URL")
    log_list_name = os.environ.get("LOG_LIST_NAME", "SFGCFMCompressorLog")
    keep_versions = int(os.environ.get("KEEP_VERSIONS", "1"))

    with tempfile.TemporaryDirectory() as tmpdir:
        input_path  = os.path.join(tmpdir, "input.pdf")
        output_path = os.path.join(tmpdir, "output.pdf")

        try:
            log("Step 1/7: Acquiring token...")
            token = graph.get_token(tenant_id, client_id, client_secret)
            log(">>> Token acquired")

            log("Step 2/7: Reading column metadata...")
            metadata = {}
            if list_id and list_item_id:
                try:
                    metadata = graph.get_file_metadata(site_id, list_id, list_item_id, token)
                    log(f">>> Captured {len(metadata)} column value(s)")
                except Exception as e:
                    log(f">>> Warning: Could not read metadata (non-fatal): {e}")
            else:
                log(">>> Warning: No ListId/ListItemId - metadata will not be preserved")

            log("Step 3/7: Downloading from SharePoint...")
            graph.download_file(drive_id, drive_item_id, input_path, token)
            downloaded_mb = round(os.path.getsize(input_path) / 1024 / 1024, 2)
            log(f">>> Downloaded: {downloaded_mb} MB")

            log("Step 4/7: Compressing PDF...")
            compress.compress_pdf(input_path, output_path)
            new_mb   = round(os.path.getsize(output_path) / 1024 / 1024, 2)
            saved_mb = round(original_mb - new_mb, 2)
            pct      = round((saved_mb / original_mb) * 100) if original_mb else 0
            log(f">>> {original_mb} MB -> {new_mb} MB (saved {saved_mb} MB / {pct}%)")

            if pct < 10:
                log(f">>> SKIPPED - only {pct}% reduction, not replacing")
                return

            log("Step 5/7: Refreshing token before upload...")
            token = graph.get_token(tenant_id, client_id, client_secret)
            log(">>> Token refreshed")

            log("Step 6/7: Uploading to SharePoint...")
            graph.upload_file(drive_id, drive_item_id, output_path, token)
            log(">>> Upload complete")

            if list_id and list_item_id and metadata:
                log("Step 6b: Restoring column metadata...")
                try:
                    graph.set_file_metadata(site_id, list_id, list_item_id, metadata, token)
                    log(">>> Metadata restored")
                except Exception as e:
                    log(f">>> Warning: Could not restore metadata (non-fatal): {e}")

            log("Step 7/7: Removing old versions...")
            graph.remove_old_versions(drive_id, drive_item_id, token, keep=keep_versions)

            log("========================================")
            log(f">>> CompressPDFs COMPLETE: {file_name}")
            log(f">>> Saved {saved_mb} MB ({pct}%)")
            log("========================================")

            if log_site_url:
                log("Writing SharePoint log entry...")
                try:
                    graph.write_log_entry(
                        log_site_url, log_list_name, token,
                        file_name, site_url, library_name,
                        original_mb, new_mb, saved_mb, pct
                    )
                    log(">>> Log entry written")
                except Exception as e:
                    log(f">>> Warning: Could not write log entry (non-fatal): {e}")

        except Exception as e:
            logerr(f"FATAL ERROR processing {file_name}: {e}")
            logerr(traceback.format_exc())
            raise
