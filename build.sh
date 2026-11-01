#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:?Run this script in the GitHub Actions build job}"
cd "$GITHUB_WORKSPACE"
source /etc/os-release

if [[ $# != 0 || $ID != kali || $EUID != 0 ]] ||
    [[ $(dpkg --print-architecture) != amd64 ]]; then
    echo 'Requires the Kali amd64 job container, as root' >&2
    exit 1
fi

export BUILD_NUMBER=${BUILD_NUMBER:-1}
export BUILD_ATTEMPT=${BUILD_ATTEMPT:-1}

if [[ ! $BUILD_NUMBER =~ ^[1-9][0-9]*$ || ! $BUILD_ATTEMPT =~ ^[1-9][0-9]*$ ]]; then
    echo 'Build number and attempt must be positive integers' >&2
    exit 1
fi

: "${KALI_IMAGE_DIGEST:?Set the resolved Kali image digest}"
if [[ ! $KALI_IMAGE_DIGEST =~ ^kalilinux/kali-rolling@sha256:[0-9a-f]{64}$ ]]; then
    echo 'Invalid Kali image digest' >&2
    exit 1
fi

export WORK="$PWD/.work/build"
export OUTPUT="$PWD/out"
mkdir -p "$WORK" "$OUTPUT"

if [[ -n $(find "$WORK" "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    echo '.work/build and out must be empty' >&2
    exit 1
fi

exec > >(tee "$WORK/build.log") 2>&1
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
    build-essential devscripts equivs fakeroot dpkg-dev \
    debian-archive-keyring debian-keyring ca-certificates \
    git curl xz-utils python3 python3-debian util-linux passwd

useradd --create-home --uid 1000 --shell /bin/bash builder
chown builder:builder "$WORK" "$OUTPUT"
cd "$WORK"

export DEBFULLNAME='SageMath for Kali'
export DEBEMAIL=noreply@github.com
export DEB_BUILD_OPTIONS='parallel=2 nocheck'
unset DEB_BUILD_PROFILES

runuser -u builder -- bash -s <<-'PREPARE'
	set -euo pipefail

	python3 - <<'PYTHON' > build.env
	import os
	import re
	import subprocess

	remote_tags = subprocess.check_output(
	    ["git", "ls-remote", "--tags", "https://github.com/sagemath/sage.git"],
	    text=True,
	    timeout=180,
	)

	tags = {}
	for line in remote_tags.splitlines():
	    commit, ref = line.split()
	    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not ref.startswith("refs/tags/"):
	        raise ValueError("malformed upstream tag response")

	    match = re.fullmatch(r"refs/tags/([0-9]+\.[0-9]+(?:\.[0-9]+)?)(\^\{\})?", ref)
	    if match:
	        version, peeled = match.groups()
	        tags.setdefault(version, {})[bool(peeled)] = commit

	if not tags:
	    raise ValueError("no numeric stable Sage tags found")

	numeric_versions = {
	    tag: tuple(map(int, (tag.split(".") + ["0"])[:3]))
	    for tag in tags
	}
	version = max(numeric_versions, key=lambda tag: (numeric_versions[tag], tag))
	commits = {
	    tags[tag].get(True, tags[tag].get(False))
	    for tag in tags
	    if numeric_versions[tag] == numeric_versions[version]
	}
	if len(commits) != 1:
	    raise ValueError("ambiguous stable Sage tags")

	build_number = os.environ["BUILD_NUMBER"]
	build_attempt = os.environ["BUILD_ATTEMPT"]
	package_version = f"{version}-0+sagekali{build_number}.{build_attempt}"

	print(f"export UPSTREAM_VERSION={version}")
	print(f"export UPSTREAM_COMMIT={commits.pop()}")
	print(f"export PACKAGE_VERSION={package_version}")
	PYTHON

	source build.env
	echo "Building Sage $UPSTREAM_VERSION at $UPSTREAM_COMMIT"

	mkdir -p apt/lists/partial download
	cat > apt/sid.sources <<'SID_SOURCES'
	Types: deb-src
	URIs: https://deb.debian.org/debian
	Suites: sid
	Components: main
	Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
	SID_SOURCES

	apt_source=(
	    -o "Dir::Etc::sourcelist=$WORK/apt/sid.sources"
	    -o Dir::Etc::sourceparts=-
	    -o "Dir::State::lists=$WORK/apt/lists"
	    -o APT::Sandbox::User=builder
	)
	apt-get "${apt_source[@]}" update

	cd download
	apt-get "${apt_source[@]}" source --download-only --only-source sagemath
	source_packages=(*.dsc)
	if [[ ${#source_packages[@]} != 1 || ! -f ${source_packages[0]} ]]; then
	    echo 'Expected one Debian Sage source package' >&2
	    exit 1
	fi

	dpkg-source -x "${source_packages[0]}" "$WORK/debian-source"
	debian_version=$(dpkg-parsechangelog -l "$WORK/debian-source/debian/changelog" -S Version)
	printf 'export DEBIAN_SOURCE_VERSION=%q\n' "$debian_version" >> "$WORK/build.env"

	cd "$WORK"
	upstream_archive="sagemath_${UPSTREAM_VERSION}.orig.tar.gz"
	curl --fail --location --show-error \
	    "https://api.github.com/repos/sagemath/sage/tarball/$UPSTREAM_COMMIT" \
	    -o "$upstream_archive.download"
	mv "$upstream_archive.download" "$upstream_archive"
	sha256sum "$upstream_archive" > orig.sha256

	mkdir source
	tar -xzf "$upstream_archive" --strip-components=1 -C source
	if [[ $(< source/VERSION.txt) != "$UPSTREAM_VERSION" ]]; then
	    echo 'Upstream VERSION.txt mismatch' >&2
	    exit 1
	fi

	rm -rf source/debian
	cp -a debian-source/debian source/debian
	cd source

	dch \
	    --newversion "$PACKAGE_VERSION" \
	    --distribution kali-rolling \
	    --force-distribution \
	    --force-bad-version \
	    --no-auto-nmu \
	    --preserve \
	    "Kali rebuild of Sage $UPSTREAM_VERSION at $UPSTREAM_COMMIT."

	dpkg-source --before-build .
	rm -f debian/control
	make -f debian/rules debian/control
PREPARE

# Prefer build dependencies from Kali binaries, then retry with Debian sid binaries if needed.
mkdir dependencies
cd dependencies
install_build_deps() {
    mk-build-deps \
        --install \
        --remove \
        --tool 'apt-get -y --no-install-recommends' \
        "$WORK/source/debian/control"
}

if ! install_build_deps; then
    cat > /etc/apt/sources.list.d/debian-sid-builddeps.sources <<'SID_BINARY_SOURCES'
Types: deb
URIs: https://deb.debian.org/debian
Suites: sid
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SID_BINARY_SOURCES
    apt-get update
    if ! install_build_deps; then
        rm -f /etc/apt/sources.list.d/debian-sid-builddeps.sources
        exit 1
    fi
    rm -f /etc/apt/sources.list.d/debian-sid-builddeps.sources
fi
cd "$WORK"

runuser -u builder -- bash -s <<-'COMPILE'
	set -euo pipefail
	source build.env

	cd source
	dpkg-checkbuilddeps
	dpkg-buildpackage --build=full -us -uc -sa

	cd "$WORK"
	sha256sum --check orig.sha256

	python3 - <<'PYTHON'
	import hashlib
	import json
	import os
	import shutil
	import subprocess
	from datetime import datetime, timezone
	from pathlib import Path

	from debian.deb822 import Changes, Dsc

	work = Path.cwd()
	output = Path(os.environ["OUTPUT"])
	version = os.environ["PACKAGE_VERSION"]
	outputs = []

	for package in ("sagemath", "python3-sage", "sagemath-jupyter", "sagemath-doc"):
	    matches = list(work.glob(f"{package}_{version}_*.deb"))
	    if len(matches) != 1:
	        raise ValueError(f"expected one {package} package")

	    deb = matches[0]
	    identity = subprocess.check_output(
	        [
	            "dpkg-deb",
	            "--show",
	            "--showformat=${Package} ${Version} ${Architecture}",
	            str(deb),
	        ],
	        text=True,
	    ).split()
	    name, built_version, architecture = identity
	    if name != package or built_version != version or architecture not in ("amd64", "all"):
	        raise ValueError(f"incorrect Sage package identity: {identity}")

	    outputs.append(deb)

	dsc = work / f"sagemath_{version}.dsc"
	with dsc.open() as stream:
	    source = Dsc(stream)
	if source["Source"] != "sagemath" or source["Version"] != version:
	    raise ValueError("incorrect Sage source identity")
	outputs.append(dsc)

	for pattern in ("sagemath_*.changes", "sagemath_*.buildinfo"):
	    matches = list(work.glob(pattern))
	    if not matches:
	        raise ValueError(f"missing {pattern}")
	    outputs.extend(matches)

	manifests = [source]
	for path in outputs:
	    if path.suffix == ".changes":
	        with path.open() as stream:
	            manifests.append(Changes(stream))

	for manifest in manifests:
	    if manifest["Version"] != version:
	        raise ValueError("incorrect build manifest version")

	    for item in manifest["Checksums-Sha256"]:
	        if Path(item["name"]).name != item["name"]:
	            raise ValueError("source/build artifact must be a basename")

	        path = work / item["name"]
	        with path.open("rb") as stream:
	            digest = hashlib.file_digest(stream, "sha256").hexdigest()
	        if digest != item["sha256"] or path.stat().st_size != int(item["size"]):
	            raise ValueError(f"corrupt build artifact: {path}")

	        if manifest is source:
	            outputs.append(path)

	for path in set(outputs):
	    shutil.copy2(path, output / path.name)

	metadata = {
	    "upstream_version": os.environ["UPSTREAM_VERSION"],
	    "upstream_commit": os.environ["UPSTREAM_COMMIT"],
	    "package_version": version,
	    "debian_source_version": os.environ["DEBIAN_SOURCE_VERSION"],
	    "orig_sha256": (work / "orig.sha256").read_text().split()[0],
	    "kali_image": os.environ["KALI_IMAGE_DIGEST"],
	    "implementation_commit": os.environ.get("GITHUB_SHA", "local"),
	    "built_at": datetime.now(timezone.utc).isoformat(),
	}
	(output / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
	PYTHON
COMPILE
