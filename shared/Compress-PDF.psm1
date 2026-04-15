# Compress-PDF.psm1
# Handles PDF compression using Ghostscript (Windows)
# Achieves ~60-80% size reduction on scanned PDFs

function Compress-PDFFile {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Quality = "ebook"   # screen=72dpi, ebook=150dpi, printer=300dpi
    )

    # Find Ghostscript executable
    $gsPath = Find-Ghostscript
    if (-not $gsPath) {
        throw "Ghostscript not found. Install it or check PATH."
    }

    Write-Host "  Using Ghostscript: $gsPath"

    $args = @(
        "-sDEVICE=pdfwrite",
        "-dCompatibilityLevel=1.4",
        "-dPDFSETTINGS=/$Quality",
        "-dNOPAUSE",
        "-dQUIET",
        "-dBATCH",
        "-dColorImageResolution=150",
        "-dGrayImageResolution=150",
        "-dMonoImageResolution=150",
        "-sOutputFile=$OutputPath",
        $InputPath
    )

    $proc = Start-Process -FilePath $gsPath -ArgumentList $args -Wait -PassThru -NoNewWindow -RedirectStandardError "$env:TEMP\gs_error.txt"

    if ($proc.ExitCode -ne 0) {
        $errText = Get-Content "$env:TEMP\gs_error.txt" -ErrorAction SilentlyContinue
        throw "Ghostscript failed (exit $($proc.ExitCode)): $errText"
    }

    if (-not (Test-Path $OutputPath)) {
        throw "Ghostscript completed but output file not found: $OutputPath"
    }

    return $true
}

function Find-Ghostscript {
    # Check common install paths on Windows
    $candidates = @(
        "gswin64c.exe",
        "gswin32c.exe",
        "gs"
    )

    # Check PATH first
    foreach ($name in $candidates) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }

    # Check common install directories
    $dirs = @(
        "C:\Program Files\gs",
        "C:\Program Files (x86)\gs"
    )

    foreach ($dir in $dirs) {
        if (Test-Path $dir) {
            $exe = Get-ChildItem -Path $dir -Recurse -Filter "gswin64c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
            $exe = Get-ChildItem -Path $dir -Recurse -Filter "gswin32c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }

    return $null
}

function Install-Ghostscript {
    Write-Host "Installing Ghostscript via winget..."
    try {
        $proc = Start-Process -FilePath "winget" -ArgumentList "install", "--id", "ArtifexSoftware.GhostScript", "--silent", "--accept-package-agreements", "--accept-source-agreements" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -eq 0) {
            Write-Host "Ghostscript installed successfully"
            return $true
        } else {
            Write-Warning "winget install failed with exit code $($proc.ExitCode)"
            return $false
        }
    } catch {
        Write-Warning "Could not install Ghostscript: $_"
        return $false
    }
}

Export-ModuleMember -Function *
