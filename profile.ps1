# profile.ps1 - runs on Function App startup (Linux)
# Installs Ghostscript for PDF compression if not already present.
# Throws on failure so the host knows compression won't work.

Write-Host "Checking Ghostscript..."
$gs = Get-Command "gs" -ErrorAction SilentlyContinue

if ($gs) {
    Write-Host "Ghostscript ready at $($gs.Source)"
} else {
    Write-Host "Ghostscript not found - attempting install..."

    $aptCheck = Get-Command "apt-get" -ErrorAction SilentlyContinue
    if (-not $aptCheck) {
        throw "apt-get not available - cannot install Ghostscript. Use a custom Docker image with ghostscript pre-installed."
    }

    $result = bash -c "sudo apt-get install -y ghostscript 2>&1"
    Write-Host $result

    $gs = Get-Command "gs" -ErrorAction SilentlyContinue
    if ($gs) {
        Write-Host "Ghostscript installed successfully at $($gs.Source)"
    } else {
        throw "Ghostscript installation failed. CompressPDFs will not work. Check that the Function App has apt-get write access, or use a custom Docker image with ghostscript pre-installed."
    }
}
