# profile.ps1 - runs on Function App startup (Linux)
# Attempts to install Ghostscript for PDF compression.
# Logs a warning on failure but does NOT throw - EnqueuePDFs does not
# need Ghostscript and must not be blocked by a compression dependency.

Write-Host "Checking Ghostscript..."
$gs = Get-Command "gs" -ErrorAction SilentlyContinue

if ($gs) {
    Write-Host "Ghostscript ready at $($gs.Source)"
} else {
    Write-Host "Ghostscript not found - attempting install..."

    $aptCheck = Get-Command "apt-get" -ErrorAction SilentlyContinue
    if (-not $aptCheck) {
        Write-Warning "apt-get not available - cannot install Ghostscript. CompressPDFs will fail. Use a custom Docker image with ghostscript pre-installed."
    } else {
        $result = bash -c "sudo apt-get install -y ghostscript 2>&1"
        Write-Host $result

        $gs = Get-Command "gs" -ErrorAction SilentlyContinue
        if ($gs) {
            Write-Host "Ghostscript installed successfully at $($gs.Source)"
        } else {
            Write-Warning "Ghostscript installation failed. CompressPDFs will not be able to compress files. EnqueuePDFs will continue normally."
        }
    }
}
