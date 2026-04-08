# SFGCPDFCompressor

Azure Function that compresses oversized PDF files in SharePoint document libraries, 
preserving all metadata fields dynamically. Built to clean up large scanned PDFs 
produced by File Magic and similar tools.

## What it does

- Scans a SharePoint library for PDFs larger than a configurable size threshold
- Downloads each file, compresses images inside the PDF (~80% size reduction)
- Re-uploads the compressed file to the same location
- Restores all metadata columns dynamically (works with any library, any fields)
- Logs results including size saved per file

## Architecture

```
Timer Trigger (nightly at 2am)
  → Get large PDFs from SharePoint library
  → For each file:
      1. Read all metadata
      2. Download file
      3. Compress PDF (Python/pikepdf)
      4. Upload compressed file
      5. Restore metadata
  → Log summary
```

## Setup

### 1. Create Azure Function App

- Runtime: PowerShell 7.4
- Functions version: ~4
- OS: Linux (required for Python)

### 2. App Settings (Environment Variables)

| Setting | Description | Example |
|---------|-------------|---------|
| `TENANT_ID` | Azure AD Tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `CLIENT_ID` | App Registration Client ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `CLIENT_SECRET` | App Registration Client Secret | `your-secret` |
| `SHAREPOINT_SITE_URL` | Full SharePoint site URL | `https://streamflogroup.sharepoint.com/sites/projects` |
| `SHAREPOINT_HOST` | SharePoint hostname | `streamflogroup.sharepoint.com` |
| `LIBRARY_NAME` | Document library name | `Documents` |
| `TEST_MODE` | Limit to TEST_LIMIT files | `true` or `false` |
| `TEST_LIMIT` | Max files in test mode | `3` |
| `MIN_SIZE_MB` | Only process files larger than this | `5` |

### 3. App Registration Permissions

The App Registration needs:
- `Sites.ReadWrite.All` (SharePoint)

Or use legacy SharePoint App-Only:
- Register at: `https://streamflogroup.sharepoint.com/_layouts/15/appregnew.aspx`
- Grant permissions at: `https://streamflogroup.sharepoint.com/_layouts/15/appinv.aspx`

### 4. Deploy

```bash
# From VS Code with Azure Functions extension
# Or via Azure CLI:
func azure functionapp publish <your-function-app-name>
```

## Testing

1. Set `TEST_MODE=true` and `TEST_LIMIT=3` in App Settings
2. Run the function manually from Azure Portal → Functions → CompressPDFs → Test/Run
3. Check logs for output
4. Verify 3 files in SharePoint are compressed and metadata is intact
5. Once happy, set `TEST_MODE=false` to process all files

## Adjusting Compression

In `shared/Compress-PDF.psm1`:

| Parameter | Default | Effect |
|-----------|---------|--------|
| `ResizePercent` | `50` | Resize images to 50% — increase for better quality |
| `JpegQuality` | `60` | JPEG quality — increase for better quality, larger files |

For the File Magic scanned PDFs (3392x4399 px images), 50% resize + quality 60 
gives ~80% file size reduction with perfectly readable output.

## File Structure

```
SFGCPDFCompressor/
├── host.json
├── local.settings.json       ← fill in your settings (don't commit secrets!)
├── profile.ps1               ← installs Python deps on startup
├── requirements.psd1
├── CompressPDFs/
│   ├── function.json         ← timer trigger (runs nightly at 2am)
│   └── run.ps1               ← main function logic
└── shared/
    ├── SharePoint-Helpers.psm1  ← all SharePoint REST API calls
    └── Compress-PDF.psm1        ← PDF compression via Python/pikepdf
```

## Notes

- The function uses the **SharePoint REST API directly** (no PnP module needed)
- Metadata fields are read **dynamically** — works with any library structure
- Files are skipped if compression saves less than 10%
- Temp files are cleaned up after each file regardless of success/failure
- Processing is resumable — failed files will be retried next run
