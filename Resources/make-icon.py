#!/usr/bin/env python3
"""Builds DesktopPet.icns from the esheep64 pet icon of the upstream desktopPet repository, so the artwork
is not stored in this repo. The sheep is cropped to its outline, scaled with hard pixel edges to 84% of the
icon width and centred on a transparent background.

Requires Pillow (`pip3 install pillow`) and macOS `iconutil`. build-app.sh runs this automatically;
to run it by hand (--preview also writes icon-preview.png):
    python3 Resources/make-icon.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from io import BytesIO

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
UPSTREAM_ICON = "https://raw.githubusercontent.com/Adrianotiger/desktopPet/master/Pets/esheep64/icon.png"


def render(sprite, size):
    scale = size * 0.84 / max(sprite.size)
    w, h = round(sprite.width * scale), round(sprite.height * scale)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(sprite.resize((w, h), Image.NEAREST), ((size - w) // 2, (size - h) // 2))
    return canvas


def main():
    with urllib.request.urlopen(UPSTREAM_ICON, timeout=30) as r:
        sprite = Image.open(BytesIO(r.read())).convert("RGBA")
    sprite = sprite.crop(sprite.getbbox())

    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "DesktopPet.iconset")
    os.mkdir(iconset)
    for base in (16, 32, 128, 256, 512):
        for mult in (1, 2):
            px = base * mult
            name = f"icon_{base}x{base}{'@2x' if mult == 2 else ''}.png"
            render(sprite, px).save(os.path.join(iconset, name))
    if "--preview" in sys.argv:
        render(sprite, 1024).save(os.path.join(HERE, "icon-preview.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, "DesktopPet.icns")], check=True)
    shutil.rmtree(tmp)
    print("Wrote", os.path.join(HERE, "DesktopPet.icns"))


if __name__ == "__main__":
    main()
