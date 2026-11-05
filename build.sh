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
    python3 python3-debian util-linux passwd

useradd --create-home --uid 1000 --shell /bin/bash builder
chown builder:builder "$WORK" "$OUTPUT"
cd "$WORK"
export DEBFULLNAME='SageMath for Kali'
export DEBEMAIL=noreply@github.com
export DEB_BUILD_OPTIONS='parallel=2 nocheck'
unset DEB_BUILD_PROFILES

# Sid is a source-only input. Never add its binary archive to the build root.
runuser -u builder -- bash -s <<-'PREPARE'
	set -euo pipefail
	mkdir -p apt/lists/partial
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
	for package in sagemath eclib; do
	    mkdir "$WORK/$package"
	    cd "$WORK/$package"
	    apt-get "${apt_source[@]}" source --download-only --only-source "$package"
	    sources=(*.dsc)
	    if [[ ${#sources[@]} != 1 || ! -f ${sources[0]} ]]; then
	        echo "Expected one Debian $package source package" >&2
	        exit 1
	    fi
	    # Keep Debian's upstream archives and their matching applied patch series.
	    dpkg-source -x "${sources[0]}" source
	    cd source
	    debian_version=$(dpkg-parsechangelog -S Version)
	    version="${debian_version}+sagekali${BUILD_NUMBER}.${BUILD_ATTEMPT}"
	    printf '%s\t%s\t%s\n' "$package" "$debian_version" "$version" >> "$WORK/versions.tsv"
	    dch --newversion "$version" --distribution kali-rolling \
	        --force-distribution --no-auto-nmu --preserve \
	        "Rebuild Debian $debian_version for Kali with Kali binary dependencies."
	    if [[ $package == sagemath ]]; then
	        python3 "$GITHUB_WORKSPACE/prepare-source.py" "$PWD"
	        rm -f debian/control
	        make -f debian/rules debian/control
	    fi
	done
PREPARE

mkdir dependencies
cd dependencies
install_build_deps() {
    mk-build-deps --install --remove \
        --tool 'apt-get -y --no-install-recommends' "$1"
}

# Build all eclib binaries (including libec-dev) against Kali before Sage.
install_build_deps "$WORK/eclib/source/debian/control"
(cd "$WORK/eclib/source" && runuser -u builder -- dpkg-buildpackage --build=full -us -uc -sa)
# Install this rebuild even when a newer or differently versioned eclib is in Kali.
# All these binary packages will be published and exercised by the clean-install job.
apt-get install -y --no-install-recommends "$WORK"/eclib/*.deb
install_build_deps "$WORK/sagemath/source/debian/control"
(cd "$WORK/sagemath/source" && runuser -u builder -- dpkg-buildpackage --build=full -us -uc -sa)
runuser -u builder -- python3 "$GITHUB_WORKSPACE/collect-artifacts.py"
