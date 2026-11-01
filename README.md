# SageMath for Kali Linux

> Having trouble slopping crypto tasks? Is your virtual machine's disk space running out from all the Conda instances you're running? Do you want more reproducibility in your life? Then this quasi-repository is for you!

SageMath was [removed from Debian 13](https://tracker.debian.org/news/1463959/sagemath-removed-from-testing/). As Kali Linux's rolling branch is based on Debian (but not Sid), it too lost access to SageMath. This repository builds SageMath in accord with other Python packaging, making it easy to install - just like old times. 

## Install on Kali

```sh
BASE_URL='https://sagemath.ovc.one'
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL "$BASE_URL/archive-key.asc" -o /etc/apt/keyrings/sage-kali.asc
sudo curl -fsSL "$BASE_URL/distributions" -o /etc/apt/sources.list.d/sage-kali.sources
sudo apt update
sudo apt install sagemath

# Optional:
sudo apt install sagemath-jupyter sagemath-doc
```
