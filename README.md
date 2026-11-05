# SageMath for Kali Linux

> Having trouble slopping crypto tasks? Is your virtual machine's disk space running out from all the Conda instances you're running? Do you want more reproducibility in your life? Then this quasi-repository is for you!

SageMath was [removed from Debian 13](https://tracker.debian.org/news/1463959/sagemath-removed-from-testing/). As Kali Linux's rolling branch is based on Debian (but not Sid), it too lost access to SageMath. This repository rebuilds Debian’s complete SageMath source package against Kali, keeping the upstream source and Debian patches together.

## Install on Kali

Supported platform: **Kali Rolling on AMD64 (x86-64)**.

```sh
BASE_URL='https://sagemath.ovc.one'
sudo install -d -m 0755 /etc/apt/keyrings
KEY_FILE=$(mktemp)
curl -fsSL "$BASE_URL/archive-key.asc" -o "$KEY_FILE"
sudo install -m 0644 "$KEY_FILE" /etc/apt/keyrings/sage-kali.asc
rm -f "$KEY_FILE"
sudo tee /etc/apt/sources.list.d/sage-kali.sources >/dev/null <<EOF
Types: deb deb-src
URIs: $BASE_URL
Suites: kali-rolling
Components: main
Signed-By: /etc/apt/keyrings/sage-kali.asc
EOF
sudo apt update
sudo apt install sagemath

# Optional:
sudo apt install sagemath-jupyter sagemath-doc
```

The package supports `sage -python script.py` (system Python), `sage -t example.sage`
(doctests), and the usual `sage`, `sage -c '...'`, and `sage -n jupyter` commands.
Use `sage --help` or `man sage` for details.
