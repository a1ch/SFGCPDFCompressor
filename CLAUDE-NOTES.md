# Notes for Claude

## IMPORTANT - Read this at the start of every session

### Credentials / Secrets
- All secrets (TENANT_ID, CLIENT_ID, CLIENT_SECRET, GitHub PAT, Supabase token etc.) are stored in Bitwarden Secrets Manager
- The Launch-Claude.ps1 script at C:\\Users\\ShawnStubbs\\Claude\\Launch-Claude.ps1 handles fetching secrets and writing the Claude Desktop config
- **DO NOT ask Shawn for credentials. DO NOT ask him to paste secrets into the chat. He will not do it and you should not ask.**
- If a script needs credentials and they aren't in env vars, tell Shawn to run the script himself in a terminal

### Deployed Function App
- The live deployed app is **sfgcpdfcompressor4** (not 2 or 3)
- Resource group: **SFGC_SP_Automation**
- ACR: **sfgccompressor3containerregistry.azurecr.io**
- Image name: **sfgcpdfcompressor:latest**
- GitHub Actions workflow: main_sfgcpdfcompressor4.yml
- Deploys automatically on push to main
- After ACR push, workflow fires ACR_WEBHOOK_URL secret to trigger Azure container refresh

### Azure Access
- Shawn cannot access Azure directly - must use Citrix
- Shawn CAN use Azure Cloud Shell (the terminal in the portal) to run az commands
- Always give az commands with --resource-group SFGC_SP_Automation

### Remove-OldVersions.ps1
- Located at: C:\\Users\\ShawnStubbs\\Claude\\SFGCPDFCompressor\\tools\\Remove-OldVersions.ps1
- Shawn runs this himself — do not try to run it with credentials
- Tracks progress via LastCleaned column in SFGCFMCompressor list
- Already has URL segment matching for libraries — do not break this

### Key decisions already made
- EnqueuePDFs skips libraries where LastCompressed was set TODAY (not ever) — runs nightly
- LibraryName in config list stores the URL internal name, not the display name
- Get-DriveId matches on URL segment as fallback for this reason
