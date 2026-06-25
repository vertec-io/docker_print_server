# =============================================================================
# Docker Print Server
# CUPS + Samba + wsdd + DirectPrintClient
# =============================================================================
#
# This container provides:
# - CUPS print server for managing printers
# - Samba for Windows SMB printer sharing
# - wsdd for Windows network discovery (WSD protocol)
# - DirectPrintClient for Odoo Direct Print integration
#
# Host OS can be any Docker-compatible system (Linux, Windows, macOS)
# The container runs Debian 12 (bookworm) internally.
#
# !! DO NOT switch this back to ubuntu:22.04 !!
# Ubuntu 22.04's patched CUPS (2.4.1op1) has a web-interface session-cookie
# auth regression: once a browser sends back CUPS's own `org.cups.sid` cookie,
# authentication fails ("pam_authenticate() returned 7") even with the correct
# password -- producing an endless admin-login loop. curl/CLI work (they don't
# send the cookie), so it's easy to misdiagnose as a password problem.
# Debian's clean CUPS 2.4.2 does not have this bug. (Diagnosed & verified 2026-06-25.)
# =============================================================================
FROM debian:12-slim

# =============================================================================
# Build Arguments (can be overridden at build time or via .env)
# =============================================================================
ARG CUPS_ADMIN_PASSWORD=adminpassword
ARG SAMBA_PASSWORD=printers
ARG SAMBA_USER=printuser

# =============================================================================
# Prevent interactive prompts during package installation
# =============================================================================
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# =============================================================================
# Install Dependencies
# =============================================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # Timezone data (required for Ubuntu)
    tzdata \
    # CUPS and printing
    cups \
    cups-client \
    cups-bsd \
    cups-filters \
    cups-ipp-utils \
    cups-pdf \
    printer-driver-all \
    # Samba for Windows SMB sharing
    samba \
    samba-common-bin \
    smbclient \
    cifs-utils \
    # Network discovery and hostname resolution
    avahi-daemon \
    avahi-utils \
    libnss-mdns \
    dbus \
    # Python for utilities and wsdd
    python3 \
    python3-pip \
    python3-cups \
    # System utilities
    procps \
    curl \
    libcurl4 \
    && rm -rf /var/lib/apt/lists/*

# Install wsdd (Web Services Discovery Daemon) from GitHub
# This enables Windows to discover the print server in Network
RUN curl -L https://raw.githubusercontent.com/christgau/wsdd/master/src/wsdd.py -o /usr/local/bin/wsdd && \
    chmod +x /usr/local/bin/wsdd

# =============================================================================
# Set Root Password for CUPS Administration
# =============================================================================
RUN echo "root:${CUPS_ADMIN_PASSWORD}" | chpasswd

# =============================================================================
# Create Samba Print User
# =============================================================================
# Create a dedicated user for Samba print access (more secure than using root)
RUN useradd -r -s /sbin/nologin ${SAMBA_USER}

# =============================================================================
# Copy and Extract DirectPrintClient
# =============================================================================
# The DirectPrintClient binary connects to Odoo via Direct Print module
# ADD automatically extracts tar.gz files
# To update: download new version from Ventor Tech and replace the tar.gz file
ADD directprint/DirectPrintClient-4.27.12-ubuntu-22.04-x86_64.tar.gz /opt/

# Rename to consistent path and set permissions
RUN mv /opt/DirectPrintClient-4.27.12-ubuntu-22.04-x86_64 /opt/directprint && \
    ldconfig && \
    chmod +x /opt/directprint/DirectPrintClient && \
    chmod +x /opt/directprint/init.sh

# =============================================================================
# Configure Samba
# =============================================================================
# Create Samba spool directory
RUN mkdir -p /var/spool/samba && \
    chmod 1777 /var/spool/samba

# Create Samba log directory
RUN mkdir -p /var/log/samba

# Set up Samba user with configured password
# This is the user Windows clients will authenticate with
RUN printf "${SAMBA_PASSWORD}\n${SAMBA_PASSWORD}\n" | smbpasswd -s -a ${SAMBA_USER}

# Also set up root as fallback
RUN printf "${SAMBA_PASSWORD}\n${SAMBA_PASSWORD}\n" | smbpasswd -s -a root

# =============================================================================
# Copy Startup Script
# =============================================================================
COPY scripts/start.sh /start.sh
RUN sed -i 's/\r$//' /start.sh && chmod +x /start.sh

# =============================================================================
# Environment Variables
# =============================================================================
ENV PYTHONUNBUFFERED=1

# =============================================================================
# Expose Ports
# =============================================================================
# 631   - CUPS web interface and IPP printing
# 139   - Samba NetBIOS Session Service
# 445   - Samba SMB Direct (main Windows file/print sharing)
# 3702  - wsdd WS-Discovery (UDP, for Windows network discovery)
# 5357  - wsdd WS-Discovery HTTP
# 8888  - DirectPrintClient web interface
# 9100  - Raw printing (JetDirect/AppSocket)
EXPOSE 631 139 445 3702/udp 5357 8888 9100

# =============================================================================
# Health Check
# =============================================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -sf http://localhost:631/ > /dev/null && \
        curl -sf http://localhost:8888/ > /dev/null || exit 1

# =============================================================================
# Start Services
# =============================================================================
ENTRYPOINT ["/start.sh"]

