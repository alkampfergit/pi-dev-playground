FROM mcr.microsoft.com/devcontainers/typescript-node:1-22-bookworm

# PowerShell (pwsh) — the samples' prepare/session-stats scripts are PowerShell.
RUN apt-get update \
    && apt-get install -y --no-install-recommends wget apt-transport-https software-properties-common \
    && . /etc/os-release \
    && wget -q "https://packages.microsoft.com/config/debian/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# Deno — the notebooks/ series runs on the Deno Jupyter kernel.
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh

# Pi coding agent CLI used by every sample under samples/.
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent

USER node
