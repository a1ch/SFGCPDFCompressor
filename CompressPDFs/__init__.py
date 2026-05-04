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
