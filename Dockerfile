# Dockerfile for SFGCPDFCompressor
# Uses the Azure Functions PowerShell + Python base image so pip works natively.
# No venv needed - Python 3.11 is a first-class citizen on this image.

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4-python3.11

# Install PyMuPDF, img2pdf, and Pillow
RUN pip install --no-cache-dir pymupdf img2pdf Pillow

# Verify installs
RUN python -c "import fitz, img2pdf, PIL; print('PyMuPDF', fitz.version[0], '/ img2pdf / Pillow OK')"

# Copy all function app code into the image
COPY . /home/site/wwwroot

# Set working directory
WORKDIR /home/site/wwwroot
