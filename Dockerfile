# Dockerfile for SFGCPDFCompressor
# Install Python via apt in the final stage (avoids shared library copy guesswork),
# then pip install our packages. pip is available because we install python3-pip.
# python3-dev needed for PyMuPDF native extensions.

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Install Python 3 + pip via apt - no version mismatch, no missing .so files
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    python3 \
    python3-dev \
    python3-pip \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Upgrade pip first, then install packages
RUN python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir pymupdf img2pdf Pillow

# Symlink so 'python' resolves
RUN ln -sf /usr/bin/python3 /usr/local/bin/python

# Verify all packages load correctly
RUN python -c "import fitz, img2pdf, PIL; print('PyMuPDF', fitz.version[0], '/ img2pdf / Pillow OK')"

# Copy all function app code into the image
COPY . /home/site/wwwroot

WORKDIR /home/site/wwwroot
