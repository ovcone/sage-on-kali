#!/usr/bin/env bash
set -euo pipefail

: "${APT_SIGNING_KEY:?}"
: "${APT_SIGNING_PASSPHRASE?}"
: "${APT_SIGNING_FINGERPRINT:?}"

if [[ -e .work/site || -e .work/reprepro ]]; then
    echo 'Use fresh publication directories' >&2
    exit 1
fi

mkdir -p .work/reprepro/conf .work/site
cp distributions .work/reprepro/conf/distributions

reprepro_command=(
    reprepro
    --basedir "$PWD/.work/reprepro"
    --outdir "$PWD/.work/site"
)

# The manifest includes every binary from the Sage and Kali-built eclib sources,
# including libec-dev and whichever runtime SONAME that eclib release produces.
python3 - <<'PYTHON'
import hashlib
import json
import subprocess
from pathlib import Path

output = Path("out")
metadata = json.loads((output / "build-info.json").read_text())
binaries = metadata["binary_packages"]
sources = metadata["source_packages"]
required = {"sagemath", "python3-sage", "sagemath-jupyter", "sagemath-doc", "eclib-tools", "libec-dev"}
if not required.issubset({item["name"] for item in binaries}):
    raise ValueError("missing required Sage/eclib binaries")
if {item["name"] for item in sources} != {"sagemath", "eclib"}:
    raise ValueError("expected Sage and eclib source packages")
command = ["reprepro", "--basedir", str(Path(".work/reprepro").resolve()),
           "--outdir", str(Path(".work/site").resolve()), "--export=never", "-S", "math", "-P", "optional"]
seen = set()
for kind, items in (("includedeb", binaries), ("includedsc", sources)):
    for item in items:
        filename = item["filename"]
        if Path(filename).name != filename or filename in seen:
            raise ValueError("invalid or duplicate artifact filename")
        seen.add(filename)
        path = output / filename
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != item["sha256"] or path.stat().st_size != item["size"]:
            raise ValueError(f"corrupt artifact: {filename}")
        if kind == "includedeb":
            identity = subprocess.check_output(
                ["dpkg-deb", "--show", "--showformat=${Package} ${Version} ${Architecture}", str(path)],
                text=True,
            ).split()
            if identity != [item["name"], item["version"], item["architecture"]] or identity[2] not in ("amd64", "all"):
                raise ValueError(f"incorrect binary identity: {identity}")
        subprocess.run(command + [kind, "kali-rolling", str(path)], check=True)
PYTHON
"${reprepro_command[@]}" export kali-rolling
"${reprepro_command[@]}" check kali-rolling
"${reprepro_command[@]}" checkpool
cp out/build-info.json .work/site/build-info.json

GNUPGHOME=$(mktemp -d "$PWD/.work/gnupg.XXXXXX")
export GNUPGHOME

cleanup() {
    gpgconf --kill gpg-agent || true
    rm -rf "$GNUPGHOME"
}
trap cleanup EXIT

printf '%s\n' "$APT_SIGNING_KEY" | gpg --batch --import
unset APT_SIGNING_KEY

gpg --batch --with-colons --fingerprint --list-keys | python3 -c '
import os
import re
import sys

rows = [line.split(":") for line in sys.stdin]
primary_fingerprints = [
    rows[index + 1][9]
    for index, row in enumerate(rows[:-1])
    if row[0] == "pub" and rows[index + 1][0] == "fpr"
]
expected = os.environ["APT_SIGNING_FINGERPRINT"]
if (
    not re.fullmatch(r"[0-9A-F]{40}(?:[0-9A-F]{24})?", expected)
    or primary_fingerprints != [expected]
):
    sys.exit("Imported signing key does not match APT_SIGNING_FINGERPRINT")
'

gpg --batch --armor --export "$APT_SIGNING_FINGERPRINT" > .work/site/archive-key.asc

release_directory=.work/site/dists/kali-rolling
release="$release_directory/Release"
sign_command=(
    gpg
    --batch
    --pinentry-mode loopback
    --passphrase-fd 0
    --local-user "$APT_SIGNING_FINGERPRINT"
)

printf '%s\n' "$APT_SIGNING_PASSPHRASE" |
    "${sign_command[@]}" --clearsign \
        --output "$release_directory/InRelease" "$release"

printf '%s\n' "$APT_SIGNING_PASSPHRASE" |
    "${sign_command[@]}" --detach-sign \
        --output "$release.gpg" "$release"

unset APT_SIGNING_PASSPHRASE
gpg --batch --verify "$release_directory/InRelease"
gpg --batch --verify "$release.gpg" "$release"

python3 - <<'PYTHON'
from pathlib import Path

site_size = 0
for path in Path(".work/site").rglob("*"):
    if path.is_symlink():
        raise SystemExit("Pages tree must not contain symlinks")
    if path.is_dir():
        continue
    if not path.is_file() or path.stat().st_nlink != 1:
        raise SystemExit("Pages tree must contain only regular files and directories")
    site_size += path.stat().st_size

if site_size > 900 * 1024 * 1024:
    raise SystemExit("APT site exceeds the 900 MiB Pages limit")
PYTHON
