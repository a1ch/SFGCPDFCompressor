# Dockerfile for SFGCPDFCompressor
# Multi-stage build:
#   Stage 1 - python:3.11-slim-bullseye matches the GLIBC version of the PS base image
#   Stage 2 - Azure Functions PowerShell image, Python copied across cleanly

FROM python:3.11-slim-bullseye AS python-build
RUN pip install --no-cache-dir pymupdf img2pdf Pillow

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Copy Python 3.11 and installed packages from build stage
COPY --from=python-build /usr/local/bin/python3.11 /usr/local/bin/python3.11
COPY --from=python-build /usr/local/lib/python3.11 /usr/local/lib/python3.11
COPY --from=python-build /usr/local/lib/libpython3.11.so.1.0 /usr/local/lib/libpython3.11.so.1.0

# Symlink so 'python' and 'python3' resolve
RUN ln -sf /usr/local/bin/python3.11 /usr/local/bin/python3 \
 && ln -sf /usr/local/bin/python3.11 /usr/local/bin/python

# Verify
RUN python -c "import fitz, img2pdf, PIL; print('PyMuPDF', fitz.version[0], '/ img2pdf / Pillow OK')"

# Copy all function app code into the image
COPY . /home/site/wwwroot

WORKDIR /home/site/wwwroot
