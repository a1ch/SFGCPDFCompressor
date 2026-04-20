# Dockerfile for SFGCPDFCompressor
# Multi-stage build:
#   Stage 1 - python:3.11-slim-bullseye matches GLIBC of PS base image (both Bullseye)
#   Stage 2 - Azure Functions PowerShell image, full Python runtime copied across

FROM python:3.11-slim-bullseye AS python-build
RUN pip install --no-cache-dir pymupdf img2pdf Pillow

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Copy full Python runtime from build stage (binary + stdlib + site-packages + shared libs)
COPY --from=python-build /usr/local/bin/python3.11        /usr/local/bin/python3.11
COPY --from=python-build /usr/local/lib/python3.11        /usr/local/lib/python3.11
COPY --from=python-build /usr/local/lib/libpython3.11.so.1.0 /usr/local/lib/libpython3.11.so.1.0
COPY --from=python-build /usr/lib/x86_64-linux-gnu/libz.so.1         /usr/lib/x86_64-linux-gnu/libz.so.1
COPY --from=python-build /usr/lib/x86_64-linux-gnu/libexpat.so.1     /usr/lib/x86_64-linux-gnu/libexpat.so.1
COPY --from=python-build /usr/lib/x86_64-linux-gnu/libffi.so.7       /usr/lib/x86_64-linux-gnu/libffi.so.7
COPY --from=python-build /usr/lib/x86_64-linux-gnu/libbz2.so.1.0     /usr/lib/x86_64-linux-gnu/libbz2.so.1.0
COPY --from=python-build /usr/lib/x86_64-linux-gnu/liblzma.so.5      /usr/lib/x86_64-linux-gnu/liblzma.so.5
COPY --from=python-build /usr/lib/x86_64-linux-gnu/libsqlite3.so.0   /usr/lib/x86_64-linux-gnu/libsqlite3.so.0

# Symlink so 'python' and 'python3' resolve
RUN ln -sf /usr/local/bin/python3.11 /usr/local/bin/python3 \
 && ln -sf /usr/local/bin/python3.11 /usr/local/bin/python

# Update shared library cache
RUN ldconfig

# Verify all packages load correctly
RUN python -c "import fitz, img2pdf, PIL; print('PyMuPDF', fitz.version[0], '/ img2pdf / Pillow OK')"

# Copy all function app code into the image
COPY . /home/site/wwwroot

WORKDIR /home/site/wwwroot
