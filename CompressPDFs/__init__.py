# CompressPDFs - Queue Trigger
import os
import json
import logging
import tempfile
import traceback
import azure.functions as func
from shared import graph, compress


def main(msg: func.QueueMessage) -> None:
    raw = msg.get_body().decode("utf-8")

    logging.info("========================================")
    logging.info(">>> CompressPDFs TRIGGERED")
    logging.info(f">>> Queue message ID: {msg.id}")
    logging.info(f">>> Dequeue count: {msg.dequeue_count}")
    logging.info("========================================")

    try:
        file = json.loads(raw)
    except Exception as e:
        logging.error(f">>> FATAL: Could not parse queue message: {e}")
        logging.error(f">>> Raw message: {raw}")
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

    logging.info(f">>> File:     {file_name}")
    logging.info(f">>> Size:     {original_mb} MB")
    logging.info(f">>> Site:     {site_url}")
    logging.info(f">>> Library:  {library_name}")

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
            logging.info("Step 1/7: Acquiring token...")
            token = graph.get_token(tenant_id, client_id, client_secret)
            logging.info(">>> Token acquired")

            logging.info("Step 2/7: Reading column metadata...")
            metadata = {}
            if list_id and list_item_id:
                try:
                    metadata = graph.get_file_metadata(site_id, list_id, list_item_id, token)
                    logging.info(f">>> Captured {len(metadata)} column value(s)")
                except Exception as e:
                    logging.warning(f">>> Could not read metadata (non-fatal): {e}")
            else:
                logging.warning(">>> No ListId/ListItemId - column metadata will not be preserved")

            logging.info("Step 3/7: Downloading file from SharePoint...")
            graph.download_file(drive_id, drive_item_id, input_path, token)
            downloaded_mb = round(os.path.getsize(input_path) / 1024 / 1024, 2)
            logging.info(f">>> Downloaded: {downloaded_mb} MB")

            logging.info("Step 4/7: Compressing PDF...")
            compress.compress_pdf(input_path, output_path)
            new_mb   = round(os.path.getsize(output_path) / 1024 / 1024, 2)
            saved_mb = round(original_mb - new_mb, 2)
            pct      = round((saved_mb / original_mb) * 100) if original_mb else 0
            logging.info(f">>> {original_mb} MB -> {new_mb} MB (saved {saved_mb} MB / {pct}%)")

            if pct < 10:
                logging.info(f">>> SKIPPED - less than 10% reduction ({pct}%), not worth replacing")
                return

            logging.info("Step 5/7: Refreshing token before upload...")
            token = graph.get_token(tenant_id, client_id, client_secret)
            logging.info(">>> Token refreshed")

            logging.info("Step 6/7: Uploading compressed file to SharePoint...")
            graph.upload_file(drive_id, drive_item_id, output_path, token)
            logging.info(">>> Upload complete")

            if list_id and list_item_id and metadata:
                logging.info("Step 6b: Restoring column metadata...")
                try:
                    graph.set_file_metadata(site_id, list_id, list_item_id, metadata, token)
                    logging.info(">>> Metadata restored")
                except Exception as e:
                    logging.warning(f">>> Could not restore metadata (non-fatal): {e}")

            logging.info("Step 7/7: Removing old versions...")
            graph.remove_old_versions(drive_id, drive_item_id, token, keep=keep_versions)

            logging.info("========================================")
            logging.info(f">>> CompressPDFs COMPLETE: {file_name}")
            logging.info(f">>> Saved {saved_mb} MB ({pct}%)")
            logging.info("========================================")

            if log_site_url:
                logging.info("Writing log entry to SharePoint...")
                try:
                    graph.write_log_entry(
                        log_site_url, log_list_name, token,
                        file_name, site_url, library_name,
                        original_mb, new_mb, saved_mb, pct
                    )
                    logging.info(">>> Log entry written")
                except Exception as e:
                    logging.warning(f">>> Could not write log entry (non-fatal): {e}")

        except Exception as e:
            logging.error(f">>> ERROR processing {file_name}: {e}")
            logging.error(traceback.format_exc())
            raise
