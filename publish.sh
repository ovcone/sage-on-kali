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

version=$(python3 -c 'import json; print(json.load(open("out/build-info.json"))["package_version"])')
reprepro_command=(
    reprepro
    --basedir "$PWD/.work/reprepro"
    --outdir "$PWD/.work/site"
)

for package in sagemath python3-sage sagemath-jupyter sagemath-doc eclib-tools libec16; do
    if [[ $package == sagemath || $package == python3-sage ||
        $package == sagemath-jupyter || $package == sagemath-doc ]]; then
        package_files=(out/"${package}_${version}_"*.deb)
    else
        package_files=(out/"${package}_"*.deb)
    fi
    if [[ ${#package_files[@]} != 1 || ! -f ${package_files[0]} ]]; then
        echo "Missing $package package" >&2
        exit 1
    fi

    identity=$(
        dpkg-deb --show \
            '--showformat=${Package} ${Version} ${Architecture}' \
            "${package_files[0]}"
    )
    if [[ $identity != "$package "*' amd64' && $identity != "$package "*' all' ]]; then
        echo "Incorrect Sage package identity: $identity" >&2
        exit 1
    fi

    "${reprepro_command[@]}" --export=never -S math -P optional \
        includedeb kali-rolling "${package_files[0]}"
done

"${reprepro_command[@]}" --export=never -S math -P optional \
    includedsc kali-rolling "out/sagemath_${version}.dsc"
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
