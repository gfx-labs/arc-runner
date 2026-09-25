ARG RUNNER_VERSION=latest
FROM ghcr.io/falcondev-oss/actions-runner:${RUNNER_VERSION}

# Node major used for the preinstalled runtime, and the Playwright release whose
# system dependencies get baked in. PLAYWRIGHT_VERSION must track the version
# pinned by the workflows that run browsers, otherwise the CI-time
# `playwright install-deps` can still find something missing and go to the
# network. See the Playwright section below.
ARG NODE_MAJOR=24
ARG PLAYWRIGHT_VERSION=1.64.0-alpha-1789764292000

USER root

# ── Common CI utilities ──────────────────────────────────────────────
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       file \
       git-lfs \
       gnupg \
       gpg-agent \
       libssl-dev \
       make \
       openssh-client \
       pkg-config \
       python3 \
       python3-pip \
       python3-venv \
       rclone \
       rsync \
       software-properties-common \
       wget \
       xz-utils \
       zip \
       zstd \
    && rm -rf /var/lib/apt/lists/*

# ── GitHub CLI ────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js ───────────────────────────────────────────────────────────
# Ubuntu 24.04 ships Node 18, which Playwright rejects (it requires >=20), so
# the distro package is not usable here. This is also what provides npx for the
# Playwright step below.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Playwright system dependencies ────────────────────────────────────
# `playwright install-deps chromium` pulls ~89 apt packages (libnss3, libgbm1,
# xvfb, mesa, fonts, ...). Runners are ephemeral pods, so without this every job
# re-installed all of them from the Ubuntu archive before the browser could
# start.
#
# Playwright itself is asked which packages it needs, rather than pinning a
# hand-copied list, so this cannot silently drift from what the pinned release
# actually requires. The CI step is kept in the workflows: once the packages are
# already present it is a dpkg no-op instead of a download.
#
# The browser binary is deliberately NOT baked in. Workflows set
# PLAYWRIGHT_BROWSERS_PATH to a per-run temp dir restored by actions/cache, so a
# browser installed here would not be found and would only add image weight.
RUN npx --yes --package=playwright@${PLAYWRIGHT_VERSION} playwright install-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.npm

USER runner
