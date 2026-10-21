# Runner certificate trust

Both runner images apply the Debian/Ubuntu eMudhra distrust policy before downloading tools. `trust.py` disables only `Comodo_AAA_Services_root.crt` and `emSign_ECC_Root_CA_-_G3.crt`, regenerates system trust, and fails the build if either SHA-256 fingerprint remains trusted. The unrelated emSign C1, C3, and G1 roots are retained.

Node uses `NODE_OPTIONS=--use-openssl-ca` to replace bundled roots, including the embedded action Node runtimes. The Actions tool cache contains Node 24.22.1. `NODE_EXTRA_CA_CERTS` can still add a private CA, as required by the internal Go cache. Python requests and pip use the corrected system bundle. uv is directed to system trust. Go on Linux uses system trust by default.

The Temurin trust store is copied and filtered by certificate fingerprint. `JAVA_TOOL_OPTIONS` directs Java processes to that immutable filtered store, including a JDK later selected by `actions/setup-java`. Jobs intentionally overriding `JAVA_TOOL_OPTIONS` or supplying another trust store must apply equivalent protections. The build rechecks both system and Java trust as the non-root runner user with networking disabled.

Changing `security/` triggers image publication and invalidates the early Docker layer, so cached apt or tool-install layers cannot bypass this policy. Rebuild and deploy by immutable digest after publication. A runner version tag alone does not identify a rebuild.

The image does not replace trust inside arbitrary Docker build stages, job containers, service containers, statically linked third-party clients, or applications that select their own roots. Update those independently. Docker daemon trust is also independent and must be patched separately.

Reference: <https://emudhra.we-have-a-problem.com/>, Debian patch <https://bugs.debian.org/1151413>, Node release <https://nodejs.org/en/blog/release/v24.22.1/>.

For live acceptance, require certificate-validation errors from all twelve incident endpoints, not DNS failures or timeouts. Also verify GitHub HTTPS and any private-CA service remain reachable. Both example incident URLs are deliberately bad chains.
