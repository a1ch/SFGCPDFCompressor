# Compress-PDF.psm1
# Compresses scanned text PDFs using PyMuPDF + img2pdf.
# Strategy: render each page to a target pixel width, convert to 1-bit B&W PNG,
# then repack with img2pdf which passes PNG data losslessly into the PDF.
# Achieves ~80% reduction on large scanned documents vs Ghostscript DPI approach.

function Compress-PDFFile {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [int]$TargetWidth = 900,      # pixel width of output pages (900 = ~79% reduction on test file)
        [string]$Mode = "bw"          # bw = 1-bit black & white (text), gray = 8-bit grayscale (photos)
    )

    # Use venv python directly - PATH may not carry through to PowerShell child processes
    $python = "/opt/pdfvenv/bin/python"
    if (-not (Test-Path $python)) {
        throw "Python venv not found at $python. Ensure the Docker image was built correctly."
    }

    Write-Host "  Compressing: $InputPath -> $OutputPath (target width: ${TargetWidth}px, mode: $Mode)"

    $script = @"
import sys, os, fitz, img2pdf, tempfile
from PIL import Image

input_path  = sys.argv[1]
output_path = sys.argv[2]
target_w    = int(sys.argv[3])
mode        = sys.argv[4]   # 'bw' or 'gray'

doc = fitz.open(input_path)
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

    with open(output_path, 'wb') as f:
        f.write(img2pdf.convert(
            sorted(png_files),
            layout_fun=img2pdf.get_layout_fun(
                (img2pdf.in_to_pt(8.5), img2pdf.in_to_pt(11))
            )
        ))

doc.close()
print(f'Done: {len(png_files)} pages')
"@

    $scriptPath = "/tmp/compress_pdf.py"
    $script | Set-Content -Path $scriptPath -Encoding UTF8

    $proc = Start-Process -FilePath $python `
        -ArgumentList @($scriptPath, $InputPath, $OutputPath, $TargetWidth, $Mode) `
        -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput "/tmp/compress_out.txt" `
        -RedirectStandardError  "/tmp/compress_err.txt"

    $stdout = Get-Content "/tmp/compress_out.txt" -ErrorAction SilentlyContinue
    $stderr = Get-Content "/tmp/compress_err.txt" -ErrorAction SilentlyContinue

    if ($stdout) { Write-Host "  Python: $stdout" }

    if ($proc.ExitCode -ne 0) {
        throw "Compression failed (exit $($proc.ExitCode)): $stderr"
    }

    if (-not (Test-Path $OutputPath)) {
        throw "Compression completed but output file not found: $OutputPath"
    }

    return $true
}

Export-ModuleMember -Function *
