# profile.ps1 - runs on Function App startup
# Compression now uses Python/PyMuPDF/img2pdf (baked into Docker image).
# Just verify Python is available.

$python = Get-Command "python" -ErrorAction SilentlyContinue
if ($python) {
    Write-Host "Python ready at $($python.Source)"
} else {
    Write-Warning "Python not found. CompressPDFs will fail. Ensure Docker image is built correctly."
}
