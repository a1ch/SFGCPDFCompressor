# profile.ps1 - runs on Function App startup
# Ghostscript is pre-installed in the Docker image - just verify it's present.

$gs = Get-Command "gs" -ErrorAction SilentlyContinue
if ($gs) {
    Write-Host "Ghostscript ready at $($gs.Source)"
} else {
    Write-Warning "Ghostscript not found. CompressPDFs will fail. Rebuild the Docker image."
}
