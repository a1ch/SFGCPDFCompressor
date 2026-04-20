# Dockerfile for SFGCPDFCompressor
# Builds on the official Azure Functions PowerShell 7.4 Linux image,
# installs Python + PyMuPDF + img2pdf via venv to avoid Debian Bookworm pip restrictions.

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Install Python3, pip, and venv
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Create venv and install packages into it
RUN python3 -m venv /opt/pdfvenv \
 && /opt/pdfvenv/bin/pip install --no-cache-dir pymupdf img2pdf Pillow

# Verify installs
RUN /opt/pdfvenv/bin/python -c "import fitz, img2pdf, PIL; print('PyMuPDF', fitz.version[0], '/ img2pdf / Pillow OK')"

# Make venv python the default for our scripts
ENV PATH="/opt/pdfvenv/bin:$PATH"

# Copy all function app code into the image
COPY . /home/site/wwwroot

# Set working directory
WORKDIR /home/site/wwwroot
