# profile.ps1 - runs on Function App startup
# Ensures Ghostscript is installed for PDF compression

Import-Module "$PSScriptRoot\shared\Compress-PDF.psm1"

Write-Host "Checking Ghostscript..."
$gsPath = Find-Ghostscript
if (-not $gsPath) {
    Write-Host "Ghostscript not found - installing..."
    $installed = Install-Ghostscript
    if ($installed) {
        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $gsPath = Find-Ghostscript
        if ($gsPath) {
            Write-Host "Ghostscript ready at: $gsPath"
        } else {
            Write-Warning "Ghostscript installed but not found in PATH yet - may need restart"
        }
    } else {
        Write-Warning "Could not install Ghostscript - compression will fail"
    }
} else {
    Write-Host "Ghostscript ready at: $gsPath"
}
