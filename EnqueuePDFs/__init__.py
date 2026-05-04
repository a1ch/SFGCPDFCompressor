# EnqueuePDFs - Timer Trigger
import os
import json
import logging
import azure.functions as func
from datetime import datetime, timezone
from shared import graph


def main(mytimer: func.TimerRequest, outputQueue: func.Out[str]) -> None:
    now_utc = datetime.now(timezone.utc)
    run_date = now_utc.strftime("%A, %B %d, %Y at %H:%M UTC")
    today = now_utc.date()

    logging.info("========================================")
    logging.info(">>> EnqueuePDFs TRIGGERED")
    logging.info(f">>> Time: {run_date}")
    if mytimer.past_due:
        logging.warning(">>> Timer is past due - running late")
    logging.info("========================================")

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

    logging.info(f"Config site:  {config_site}")
    logging.info(f"Config list:  {config_list}")
    logging.info(f"Test Mode:    {test_mode} (limit: {test_limit})")
    logging.info(f"Global Min:   {global_min_mb} MB")

    try:
        logging.info("Authenticating to Graph API...")
        token = graph.get_token(tenant_id, client_id, client_secret)
        logging.info(">>> Authentication successful")
    except Exception as e:
        logging.error(f">>> FATAL: Authentication failed: {e}")
        raise

    try:
        logging.info(f"Reading config list '{config_list}'...")
        targets = graph.read_config_list(config_site, config_list, token)
        logging.info(f">>> Found {len(targets)} enabled target(s)")
    except Exception as e:
        logging.error(f">>> FATAL: Could not read config list: {e}")
        raise

    if not targets:
        logging.info(">>> No enabled targets - nothing to do. Exiting.")
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

        logging.info(f"--- Processing [{label}] {site_url} / {library_name} ---")

        if last_compressed:
            try:
                lc_date = datetime.fromisoformat(last_compressed.rstrip("Z")).date()
                if lc_date >= today:
                    logging.info(f"  SKIPPED - already compressed today ({last_compressed})")
                    skipped_count += 1
                    continue
            except Exception as e:
                logging.warning(f"  Could not parse LastCompressed '{last_compressed}': {e}")

        target_messages = []
        done = [False]

        try:
            logging.info(f"  Getting site ID for {site_url}...")
            site_id  = graph.get_site_id(site_url, token)
            logging.info(f"  site_id: {site_id}")

            logging.info(f"  Getting drive ID for library '{library_name}'...")
            drive_id = graph.get_drive_id(site_id, library_name, token)
            logging.info(f"  drive_id: {drive_id}")

            logging.info(f"  Getting list ID for '{library_name}'...")
            list_id  = graph.get_list_id(site_id, library_name, token)
            logging.info(f"  list_id: {list_id}")

            logging.info(f"  Scanning folders for PDFs > {min_mb} MB...")

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
                        logging.info(f"  Queuing: {item['name']} ({size_mb} MB)")

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
                            logging.info(f"  TEST MODE: Reached limit of {test_limit} files")
                            done[0] = True
                            return

                    uri = data.get("@odata.nextLink")

            root_uri = f"https://graph.microsoft.com/v1.0/drives/{drive_id}/root/children?$select=id,name,size,folder,listItem&$expand=listItem($select=id)&$top=500"
            scan_folder(root_uri)

            target_count = len(target_messages)
            messages.extend(target_messages)
            total_queued += target_count

            logging.info(f"  >>> Enqueued {target_count} file(s) for [{label}]")

            if target_count > 0:
                logging.info("  Refreshing token before updating LastCompressed...")
                token = graph.get_token(tenant_id, client_id, client_secret)
                graph.update_last_compressed(config_site, config_list, item_id, token)
            else:
                logging.info("  No files queued - LastCompressed not updated")

            target_summaries.append({
                "label": label,
                "site_url": site_url,
                "library_name": library_name,
                "count": target_count
            })

        except Exception as e:
            logging.error(f"  >>> ERROR processing [{label}]: {e}")
            import traceback
            logging.error(traceback.format_exc())

    logging.info(f"Pushing {len(messages)} message(s) to queue...")
    for msg in messages:
        outputQueue.set(msg)

    file_log_lines.append("-" * 80)
    file_log_lines.append(f"Total queued: {total_queued} files")
    file_log = "\n".join(file_log_lines)

    logging.info("========================================")
    logging.info(f">>> EnqueuePDFs COMPLETE")
    logging.info(f">>> Total enqueued: {total_queued} files")
    logging.info(f">>> Skipped (already compressed today): {skipped_count}")
    logging.info("========================================")

    try:
        logging.info("Sending summary email...")
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
        logging.info(">>> Summary email sent")
    except Exception as e:
        logging.error(f">>> ERROR sending summary email: {e}")
