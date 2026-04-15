# profile.ps1 - runs on Function App startup
# Downloads and installs Ghostscript for PDF compression

function Install-GhostscriptFromWeb {
    $gsInstaller = "C:\home\gs_installer.exe"
    $gsDir       = "C:\home\gs"

    # Check if already installed
    $gsExe = Get-ChildItem -Path $gsDir -Recurse -Filter "gswin64c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gsExe) {
        Write-Host "Ghostscript already installed at $($gsExe.FullName)"
        $env:PATH = "$($gsExe.DirectoryName);$env:PATH"
        return $true
    }

    Write-Host "Downloading Ghostscript..."
    try {
        Invoke-WebRequest -Uri "https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10031/gs10031w64.exe" `
                          -OutFile $gsInstaller -UseBasicParsing
        Write-Host "Installing Ghostscript silently..."
        $proc = Start-Process -FilePath $gsInstaller -ArgumentList "/S", "/D=$gsDir" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            $gsExe = Get-ChildItem -Path $gsDir -Recurse -Filter "gswin64c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($gsExe) {
                $env:PATH = "$($gsExe.DirectoryName);$env:PATH"
                Write-Host "Ghostscript installed at $($gsExe.FullName)"
                return $true
            }
        }
        Write-Warning "Ghostscript installer failed with exit code $($proc.ExitCode)"
        return $false
    } catch {
        Write-Warning "Could not download/install Ghostscript: $_"
        return $false
    } finally {
        Remove-Item $gsInstaller -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Checking Ghostscript..."
$gsExe = Get-ChildItem -Path "C:\home\gs" -Recurse -Filter "gswin64c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($gsExe) {
    $env:PATH = "$($gsExe.DirectoryName);$env:PATH"
    Write-Host "Ghostscript ready at $($gsExe.FullName)"
} else {
    Install-GhostscriptFromWeb | Out-Null
}
