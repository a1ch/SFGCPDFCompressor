# Dockerfile for SFGCPDFCompressor
# Builds on the official Azure Functions PowerShell 7.4 Linux image
# and permanently installs Ghostscript so profile.ps1 never needs to.

FROM mcr.microsoft.com/azure-functions/powershell:4-powershell7.4

# Install Ghostscript and clean up apt cache to keep image lean
RUN apt-get update \
 && apt-get install -y --no-install-recommends ghostscript \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Verify gs is on PATH (fails the build immediately if install didn't work)
RUN gs --version
