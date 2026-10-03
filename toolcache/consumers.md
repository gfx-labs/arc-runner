# CI dependency audit

Audited `oku-trade/trade`, `oku-trade/account`, and `oku-trade/retail` on October 3, 2026. Paths below are relative to those repositories. The audit distinguishes tools used on the Linux runner from application dependencies, Docker build contents, and macOS-only jobs.

## Versions covered by these images

| Consumer | Runner requirement | Image provisioning | Evidence |
| --- | --- | --- | --- |
| All three repos | Node `24` | Node 24.21.0 in the Actions tool cache | trade `.github/workflows/ci.yml:35`, account `.github/workflows/ci.yml:178-180`, retail `.github/workflows/ci.yml` |
| account | Go **1.26.6**, exact | Added alongside the existing Go 1.25.14 entry | `go.mod:3` and `.github/workflows/ci.yml:102-104` |
| account | Yarn **4.11.0** | Shared Corepack cache | `package.json` `packageManager` |
| retail | Yarn **4.12.0**, with integrity hash | Shared Corepack cache preserving the complete descriptor | `package.json:61`, `.github/workflows/android-internal.yml:55` |
| trade | Yarn **4.17.1** | Shared Corepack cache | `package.json:172`, `.github/workflows/ci.yml:38` |
| retail Android | Ruby `3.3` | Ruby 3.3.12 using the same setup-ruby revision as the workflow | `.github/workflows/android-internal.yml:84-87` |
| trade browser jobs | Playwright **1.63.0**, Chromium and Firefox system dependencies | General image queries that release for both dependency sets | `package.json:55,152`, `.github/workflows/e2e.yml:80-83` |
| account | PostgreSQL client | General image installs `postgresql-client` | `.github/workflows/ci.yml:157-158` |

No additional Node or Ruby CI versions were found. Trade's `.tool-versions` Node 24.11.0 is a developer-tool pin, not a CI setup request. All three projects' CI requests select Node 24. Go 1.25.14 remains for other existing consumers of the shared runner pools.

`COREPACK_HOME=/opt/corepack` is preserved across job steps within each image. Cached Yarn versions are checked with their project descriptors, as the runner user, with both container networking and Corepack network access disabled. Corepack still reads `packageManager` even when a project also checks in a Yarn release through `yarnPath`.

Xvfb and the GitHub CLI were already present in the validated image. They do not need another installation mechanism. The Android image already supplies Android platform 36, build tools 36.0.0, NDK 27.1.12297006, CMake 3.22.1, accepted licenses, and sccache with a ccache symlink.

## Remaining follow-ups

| Dependency | Consumer | Why it remains separate |
| --- | --- | --- |
| Deno `v2.x` | account's three validation jobs, `.github/workflows/ci.yml:33-35,74-76,88-90` | `setup-deno` looks in its tool cache, not system `PATH`, but resolves the version over the network before cache lookup, even for exact versions. It cannot use the existing network-disabled action replay unchanged. A dedicated wrapper/cache check and a consumer version pin would avoid binary downloads without pretending metadata resolution is offline. |
| Temurin JDK `21` Actions cache | retail Android, `.github/workflows/android-internal.yml:79-82` | The apt JDK and `JAVA_HOME` are present, but `setup-java` searches `Java_Temurin-Hotspot_jdk` cache entries. Register or provision through that action rather than inventing the Java version/build-number directory format. |
| Bundler **4.0.10** | retail Android, `Gemfile.lock:364` and `apps/mobile/Gemfile.lock:364` | The Ruby runtime is cached, but the build wrapper deliberately sets `bundler: none`. The pinned setup-ruby implementation invokes `gem install` for an explicitly selected Bundler version. Warming the gem may help, but needs a real job check before claiming that this step makes no network requests. |
| Gradle **9.3.1** | retail Android, `apps/mobile/android/gradle/wrapper/gradle-wrapper.properties:3` | The workflow already restores `~/.gradle/wrapper` and build caches. It is not an Actions language-toolcache entry. |
| Playwright browser binaries and MetaMask | trade browser jobs | Browser caches have job-specific paths and restore keys. Align those before baking browsers into a shared image. MetaMask is downloaded by dappwright at runtime. |

The account database check and trade browser jobs still run unconditional apt update/install commands. Baking their packages in avoids package downloads, but changing those workflow commands to skip apt metadata refresh would require separate consumer-repository changes.

Do not add buf, protoc, mise, bun, pnpm, or golangci-lint just because they occur in a developer configuration. None was needed as a preinstalled host binary by these three repos' audited CI steps. Account uses `go tool ko` from its module tool dependencies, so ko belongs in the Go module cache rather than as an unrelated global binary.

Application packages, fastlane 2.238.0, Go modules, Deno imports, and Gradle build outputs remain in their existing dependency caches. Retail's iOS jobs run on macOS and are outside the Linux images' scope.
