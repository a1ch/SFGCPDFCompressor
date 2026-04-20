# Compress-PDF.psm1
# Compresses scanned text PDFs using PyMuPDF + img2pdf.
# Strategy: render each page to a target pixel width, convert to 1-bit B&W PNG,
# then repack with img2pdf which passes PNG data losslessly into the PDF.
# Achieves ~80% reduction on large scanned documents vs Ghostscript DPI approach.

function Compress-PDFFile {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [int]$TargetWidth = 900,
        [string]$Mode = "bw"
    )

    $python = (Get-Command "python" -ErrorAction SilentlyContinue)?.Source
    if (-not $python) {
        throw "python not found. Ensure the Docker image includes the python:3.11-slim-bullseye stage."
    }

    Write-Host "  Compressing: $InputPath -> $OutputPath (target width: ${TargetWidth}px, mode: $Mode)"

    $script = @"
import sys, os, fitz, img2pdf, tempfile, traceback
from PIL import Image

input_path  = sys.argv[1]
output_path = sys.argv[2]
target_w    = int(sys.argv[3])
mode        = sys.argv[4]

try:
    doc = fitz.open(input_path)
    print(f'Opened: {len(doc)} pages, {doc[0].rect.width:.0f}x{doc[0].rect.height:.0f} pts', flush=True)
    scale = target_w / doc[0].rect.width

    with tempfile.TemporaryDirectory() as tmpdir:
        png_files = []
        for i, page in enumerate(doc):
            pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), colorspace=fitz.csGRAY)
            img = Image.frombytes('L', [pix.width, pix.height], pix.samples)
            if mode == 'bw':
                img = img.convert('1')
            path = os.path.join(tmpdir, f'p{i:04d}.png')
            img.save(path, format='PNG', optimize=True)
            png_files.append(path)
            if (i + 1) % 50 == 0:
                print(f'  Rendered {i+1}/{len(doc)} pages', flush=True)

        print(f'Assembling {len(png_files)} pages into PDF...', flush=True)
        pdf_bytes = img2pdf.convert(
            sorted(png_files),
            layout_fun=img2pdf.get_layout_fun(
                (img2pdf.in_to_pt(8.5), img2pdf.in_to_pt(11))
            )
        )
        with open(output_path, 'wb') as f:
            f.write(pdf_bytes)

        written = os.path.getsize(output_path)
        print(f'Done: {len(png_files)} pages written, {written} bytes', flush=True)

    doc.close()

except Exception as e:
    print(f'PYTHON ERROR: {e}', flush=True)
    traceback.print_exc()
    sys.exit(1)
"@

    $rand       = [System.IO.Path]::GetRandomFileName()
    $scriptPath = "/tmp/compress_$rand.py"
    $stdoutFile = "/tmp/compress_out_$rand.txt"
    $stderrFile = "/tmp/compress_err_$rand.txt"

    $script | Set-Content -Path $scriptPath -Encoding UTF8

    $proc = Start-Process -FilePath $python `
        -ArgumentList @($scriptPath, $InputPath, $OutputPath, $TargetWidth, $Mode) `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError  $stderrFile

    $stdout = Get-Content $stdoutFile -ErrorAction SilentlyContinue
    $stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue

    if ($stdout) { foreach ($line in $stdout) { Write-Host "  [py] $line" } }
    if ($stderr) { foreach ($line in $stderr) { Write-Warning "  [py err] $line" } }

    Remove-Item $scriptPath, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        throw "Compression failed (exit $($proc.ExitCode)) - see [py] lines above for details"
    }

    if (-not (Test-Path $OutputPath)) {
        throw "Compression completed but output file not found: $OutputPath"
    }

    return $true
}

Export-ModuleMember -Function *
