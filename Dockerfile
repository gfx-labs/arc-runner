# Default for local/manual builds. CI overrides this via --build-arg with the
# resolved upstream release, so this value only matters when building by hand.
# Pinned rather than `latest` so a plain `docker build` is reproducible.
ARG RUNNER_VERSION=2.337.0
FROM ghcr.io/falcondev-oss/actions-runner:${RUNNER_VERSION}

# Node major used for the preinstalled runtime, and the Playwright release whose
# system dependencies get baked in. PLAYWRIGHT_VERSION must track the version
# pinned by the workflows that run browsers, otherwise the CI-time
# `playwright install-deps` can still find something missing and go to the
# network. See the Playwright section below.
ARG NODE_MAJOR=24
ARG PLAYWRIGHT_VERSION=1.64.0-alpha-1789764292000

# JDK major for the Android release jobs. This must track what the workflows
# ask for (they pin Temurin 21); on a mismatch actions/setup-java just
# downloads its own copy and the preinstall buys nothing.
ARG JAVA_MAJOR=21

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

# ── JDK ───────────────────────────────────────────────────────────────
# The Android release job signs the AAB on the host with jarsigner and checks
# the upload certificate with keytool, so a JDK is needed even though the app
# itself is built inside a container. Temurin matches what the workflow asks
# for, so actions/setup-java finds it already present and skips its download.
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
       | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print $2}' /etc/os-release) main" \
       > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-${JAVA_MAJOR}-jdk \
    && rm -rf /var/lib/apt/lists/*

# Resolved rather than hardcoded to amd64, since this image is also published
# for arm64 and the package path carries the Debian architecture. TARGETARCH is
# supplied by buildx and must be re-declared to be usable in this stage.
ARG TARGETARCH
ENV JAVA_HOME=/usr/lib/jvm/temurin-${JAVA_MAJOR}-jdk-${TARGETARCH}

# ── Ruby native-extension dependencies ────────────────────────────────
# fastlane runs on the host to talk to Google Play, so the release jobs need
# Ruby. The interpreter itself is NOT installed here: workflows pin an exact
# version through ruby/setup-ruby, which downloads a prebuilt Ruby, and the
# distro package is a different patch series (3.2 against the pinned 3.3), so
# installing it would be dead weight that setup-ruby ignores.
#
# What is worth baking in are the headers its gems need to compile native
# extensions, which otherwise pull from the Ubuntu archive on every job.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libffi-dev \
       libyaml-dev \
       zlib1g-dev \
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
