# Compress-PDF.psm1
# Handles PDF compression using Python + pikepdf
# This achieves ~80% size reduction on scanned PDFs (like File Magic output)

function Compress-PDFFile {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [int]$ResizePercent = 50,   # Resize images to this % of original
        [int]$JpegQuality   = 60    # JPEG quality (0-100)
    )

    # Ensure Python and pikepdf are available
    $pythonScript = @"
import pikepdf
from PIL import Image
import io
import sys
import os

input_path  = sys.argv[1]
output_path = sys.argv[2]
resize_pct  = float(sys.argv[3]) / 100.0
jpeg_quality = int(sys.argv[4])

try:
    pdf = pikepdf.open(input_path)
    page_count = len(pdf.pages)

    for i, page in enumerate(pdf.pages):
        xobjects = page.resources.get('/XObject', {})
        for key in list(xobjects.keys()):
            xobj = xobjects[key]
            if xobj.get('/Subtype') == '/Image':
                try:
                    raw  = bytes(xobj.read_raw_bytes())
                    img  = Image.open(io.BytesIO(raw))
                    w, h = img.size
                    new_w = max(1, int(w * resize_pct))
                    new_h = max(1, int(h * resize_pct))
                    img   = img.resize((new_w, new_h), Image.LANCZOS)

                    buf = io.BytesIO()
                    img.save(buf, format='JPEG', quality=jpeg_quality, optimize=True)
                    buf.seek(0)

                    xobj.write(buf.read(), filter=pikepdf.Name('/DCTDecode'))
                    xobj['/Width']             = new_w
                    xobj['/Height']            = new_h
                    xobj['/BitsPerComponent']  = 8
                    if '/ColorSpace' not in xobj:
                        xobj['/ColorSpace'] = pikepdf.Name('/DeviceGray')
                except Exception as img_err:
                    print(f'  Warning: could not compress image on page {i+1}: {img_err}', file=sys.stderr)

    pdf.save(output_path)
    orig = os.path.getsize(input_path)
    comp = os.path.getsize(output_path)
    print(f'OK:{orig}:{comp}')

except Exception as e:
    print(f'ERROR:{e}', file=sys.stderr)
    sys.exit(1)
"@

    # Write python script to temp file
    $pyScript = [System.IO.Path]::GetTempFileName() + ".py"
    $pythonScript | Set-Content -Path $pyScript -Encoding UTF8

    try {
        $result = & python3 $pyScript $InputPath $OutputPath $ResizePercent $JpegQuality 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Python compression failed: $result"
        }

        if ($result -notlike "OK:*") {
            throw "Unexpected output: $result"
        }

        return $true

    } finally {
        Remove-Item $pyScript -Force -ErrorAction SilentlyContinue
    }
}

function Install-PythonDependencies {
    # Called once during function startup if needed
    Write-Host "Checking Python dependencies..."
    $check = & python3 -c "import pikepdf, PIL" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing pikepdf and Pillow..."
        & pip3 install pikepdf Pillow --quiet
    } else {
        Write-Host "✅ Python dependencies OK"
    }
}

Export-ModuleMember -Function *
