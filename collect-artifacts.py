#!/usr/bin/python3
"""Validate both source builds and record exactly which packages to publish."""
import hashlib
import json
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from debian.deb822 import Changes, Dsc

work = Path(os.environ["WORK"])
output = Path(os.environ["OUTPUT"])
binaries = []
sources = []
debian_versions = {}


def record(path):
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"filename": path.name, "sha256": digest, "size": path.stat().st_size}


for row in (work / "versions.tsv").read_text().splitlines():
    package, debian_version, version = row.split("\t")
    debian_versions[package] = debian_version
    directory = work / package
    artifact_version = version.split(":", 1)[-1]
    dsc_path = directory / f"{package}_{artifact_version}.dsc"
    with dsc_path.open() as stream:
        source = Dsc(stream)
    if source["Source"] != package or source["Version"] != version:
        raise ValueError(f"incorrect source identity: {dsc_path}")
    sources.append(dict(record(dsc_path), name=package, version=version))
    outputs = {dsc_path}
    for binary in source["Binary"].replace(",", " ").split():
        matches = list(directory.glob(f"{binary}_{artifact_version}_*.deb"))
        if len(matches) != 1:
            raise ValueError(f"expected one {binary} binary")
        path = matches[0]
        identity = subprocess.check_output(
            ["dpkg-deb", "--show", "--showformat=${Package} ${Version} ${Architecture}", str(path)],
            text=True,
        ).split()
        if identity[:2] != [binary, version] or identity[2] not in ("amd64", "all"):
            raise ValueError(f"incorrect binary identity: {identity}")
        binaries.append(dict(record(path), name=binary, version=version, architecture=identity[2]))
        outputs.add(path)
    changes = list(directory.glob(f"{package}_{artifact_version}_*.changes"))
    buildinfo = list(directory.glob(f"{package}_{artifact_version}_*.buildinfo"))
    if not changes or not buildinfo:
        raise ValueError(f"missing build manifests for {package}")
    outputs.update(changes + buildinfo)
    manifests = [source]
    for path in changes:
        with path.open() as stream:
            manifests.append(Changes(stream))
    for manifest in manifests:
        if manifest["Version"] != version:
            raise ValueError("incorrect build manifest version")
        for item in manifest["Checksums-Sha256"]:
            name = item["name"]
            if Path(name).name != name:
                raise ValueError("artifact must be a basename")
            path = directory / name
            actual = record(path)
            if actual["sha256"] != item["sha256"] or actual["size"] != int(item["size"]):
                raise ValueError(f"corrupt build artifact: {path}")
            if manifest is source:
                outputs.add(path)
    for path in outputs:
        shutil.copy2(path, output / path.name)

if {source["name"] for source in sources} != {"sagemath", "eclib"}:
    raise ValueError("expected Sage and eclib source builds")
required = {"sagemath", "python3-sage", "sagemath-jupyter", "sagemath-doc", "eclib-tools", "libec-dev"}
if not required.issubset({binary["name"] for binary in binaries}):
    raise ValueError("missing required Sage/eclib packages")
sage = next(source for source in sources if source["name"] == "sagemath")
metadata = {
    "upstream_version": (work / "sagemath/source/VERSION.txt").read_text().strip(),
    "package_version": sage["version"],
    "debian_source_version": debian_versions["sagemath"],
    "debian_source_versions": debian_versions,
    "binary_packages": binaries,
    "source_packages": sources,
    "kali_image": os.environ["KALI_IMAGE_DIGEST"],
    "implementation_commit": os.environ.get("GITHUB_SHA", "local"),
    "built_at": datetime.now(timezone.utc).isoformat(),
}
(output / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
