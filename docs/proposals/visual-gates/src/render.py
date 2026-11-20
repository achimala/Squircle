#!/usr/bin/env python3
"""Render each NN-*.html here to ../NN-*.png at 3x with headless Chrome, trimming the empty paper below."""
import pathlib, subprocess, sys
from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
here = pathlib.Path(__file__).resolve().parent
widths = {"01": 430, "02": 860, "03": 860, "04": 860, "05": 430, "06": 1080, "07": 1300, "08": 1300, "09": 1300, "10": 1080}
for html in sorted(here.glob("[0-9][0-9]-*.html")):
    if len(sys.argv) > 1 and html.stem[:2] not in sys.argv[1:]:
        continue
    out = here.parent / (html.stem + ".png")
    w = widths[html.stem[:2]]
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=3",
                    f"--window-size={w},2600", f"--screenshot={out}", html.as_uri()], check=True, capture_output=True)
    im = Image.open(out).convert("RGB")
    bg = im.getpixel((im.width - 2, im.height - 2))
    px = im.load()
    bottom = im.height
    while bottom > 1 and all(px[x, bottom - 1] == bg for x in range(0, im.width, 3)):
        bottom -= 1
    im.crop((0, 0, im.width, min(im.height, bottom + 60))).save(out, optimize=True)
    print(out.name, im.width, bottom + 60)
