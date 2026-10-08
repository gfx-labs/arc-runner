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
ARG PLAYWRIGHT_VERSION=1.63.0

# JDK major used by Gradle and host-side signing tools.
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
# itself is built inside a container. This apt installation does not populate
# the separate Actions cache used by actions/setup-java.
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
       | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print $2}' /etc/os-release) main" \
       > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-${JAVA_MAJOR}-jdk \
    && rm -rf /var/lib/apt/lists/*

# The package path carries the Debian architecture. TARGETARCH is supplied by
# buildx and must be re-declared to be usable in this stage.
ARG TARGETARCH
ENV JAVA_HOME=/usr/lib/jvm/temurin-${JAVA_MAJOR}-jdk-${TARGETARCH}

# ── Ruby native-extension dependencies ────────────────────────────────
# fastlane runs on the host to talk to Google Play, so the release jobs need
# Ruby. Exact interpreter versions are installed into the tool cache below
# using ruby/setup-ruby rather than the distro package.
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
# Browser dependencies include libnss3, GTK, xvfb, mesa, and fonts.
# Runners are ephemeral pods, so without this every job
# re-installed all of them from the Ubuntu archive before the browser could
# start.
#
# Playwright itself is asked which packages it needs, rather than pinning a
# hand-copied list, so this cannot silently drift from what the pinned release
# actually requires. The CI step is kept in the workflows: once the packages are
# already present it is a dpkg no-op instead of a download.
#
# Browser binaries remain in workflow caches whose locations vary by job.
# PostgreSQL's client is needed by account's database smoke check.
RUN npx --yes --package=playwright@${PLAYWRIGHT_VERSION} playwright install-deps chromium firefox \
    && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/* /root/.npm

# Ruby's prebuilt binaries require this non-relocatable cache prefix.
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
ENV COREPACK_HOME=/opt/corepack
COPY toolcache/ /opt/runner-toolcache/
RUN /home/runner/externals/node24/bin/node /opt/runner-toolcache/install.mjs \
    && /home/runner/externals/node24/bin/node /opt/runner-toolcache/corepack.mjs \
    && chown -R runner:runner /opt/hostedtoolcache /opt/corepack

USER runner

RUN --network=none /home/runner/externals/node24/bin/node /opt/runner-toolcache/install.mjs --verify \
    && /home/runner/externals/node24/bin/node /opt/runner-toolcache/corepack.mjs --verify
