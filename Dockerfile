# Go build cache client (GOCACHEPROG). Pinned by digest so a rebuild of this
# image cannot pick up a different client than the one reviewed here. The
# server it talks to is set per scale set through ARC_GOCACHE_URL.
ARG GOCACHEPROG_IMAGE=ghcr.io/gfx-labs/arc-gocacheprog:0.0.1@sha256:3647c39f14b6ca5e9a5006de4aa05188b3bd02034b80057d94a587fcf9b61027

# Default for local/manual builds. CI overrides this via --build-arg with the
# resolved upstream release, so this value only matters when building by hand.
# Pinned rather than `latest` so a plain `docker build` is reproducible.
ARG RUNNER_VERSION=2.337.0

# Stage only used to copy the client binary. ARGs above are global, so it
# must come after them.
FROM ${GOCACHEPROG_IMAGE} AS gocacheprog

# Tool cache built from the bare runner image so its cache key depends only on
# toolcache/ and the base image, not on the apt layers of the final stage.
FROM ghcr.io/falcondev-oss/actions-runner:${RUNNER_VERSION} AS toolcache
USER root
# No system Node here. corepack.mjs uses the runner's bundled corepack.
ENV PATH=/home/runner/externals/node24/bin:${PATH}
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
ENV COREPACK_HOME=/opt/corepack
COPY toolcache/ /opt/runner-toolcache/
RUN /home/runner/externals/node24/bin/node /opt/runner-toolcache/install.mjs \
    && /home/runner/externals/node24/bin/node /opt/runner-toolcache/corepack.mjs

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

# ── Go build cache client ────────────────────────────────────────────
# Installed but not enabled. A job opts in with GOCACHEPROG=arc-gocacheprog,
# so existing workflows that restore ~/.cache/go-build themselves, or
# that build release artifacts from a clean cache, are unchanged. See
# toolcache/README.md for the workflow settings.
COPY --from=gocacheprog /usr/local/bin/arc-gocacheprog /usr/local/bin/arc-gocacheprog

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
COPY --from=toolcache /opt/runner-toolcache/ /opt/runner-toolcache/
COPY --from=toolcache /opt/setup-actions/ /opt/setup-actions/
COPY --from=toolcache --chown=runner:runner /opt/hostedtoolcache/ /opt/hostedtoolcache/
COPY --from=toolcache --chown=runner:runner /opt/corepack/ /opt/corepack/

USER runner

RUN --network=none /home/runner/externals/node24/bin/node /opt/runner-toolcache/install.mjs --verify \
    && /home/runner/externals/node24/bin/node /opt/runner-toolcache/corepack.mjs --verify

# The client must start and answer the protocol handshake with no server and
# no network. It exits cleanly when stdin closes.
RUN --network=none ARC_GOCACHE_DIR="$(mktemp -d)" \
       sh -c '/usr/local/bin/arc-gocacheprog </dev/null | grep -q KnownCommands; rc=$?; rm -rf "$ARC_GOCACHE_DIR"; exit $rc'
