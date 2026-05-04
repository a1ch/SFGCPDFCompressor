import os
import sys
import json
import logging
import tempfile
import traceback
import azure.functions as func
from shared import graph, compress


def log(msg):
    print(msg, flush=True)
    logging.info(msg)


def logerr(msg):
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    logging.error(msg)


def main(msg: func.QueueMessage) -> None:
    raw = msg.get_body().decode("utf-8")
    log("========================================")
    log(">>> CompressPDFs TRIGGERED")
    log(f">>> Message ID: {msg.id} | Dequeue count: {msg.dequeue_count}")
    log("========================================")

    try:
        file = json.loads(raw)
    except Exception as e:
        logerr(f"FATAL: Could not parse queue message: {e}")
        raise

    file_name     = file["Name"]
    drive_item_id = file["DriveItemId"]
    drive_id      = file["DriveId"]
    site_id       = file["SiteId"]
    list_id       = file["ListId"]
    list_item_id  = file.get("ListItemId")
    original_mb   = file["SizeMB"]
    site_url      = file["SiteUrl"]
    library_name  = file["LibraryName"]

    log(f">>> File: {file_name} | Size: {original_mb} MB | Library: {library_name}")

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
            log("Step 1: Acquiring token...")
            token = graph.get_token(tenant_id, client_id, client_secret)
            log(">>> Token acquired")

            log("Step 2: Reading metadata...")
            metadata = {}
            if list_id and list_item_id:
                try:
                    metadata = graph.get_file_metadata(site_id, list_id, list_item_id, token)
                    log(f">>> {len(metadata)} column(s) captured")
                except Exception as e:
                    log(f">>> Warning: metadata read failed: {e}")

            log("Step 3: Downloading from SharePoint...")
            graph.download_file(drive_id, drive_item_id, input_path, token)
            log(f">>> Downloaded: {round(os.path.getsize(input_path)/1024/1024,2)} MB")

            log("Step 4: Compressing...")
            compress.compress_pdf(input_path, output_path)
            new_mb   = round(os.path.getsize(output_path)/1024/1024, 2)
            saved_mb = round(original_mb - new_mb, 2)
            pct      = round((saved_mb / original_mb) * 100) if original_mb else 0
            log(f">>> {original_mb} MB -> {new_mb} MB ({pct}% saved)")

            if pct < 10:
                log(f">>> SKIPPED - only {pct}% reduction")
                return

            log("Step 5: Refreshing token...")
            token = graph.get_token(tenant_id, client_id, client_secret)

            log("Step 6: Uploading to SharePoint...")
            graph.upload_file(drive_id, drive_item_id, output_path, token)
            log(">>> Upload complete")

            if list_id and list_item_id and metadata:
                try:
                    graph.set_file_metadata(site_id, list_id, list_item_id, metadata, token)
                    log(">>> Metadata restored")
                except Exception as e:
                    log(f">>> Warning: metadata restore failed: {e}")

            log("Step 7: Removing old versions...")
            graph.remove_old_versions(drive_id, drive_item_id, token, keep=keep_versions)

            log("========================================")
            log(f">>> CompressPDFs COMPLETE: {file_name} - saved {saved_mb} MB ({pct}%)")
            log("========================================")

            if log_site_url:
                try:
                    graph.write_log_entry(log_site_url, log_list_name, token,
                                          file_name, site_url, library_name,
                                          original_mb, new_mb, saved_mb, pct)
                    log(">>> SharePoint log entry written")
                except Exception as e:
                    log(f">>> Warning: log entry failed: {e}")

        except Exception as e:
            logerr(f"FATAL ERROR: {file_name}: {e}")
            logerr(traceback.format_exc())
            raise
