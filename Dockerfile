# Dockerfile for SFGCPDFCompressor
# Install Python via apt, use --break-system-packages for pip installs.
# Safe in Docker - there is no actual system to break in a container.

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Install Python 3 + pip + dev headers for PyMuPDF native extensions
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    python3 \
    python3-dev \
    python3-pip \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Install packages - --break-system-packages is safe and correct in Docker
RUN pip3 install --no-cache-dir --break-system-packages pymupdf img2pdf Pillow

# Symlink so 'python' resolves
RUN ln -sf /usr/bin/python3 /usr/local/bin/python

# Verify all packages load correctly
RUN python -c "import fitz, img2pdf, PIL; print('PyMuPDF', fitz.version[0], '/ img2pdf / Pillow OK')"

# Copy all function app code into the image
COPY . /home/site/wwwroot

WORKDIR /home/site/wwwroot
