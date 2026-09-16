# Cloud Agent base image for NetDiagram-PS.
# Provides the stable system toolchain: PowerShell 7 (the module targets 7.4+),
# net-snmp (optional SNMP discovery), and the Linux networking tools the
# discovery wizard shells out to (ip / arp). Project-level PowerShell modules
# (Pester, PSScriptAnalyzer) are installed by .cursor/install.sh after checkout.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        sudo \
        apt-transport-https \
        snmp \
        iproute2 \
        net-tools \
    && rm -rf /var/lib/apt/lists/*

# Install PowerShell 7 from Microsoft's package repository for this Ubuntu release.
RUN . /etc/os-release \
    && wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
        -O /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm -f /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# Passwordless sudo for the default agent user (matches Cursor's conventions).
RUN echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

USER ubuntu
