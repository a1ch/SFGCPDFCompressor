# Compress-PDF.psm1
# Handles PDF compression using Ghostscript (Windows)

function Compress-PDFFile {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Quality = "ebook"   # screen=72dpi, ebook=150dpi, printer=300dpi
    )

    $gsPath = Find-Ghostscript
    if (-not $gsPath) {
        throw "Ghostscript not found. Ensure profile.ps1 ran successfully."
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
    # Check C:\home\gs first (our install location)
    $homeGs = Get-ChildItem -Path "C:\home\gs" -Recurse -Filter "gswin64c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($homeGs) { return $homeGs.FullName }

    # Check PATH
    foreach ($name in @("gswin64c.exe", "gswin32c.exe", "gs")) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }

    # Check common install directories
    foreach ($dir in @("C:\Program Files\gs", "C:\Program Files (x86)\gs")) {
        if (Test-Path $dir) {
            $exe = Get-ChildItem -Path $dir -Recurse -Filter "gswin64c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { return $exe.FullName }
        }
    }

    return $null
}

Export-ModuleMember -Function *
