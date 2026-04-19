# Dockerfile for SFGCPDFCompressor
# Builds on the official Azure Functions PowerShell 7.4 Linux image,
# permanently installs Ghostscript, and copies all function code in.

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Install Ghostscript and clean up apt cache to keep image lean
RUN apt-get update \
 && apt-get install -y --no-install-recommends ghostscript \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Verify gs is on PATH (fails the build immediately if install didn't work)
RUN gs --version

# Copy all function app code into the image
COPY . /home/site/wwwroot

# Set working directory
WORKDIR /home/site/wwwroot
