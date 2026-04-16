# profile.ps1 - runs on Function App startup (Linux)
# Installs Ghostscript for PDF compression

Write-Host "Checking Ghostscript..."
$gs = Get-Command "gs" -ErrorAction SilentlyContinue
if ($gs) {
    Write-Host "Ghostscript ready at $($gs.Source)"
} else {
    Write-Host "Installing Ghostscript..."
    $result = bash -c "apt-get install -y ghostscript 2>&1"
    Write-Host $result
    $gs = Get-Command "gs" -ErrorAction SilentlyContinue
    if ($gs) {
        Write-Host "Ghostscript installed at $($gs.Source)"
    } else {
        Write-Warning "Ghostscript installation failed - compression will not work"
    }
}
