#!/usr/bin/env python3
"""Apply and verify the eMudhra root distrust policy for runner trust stores."""

import hashlib
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys

ROOTS = {
    "mozilla/Comodo_AAA_Services_root.crt": "D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4",
    "mozilla/emSign_ECC_Root_CA_-_G3.crt": "86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B",
}
JAVA_STORE = Path("/opt/runner-security/cacerts")


def verify_system():
    roots = ssl.create_default_context().get_ca_certs(binary_form=True)
    if not roots:
        raise RuntimeError("System trust store is empty")
    fingerprints = {hashlib.sha256(cert).hexdigest().upper() for cert in roots}
    if fingerprints.intersection(ROOTS.values()):
        raise RuntimeError("Distrusted eMudhra chain anchor remains in system trust")
    print(f"System trust verified: {len(roots)} roots, affected anchors absent")


def java_entries():
    output = subprocess.run(
        ["keytool", "-list", "-v", "-keystore", str(JAVA_STORE), "-storepass", "changeit"],
        check=True, capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"},
    ).stdout
    alias = None
    entries = {}
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("Alias name: "):
            alias = line.removeprefix("Alias name: ")
        elif line.startswith("SHA256: ") and alias is not None:
            entries[alias] = line.removeprefix("SHA256: ").replace(":", "").upper()
    if not entries:
        raise RuntimeError("Could not parse Java trust store fingerprints")
    return entries


def verify_java():
    entries = java_entries()
    if set(entries.values()).intersection(ROOTS.values()):
        raise RuntimeError("Distrusted eMudhra chain anchor remains in Java trust")
    print(f"Java trust verified: {len(entries)} roots, affected anchors absent")


def main():
    mode = sys.argv[1]
    if mode == "system":
        config = Path("/etc/ca-certificates.conf")
        lines = config.read_text().splitlines()
        config.write_text("\n".join("!" + line if line in ROOTS else line for line in lines) + "\n")
        subprocess.run(["update-ca-certificates", "--fresh"], check=True)
        verify_system()
    elif mode == "java":
        source = Path(os.environ["JAVA_HOME"]) / "lib/security/cacerts"
        shutil.copyfile(source, JAVA_STORE)
        for alias, fingerprint in java_entries().items():
            if fingerprint in ROOTS.values():
                subprocess.run(["keytool", "-delete", "-alias", alias, "-keystore", str(JAVA_STORE), "-storepass", "changeit"], check=True)
        JAVA_STORE.chmod(0o644)
        verify_java()
    elif mode == "verify":
        verify_system()
        verify_java()
    else:
        raise ValueError(f"Unknown mode: {mode}")


if __name__ == "__main__":
    main()
