# CompressPDFs - Queue Trigger
# Processes ONE PDF per execution.
# Downloads, compresses, replaces in SharePoint, restores metadata.

import os
import json
import logging
import tempfile
import azure.functions as func
from shared import graph, compress


def main(msg: func.QueueMessage) -> None:
    raw = msg.get_body().decode("utf-8")
    try:
        file = json.loads(raw)
    except Exception:
        logging.error(f"Could not parse queue message: {raw}")
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

    tenant_id     = os.environ["TENANT_ID"]
    client_id     = os.environ["CLIENT_ID"]
    client_secret = os.environ["CLIENT_SECRET"]
    log_site_url  = os.environ.get("CONFIG_SITE_URL")
    log_list_name = os.environ.get("LOG_LIST_NAME", "SFGCFMCompressorLog")
    keep_versions = int(os.environ.get("KEEP_VERSIONS", "1"))
    step_delay    = float(os.environ.get("STEP_DELAY_MS", "200")) / 1000

    logging.info("========================================")
    logging.info(f"Processing: {file_name} ({original_mb} MB)")
    logging.info(f"Site:       {site_url}")
    logging.info(f"Library:    {library_name}")
    logging.info("========================================")

    with tempfile.TemporaryDirectory() as tmpdir:
        input_path  = os.path.join(tmpdir, "input.pdf")
        output_path = os.path.join(tmpdir, "output.pdf")
        skipped = False

        # 1. Get token
        token = graph.get_token(tenant_id, client_id, client_secret)
        logging.info("Token acquired")

        # 2. Snapshot metadata
        metadata = {}
        if list_id and list_item_id:
            logging.info("Reading column metadata...")
            try:
                metadata = graph.get_file_metadata(site_id, list_id, list_item_id, token)
                logging.info(f"  Captured {len(metadata)} column value(s)")
            except Exception as e:
                logging.warning(f"  Could not read metadata: {e}")
        else:
            logging.warning("  No ListId/ListItemId - column metadata will not be preserved")

        # 3. Download
        logging.info("Downloading from SharePoint...")
        graph.download_file(drive_id, drive_item_id, input_path, token)
        downloaded_mb = round(os.path.getsize(input_path) / 1024 / 1024, 2)
        logging.info(f"Downloaded: {downloaded_mb} MB")

        # 4. Compress
        logging.info("Compressing...")
        compress.compress_pdf(input_path, output_path)

        new_mb  = round(os.path.getsize(output_path) / 1024 / 1024, 2)
        saved_mb = round(original_mb - new_mb, 2)
        pct = round((saved_mb / original_mb) * 100) if original_mb else 0
        logging.info(f"{original_mb} MB -> {new_mb} MB (saved {saved_mb} MB / {pct}%)")

        if pct < 10:
            logging.info("Skipping - less than 10% reduction")
            skipped = True
        else:
            # 5. Refresh token before upload
            logging.info("Refreshing token before upload...")
            token = graph.get_token(tenant_id, client_id, client_secret)

            # 6. Upload
            logging.info("Replacing file in SharePoint...")
            graph.upload_file(drive_id, drive_item_id, output_path, token)

            # 7. Restore metadata
            if list_id and list_item_id and metadata:
                logging.info("Restoring column metadata...")
                try:
                    graph.set_file_metadata(site_id, list_id, list_item_id, metadata, token)
                except Exception as e:
                    logging.warning(f"  Could not restore metadata: {e}")

            # 8. Remove old versions
            graph.remove_old_versions(drive_id, drive_item_id, token, keep=keep_versions)

            logging.info(f"Done - saved {saved_mb} MB")

            # 9. Write log entry
            if log_site_url:
                graph.write_log_entry(
                    log_site_url, log_list_name, token,
                    file_name, site_url, library_name,
                    original_mb, new_mb, saved_mb, pct
                )
