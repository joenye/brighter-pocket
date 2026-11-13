#!/usr/bin/env python3
"""Draw the app icons of the layer: the Brighter Atlas mark, its A replaced by a white Apple logo.

usage: tools/make_icons.py [--mark ~/Projects/brighter-atlas/webapp/brand/mark.svg] [--chrome PATH] [--only icons|lockup]

Brighter Atlas's "app" look (webapp/tools/icons.ts): the mark at 0.9 of its 32 x 32 box,
its visual centre (16, 15.9) at the middle, on a radial glow from #232327 to #0e0e10 centred
35% down. The mark's A (its #a path) gives way to the Apple logo, white, in the A's box: the
macOS font glyph U+F8FF, a little smaller than the A, drawn as text, so no copy of the logo's outline is kept here (it needs
a Mac's system fonts). The iOS app (launcher/) has it full bleed, iOS rounds the corners; its
dark variants are the same, its tinted ones the mark in grey on black, which iOS tints. The
Mac app (management/) has it on Apple's macOS tile: 824 of 1024 with a corner radius of 185,
a transparent margin round it. Every file the platform's AppIcon.appiconset names is drawn at
its own pixel size by headless Chrome, so the PNGs match the SVG exactly, into
pocket/<app>/Assets.xcassets/AppIcon.appiconset/ (pocket/overlay.map puts them in place).

The lockup the loading screen shows (PocketLoadingView.m) is the one brighteratlas.com/pocket heads its page with
(css/pocket.css, .pk-lockup at phone width): the icon, then "Brighter" in Roboto Slab SemiBold (the site's own subset,
webapp/vendor/fonts/brighter.woff2, Apache 2.0) and "POCKET" in the system font, bold and spaced, white with a
black outline (as the Apple logo in the icon, and legible on either background). It is drawn the same way, at 2x
and 3x, for the dark appearance ("Brighter" in the site's light grey) and the light one ("Brighter" near black),
into pocket/launcher/Assets.xcassets/PocketLockup.imageset/.
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

CHROMES = ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
           "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary")
MARK = Path.home() / "Projects/brighter-atlas/webapp/brand/mark.svg"
WORDS_FONT = Path.home() / "Projects/brighter-atlas/webapp/vendor/fonts/brighter.woff2"
# The lockup in points (the site's at phone width): the icon's side, "Brighter" and "POCKET"'s sizes, and the gaps.
LOCKUP = {"icon": 52, "name": 24, "sub": 20, "gap": 14, "words_gap": 8}
# ("Brighter"'s colour, the icon's edge) for each appearance: dark is the site's (--fg0). POCKET is white, outlined.
LOCKUP_COLOURS = {"dark": ("#e8ecf2", "0 0 0 1px rgba(255,255,255,.08)"),
                  "light": ("#16181d", "none")}
SCALE, CENTRE = 0.9, (16, 15.9)
GLOW = ('<radialGradient id="glow" cx="50%" cy="35%" r="75%"><stop offset="0" stop-color="#232327"/>'
        '<stop offset="1" stop-color="#0e0e10"/></radialGradient>')
# Grey from the mark's luminance, a little brighter, for the tinted icons.
GREY = ('<filter id="grey" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values="'
        + " ".join([".26 .86 .09 0 0"] * 3) + ' 0 0 0 1 0"/></filter>')
SETS = ("launcher", "management")
# The Apple logo in place of the A: centred on x 16 and on the A's middle (20.25 of the mark's 32), a
# little smaller than the A, clear of the arches.
APPLE = ('<text x="16" y="25.1" text-anchor="middle" font-size="11" fill="#fff" '
         'font-family="SF Pro Display, .AppleSystemUIFont, Helvetica Neue, Helvetica">\uf8ff</text>')


def compose(mark: str, look: str) -> str:
    """A look ("app", "tinted" or "mac") as an SVG document."""
    move = f"translate({CENTRE[0] * (1 - SCALE):.3f} {16 - CENTRE[1] * SCALE:.3f}) scale({SCALE})"
    if look == "tinted":
        body = f'<defs>{GREY}</defs><rect width="32" height="32"/><g transform="{move}" filter="url(#grey)">{mark}</g>'
    else:
        rx = ' rx="7.184"' if look == "mac" else ""   # 185 of 824
        body = f'<defs>{GLOW}</defs><rect width="32" height="32"{rx} fill="url(#glow)"/><g transform="{move}">{mark}</g>'
    if look == "mac":
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
                f'<svg x="100" y="100" width="824" height="824" viewBox="0 0 32 32">{body}</svg></svg>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">{body}</svg>'


def draw(chrome: str, svg: str, size: int, out: Path) -> None:
    with tempfile.TemporaryDirectory() as scratch:
        page = Path(scratch) / "icon.html"
        source = base64.b64encode(svg.encode()).decode()
        page.write_text(f'<html><body style="margin:0;background:transparent"><img style="display:block;width:{size}px;'
                        f'height:{size}px" src="data:image/svg+xml;base64,{source}"></body></html>')
        subprocess.run([chrome, "--headless", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--default-background-color=00000000", f"--window-size={size},{size}",
                        f"--screenshot={out}", page.as_uri()], check=True, capture_output=True)


def lockup_page(icon_svg: str, font: bytes, appearance: str) -> str:
    """The lockup alone on a transparent page; its title, once laid out, is its size in points."""
    words, edge = LOCKUP_COLOURS[appearance]
    l = LOCKUP
    icon = base64.b64encode(icon_svg.encode()).decode()
    return f"""<html><head><style>
@font-face {{ font-family: 'BA Brighter'; font-weight: 600; src: url(data:font/woff2;base64,{base64.b64encode(font).decode()}) format('woff2'); }}
html, body {{ margin: 0; background: transparent; }}
#l {{ display: inline-flex; align-items: center; gap: {l["gap"]}px; padding: 1px; line-height: 1; white-space: nowrap; }}
#l img {{ display: block; width: {l["icon"]}px; height: {l["icon"]}px; border-radius: 22.5%; box-shadow: {edge}; }}
.w {{ display: inline-flex; align-items: baseline; gap: {l["words_gap"]}px; }}
.n {{ font-family: 'BA Brighter'; font-weight: 600; font-size: {l["name"]}px; letter-spacing: 0.2px; color: {words}; }}
.s {{ font-family: -apple-system, 'Helvetica Neue', sans-serif; font-size: {l["sub"]}px; font-weight: 700;
      letter-spacing: 0.08em; margin-right: -0.08em; text-transform: uppercase; color: #fff;
      -webkit-text-stroke: 2px #000; paint-order: stroke fill; }}
</style></head><body><div id="l"><img src="data:image/svg+xml;base64,{icon}"><span class="w"><span class="n">Brighter</span>
<span class="s">Pocket</span></span></div>
<script>document.fonts.ready.then(() => {{ const r = document.getElementById('l').getBoundingClientRect();
document.title = Math.ceil(r.width) + 'x' + Math.ceil(r.height); }});</script></body></html>"""


def draw_lockup(chrome: str, mark: str) -> None:
    """PocketLockup.imageset: the lockup at 2x and 3x, dark and light."""
    font = WORDS_FONT.read_bytes()
    out = common.ROOT / "pocket/launcher/Assets.xcassets/PocketLockup.imageset"
    out.mkdir(parents=True, exist_ok=True)
    images = []
    with tempfile.TemporaryDirectory() as scratch:
        for appearance in ("light", "dark"):
            page = Path(scratch) / f"lockup-{appearance}.html"
            page.write_text(lockup_page(compose(mark, "app"), font, appearance))
            dom = subprocess.run([chrome, "--headless", "--virtual-time-budget=5000", "--dump-dom", page.as_uri()],
                                 check=True, capture_output=True, text=True).stdout
            size = re.search(r"<title>(\d+)x(\d+)</title>", dom)
            if not size:
                raise SystemExit("the lockup's page did not lay out (no size in its title)")
            width, height = int(size[1]), int(size[2])
            for scale in (2, 3):
                name = f"PocketLockup{'-Dark' if appearance == 'dark' else ''}@{scale}x.png"
                subprocess.run([chrome, "--headless", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
                                "--default-background-color=00000000", "--virtual-time-budget=5000",
                                f"--window-size={width},{height}", f"--screenshot={out / name}", page.as_uri()],
                               check=True, capture_output=True)
                image = {"filename": name, "idiom": "universal", "scale": f"{scale}x"}
                if appearance == "dark":
                    image["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
                images.append(image)
                print(f"{(out / name).relative_to(common.ROOT)}  {appearance}, {width} x {height} pt at {scale}x")
    images.sort(key=lambda i: ("appearances" in i, i["scale"]))
    (out / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                                                  indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--mark", type=Path, default=MARK)
    parser.add_argument("--chrome", default=next((c for c in CHROMES if Path(c).exists()), CHROMES[0]))
    parser.add_argument("--only", choices=("icons", "lockup"), help="draw only the app icons, or only the lockup")
    args = parser.parse_args()
    mark = re.sub(r"<!--.*?-->", "", re.sub(r"^.*?<svg[^>]*>|</svg>\s*$", "", args.mark.read_text(), flags=re.S), flags=re.S)
    mark = re.sub(r'\s*<use href="#a"[^>]*/>', "", mark) + APPLE
    if args.only != "icons":
        draw_lockup(args.chrome, mark)
    if args.only == "lockup":
        return 0
    for app in SETS:
        folder = Path(app) / "Assets.xcassets/AppIcon.appiconset"
        out = common.ROOT / "pocket" / folder
        out.mkdir(parents=True, exist_ok=True)
        drawn: dict[tuple[str, int], Path] = {}
        for image in json.loads((common.ROOT / "platform" / folder / "Contents.json").read_text())["images"]:
            appearance = {a["value"] for a in image.get("appearances", [])}
            look = "mac" if image["idiom"] == "mac" else "tinted" if "tinted" in appearance else "app"
            size = round(float(image["size"].split("x")[0]) * float(image.get("scale", "1x")[:-1]))
            target = out / image["filename"]
            if (look, size) in drawn:
                target.write_bytes(drawn[look, size].read_bytes())
            else:
                draw(args.chrome, compose(mark, look), size, target)
                drawn[look, size] = target
            print(f"{target.relative_to(common.ROOT)}  {look}, {size} px")
    return 0


if __name__ == "__main__":
    sys.exit(main())
