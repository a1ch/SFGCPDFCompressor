# profile.ps1 - runs on Function App startup (EP2 Linux)
# Installs Ghostscript without sudo - EP2 Linux containers run as root
# so sudo is not available but apt-get works directly.

Write-Host "Checking Ghostscript..."
$gs = Get-Command "gs" -ErrorAction SilentlyContinue

if ($gs) {
    Write-Host "Ghostscript ready at $($gs.Source)"
} else {
    Write-Host "Ghostscript not found - attempting install (no sudo)..."

    $result = bash -c "apt-get update -qq && apt-get install -y --no-install-recommends ghostscript 2>&1"
    Write-Host $result

    $gs = Get-Command "gs" -ErrorAction SilentlyContinue
    if ($gs) {
        Write-Host "Ghostscript installed successfully at $($gs.Source)"
    } else {
        Write-Warning "Ghostscript installation failed. CompressPDFs will not be able to compress files. EnqueuePDFs will continue normally."
    }
}
