#!/usr/bin/env python3
"""Puts the page and the logo into both scripts: src/ -> shareit.sh, shareit.ps1 (the files people run)."""
from pathlib import Path
page, logo = Path("src/page.html").read_text(), Path("src/logo.svg").read_text().strip()
for name in ("shareit.sh", "shareit.ps1"):
    Path(name).write_text(Path("src", name).read_text().replace("@@PAGE@@", page.rstrip()).replace("@@LOGO@@", logo))
print("built")
