# Runner tool cache

Both images preinstall the versions in `manifest.json` by executing the compiled entrypoints of pinned `actions/setup-node`, `actions/setup-go`, and `ruby/setup-ruby` revisions. The runner's bundled Node executes the actions. No action dependencies are installed from npm.

The manifest currently includes Node 24.21.0, Go 1.25.14, 1.26.6, and `stable`, and Ruby 3.3.12. Account's `go-version-file: go.mod` selects exactly 1.26.6. Ruby's action revision matches retail because its bundled release list controls which patch a `3.3` request selects. See [the consumer audit](consumers.md) for source references and other dependency gaps.

`stable` is resolved by setup-go when the image is built, so every build includes the latest Go release. CI looks up that release on go.dev and passes it as the `GO_STABLE` build arg. A new Go release therefore invalidates the cached toolcache stage, and the install fails if the action resolves a different version. The resolved version is written to `resolved.json` next to the manifest, which the offline verification uses.

The wrappers provide action inputs and temporary GitHub command files. Dependency caching, Bundler installation, and authentication inputs are disabled during provisioning. Runtime downloads and cache metadata are handled by the official actions.

`RUNNER_TOOL_CACHE` and `AGENT_TOOLSDIRECTORY` both point at `/opt/hostedtoolcache`. Keep this prefix: the prebuilt Ruby contains absolute paths. Do not mount an empty volume over it. The cache is owned by `runner`; action sources under `/opt/setup-actions` are root-owned and readable by `runner`.

Corepack separately caches Yarn 4.11.0, 4.12.0, and 4.17.1 under `COREPACK_HOME=/opt/corepack`. The retail descriptor retains its integrity hash. `corepack.mjs` provisions through the official CLI without changing global defaults. Its verification creates a temporary project for each descriptor and runs the selected Yarn with network access disabled.

## Updating

Edit `manifest.json` to add exact runtime versions or update action commit SHAs. The wrapper checks that each downloaded action's declared runtime and entrypoint match the manifest. The build workflow watches `toolcache/**` and rebuilds both images when these files change.

Keep workflow setup steps. They select a runtime and update `PATH` using the preinstalled cache. A version absent from the image can still be downloaded normally. Dependency caches such as npm packages, Go modules, and gems are separate from this tool cache.

When changing Ruby's action revision, check its `ruby-builder-versions.json` against the revision used by consumers. Their major/minor requests may select different patches even when both revisions use the same cache directory format.

## Validation

Each Dockerfile reruns all pinned actions as the `runner` user with `RUN --network=none` after provisioning. `verifyRequests` maps installed versions to workflow requests: `24`, `1.25.x`, exact `1.26.6`, and `3.3`. The wrapper requires the binary added through `GITHUB_PATH` to resolve inside the tool cache, have a completion marker, and report the expected exact version. The same network-disabled layer verifies all three Yarn versions. A missing cache entry or unavailable runtime library fails the image build.

Run the same check on a built image:

```sh
docker run --rm --network none --entrypoint /home/runner/externals/node24/bin/node \
  <image> /opt/runner-toolcache/install.mjs --verify
docker run --rm --network none --entrypoint /home/runner/externals/node24/bin/node \
  <image> /opt/runner-toolcache/corepack.mjs --verify
```

Provision or verify a single tool with `--tool node`, `--tool go`, or `--tool ruby`. The verification mode never downloads action sources and uses a dead proxy as an additional check. Container network isolation is the definitive no-download check.

Build the general image with `docker build -t arc-runner:toolcache .` and the Android image with `docker build -f Dockerfile.android -t arc-runner-android:toolcache .`. The publication workflow builds both images for amd64 only.

## Go build cache

Both images include the [arc-gocacheprog](https://github.com/gfx-labs/arc-gocacheprog) client at `/usr/local/bin/arc-gocacheprog` (on `PATH`), copied from a digest-pinned image (`GOCACHEPROG_IMAGE` in each Dockerfile). It is not enabled by default. A job opts in:

```yaml
jobs:
  test:
    permissions:
      contents: read
      id-token: write   # the client exchanges this for a cache token
    env:
      GOCACHEPROG: arc-gocacheprog
      ARC_GOCACHE_URL: http://arc-gocacheprog.<namespace>.svc
      ARC_GOCACHE_VERBOSE: "1"   # hit/miss stats after each go command
    steps:
      - uses: actions/setup-go@...
        with:
          go-version-file: go.mod
          cache: false   # do not also restore ~/.cache/go-build
```

The server scopes entries by repository and ref. A job writes only to its own ref and reads its own ref, the pull request base branch, and the server's default branches. Without `id-token: write` or `ARC_GOCACHE_URL` the client uses a local disk cache and the build still succeeds.

Leave `GOCACHEPROG` unset in jobs that build release artifacts, so they compile from a clean cache. `GOCACHE` still holds fuzzing corpora and must stay writable.

To update the client, change the digest in both Dockerfiles. Each image build runs the client with networking disabled and fails if it does not answer the GOCACHEPROG handshake.
