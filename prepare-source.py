#!/usr/bin/python3
"""Install the Kali launcher through Debian's existing package build rules."""
from pathlib import Path
import re
import shutil
import sys

source = Path(sys.argv[1])
version = (source / "VERSION.txt").read_text().strip()
if not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version):
    raise ValueError(f"Debian Sage source is not a stable release: {version}")
packaging = Path(__file__).resolve().parent / "packaging"
shutil.copy2(packaging / "sage", source / "debian/sage-kali")
shutil.copy2(packaging / "sage.1", source / "debian/sage.1")
rules = source / "debian/rules"
text = rules.read_text()
anchor = "override_dh_auto_install:\n"
if text.count(anchor) != 1:
    raise ValueError("Debian install hook changed; review the launcher integration")
recipe = "\tinstall -m 0755 debian/sage-kali debian/tmp/usr/bin/sage\n"
if recipe not in text:
    text = text.replace(anchor, anchor + recipe)
# Only python3-sage contains Python modules now; the other packages contain
# the shell launcher, Jupyter metadata or documentation.
indep_hook = "\noverride_dh_python3-indep:\n\t:\n"
if "\noverride_dh_python3-indep:" not in text:
    text += indep_hook
elif indep_hook not in text:
    raise ValueError("Debian Python install hook changed; review the launcher integration")
rules.write_text(text)

# The shell launcher no longer generates dh_python3's automatic dependency.
control = source / "debian/control.in"
paragraphs = control.read_text().split("\n\n")
matches = [i for i, paragraph in enumerate(paragraphs) if paragraph.startswith("Package: sagemath\n")]
if len(matches) != 1:
    raise ValueError("Debian sagemath control stanza changed; review dependencies")
index = matches[0]
paragraphs[index] = paragraphs[index].replace("${python3:Depends}", "python3:any").replace("${shlibs:Depends}, ", "")
if "python3-pytest" not in paragraphs[index]:
    paragraphs[index] = paragraphs[index].replace("python3:any", "python3:any, python3-pytest", 1)
control.write_text("\n\n".join(paragraphs))
