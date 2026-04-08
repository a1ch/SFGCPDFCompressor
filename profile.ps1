# profile.ps1 - runs on Function App startup

# Install Python dependencies needed for PDF compression
Write-Host "Checking Python dependencies for PDF compression..."
try {
    $check = & python3 -c "import pikepdf, PIL" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing pikepdf and Pillow..."
        & pip3 install pikepdf Pillow --quiet --break-system-packages
        Write-Host "✅ Python dependencies installed"
    } else {
        Write-Host "✅ Python dependencies already available"
    }
} catch {
    Write-Warning "Could not verify Python dependencies: $_"
}
