# TODO - Rotate Secrets

The following secrets were exposed in chat and need to be rotated:

## 1. Azure Storage Account Key (sfgcspautomation9bf0)
- Go to **portal.azure.com → Storage accounts → sfgcspautomation9bf0 → Security → Access keys**
- Click **Rotate key1** (or key2)
- Update the new connection string in App Settings for:
  - `sfgcpdfcompressor4` → `AzureWebJobsStorage` and `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`
  - Any other apps using this storage account

## 2. Azure Container Registry Password (sfgccompressor3containerregistry)
- Go to **portal.azure.com → Container registries → sfgccompressor3containerregistry → Access keys**
- Click **Regenerate** on password1
- Update in:
  - `sfgcpdfcompressor4` App Settings → `DOCKER_REGISTRY_SERVER_PASSWORD`
  - GitHub secret → `ACR_PASSWORD`

## 3. App Registration Client Secret
- Go to **portal.azure.com → Entra ID → App registrations → your app → Certificates & secrets**
- Delete the old secret, create a new one
- Update `CLIENT_SECRET` in `sfgcpdfcompressor4` App Settings

## 4. GitHub Secrets to update after rotating
- `ACR_PASSWORD`
- `AZURE_FUNCTIONAPP_PUBLISH_PROFILE_4` (re-download from portal if needed)
