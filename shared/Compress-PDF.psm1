# Compress-PDF.psm1
# Handles PDF compression using Ghostscript (Linux)

function Compress-PDFFile {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Quality = "ebook"   # screen=72dpi, ebook=150dpi, printer=300dpi
    )

    # On Linux, gs is installed via apt-get in profile.ps1
    $gsPath = (Get-Command "gs" -ErrorAction SilentlyContinue)?.Source
    if (-not $gsPath) {
        throw "Ghostscript (gs) not found. Ensure profile.ps1 ran successfully."
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

    $proc = Start-Process -FilePath $gsPath -ArgumentList $args -Wait -PassThru -NoNewWindow -RedirectStandardError "/tmp/gs_error.txt"

    if ($proc.ExitCode -ne 0) {
        $errText = Get-Content "/tmp/gs_error.txt" -ErrorAction SilentlyContinue
        throw "Ghostscript failed (exit $($proc.ExitCode)): $errText"
    }

    if (-not (Test-Path $OutputPath)) {
        throw "Ghostscript completed but output file not found: $OutputPath"
    }

    return $true
}

Export-ModuleMember -Function *
