# profile.ps1 - runs on Function App startup

$startTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss UTC")
Write-Host "================================================"
Write-Host "  SFGCPDFCOMPRESSOR CONTAINER STARTED"
Write-Host "  Time: $startTime"
Write-Host "  PID:  $PID"
Write-Host "  Host: $env:COMPUTERNAME"
Write-Host "================================================"

# Verify Python is available
$python = Get-Command "python" -ErrorAction SilentlyContinue
if ($python) {
    Write-Host "Python ready at $($python.Source)"
} else {
    Write-Warning "Python not found. CompressPDFs will fail. Ensure Docker image is built correctly."
}
