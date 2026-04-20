# Dockerfile for SFGCPDFCompressor
# Builds on the official Azure Functions PowerShell 7.4 Linux image,
# installs Python + PyMuPDF + img2pdf for pixel-targeted 1-bit B&W compression.

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Install Python3, pip, and dependencies
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-pil \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Install PyMuPDF and img2pdf
RUN pip3 install --no-cache-dir --break-system-packages pymupdf img2pdf Pillow

# Verify installs
RUN python3 -c "import fitz, img2pdf, PIL; print('PyMuPDF', fitz.version[0], '/ img2pdf / Pillow OK')"

# Copy all function app code into the image
COPY . /home/site/wwwroot

# Set working directory
WORKDIR /home/site/wwwroot
