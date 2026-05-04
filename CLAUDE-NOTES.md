# Notes for Claude

## IMPORTANT - Read this at the start of every session

### Credentials / Secrets
- All secrets (TENANT_ID, CLIENT_ID, CLIENT_SECRET, GitHub PAT, Supabase token etc.) are stored in Bitwarden Secrets Manager
- The Launch-Claude.ps1 script at C:\Users\ShawnStubbs\Claude\Launch-Claude.ps1 handles fetching secrets and writing the Claude Desktop config
- **DO NOT ask Shawn for credentials. DO NOT ask him to paste secrets into the chat. He will not do it and you should not ask.**
- If a script needs credentials and they aren't in env vars, tell Shawn to run the script himself in a terminal

### Architecture - PURE PYTHON (as of May 2026)
- App was rewritten from PowerShell+Docker to pure Python Azure Functions
- NO Docker container - deploys as Python zip via GitHub Actions
- Runtime: Python 3.11, Azure Functions v2
- shared/graph.py - all Graph/SharePoint API helpers
- shared/compress.py - PDF compression (PyMuPDF + img2pdf + Pillow)
- EnqueuePDFs/__init__.py - timer trigger
- CompressPDFs/__init__.py - queue trigger
- requirements.txt - pymupdf, img2pdf, Pillow, requests, azure-functions

### Deployed Function App
- The live deployed app is **sfgcpdfcompressor5**
- URL: sfgcpdfcompressor5-agagcccrhje8g7et.canadacentral-01.azurewebsites.net
- Resource group: **sfgcpdfcompressor5_group**
- GitHub Actions workflow: main_sfgcpdfcompressor5.yml
- Deploys automatically on push to main via zip deploy
- WEBSITE_RUN_FROM_PACKAGE=0 (writeable wwwroot)
- SCM enabled

### Azure Access
- Shawn cannot access Azure directly - must use Citrix
- Shawn CAN use Azure Cloud Shell (the terminal in the portal) to run az commands
- Always give az commands with --resource-group sfgcpdfcompressor5_group

### Remove-OldVersions.ps1
- Located at: C:\Users\ShawnStubbs\Claude\SFGCPDFCompressor\tools\Remove-OldVersions.ps1
- Shawn runs this himself - do not try to run it with credentials
- Tracks progress via LastCleaned column in SFGCFMCompressor list
- Already has URL segment matching for libraries - do not break this

### Key decisions already made
- EnqueuePDFs skips libraries where LastCompressed was set TODAY (not ever) - runs nightly
- LibraryName in config list stores the URL internal name, not the display name
- Get-DriveId matches on URL segment as fallback for this reason
- Timer is 23:45 UTC (6:45pm Mountain) with runOnStartup true
- Min 10% reduction threshold before replacing file
