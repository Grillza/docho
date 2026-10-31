#!/usr/bin/env python3
"""Copies the Android app's icons into the iOS asset catalog, so both apps draw the same glyphs.

- Material Symbols from `icons/*/src/main/valkyrieResources` become template images named after
  the file: `settings`, and `settings.fill` for the RoundedFilled style.
- The bottom navigation's animated vectors (`res/drawable/animated_*.xml`) become `nav.<tab>` in
  their unselected state and `nav.<tab>.fill` in their selected state (each animation's end values).
- `ic_docho_wordmark.xml` becomes `wordmark` (the logo at the top of More).
- The server and tracker logos (`brand_*`) become `brand.<name>`, in their own colours.

Run from anywhere: `ios/scripts/import-icons.py`. The output is committed; rerun after the Android
icons change.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "app/src/main/res/drawable"
OUT = ROOT / "ios/Docho/Resources/Assets.xcassets/Icons"
A = "{http://schemas.android.com/apk/res/android}"
AAPT = "{http://schemas.android.com/aapt}"

CONTENTS = {
    "images": [{"filename": None, "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
    "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
}


def write_imageset(name: str, svg: str, template: bool = True) -> None:
    folder = OUT / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.svg").write_text(svg)
    contents = json.loads(json.dumps(CONTENTS))
    contents["images"][0]["filename"] = f"{name}.svg"
    if not template:
        contents["properties"]["template-rendering-intent"] = "original"
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def material_symbols() -> int:
    count = 0
    for svg in sorted(ROOT.glob("icons/*/src/main/valkyrieResources/**/*.svg")):
        style = svg.parent.name
        if style == "valkyrieResources":  # brand icons (simple-icons)
            name = "brand." + svg.stem
        else:
            name = svg.stem
            if style.endswith("Filled"):
                name += ".fill"
        text = re.sub(r"<!--.*?-->\s*", "", svg.read_text(), flags=re.S)
        write_imageset(name, text)
        count += 1
    return count


def color(value: str | None) -> str:
    if not value or not value.startswith("#"):
        return "#000000"
    value = value[1:]
    if len(value) == 8:  # AARRGGBB
        return "#" + value[2:]
    return "#" + value


def group_transform(el: ET.Element, rotation: float | None) -> str:
    """Android's group transform: translate, then rotate and scale about the pivot."""
    tx = float(el.get(A + "translateX", 0))
    ty = float(el.get(A + "translateY", 0))
    px = float(el.get(A + "pivotX", 0))
    py = float(el.get(A + "pivotY", 0))
    sx = float(el.get(A + "scaleX", 1))
    sy = float(el.get(A + "scaleY", 1))
    rot = rotation if rotation is not None else float(el.get(A + "rotation", 0))
    parts = []
    if tx or ty:
        parts.append(f"translate({tx} {ty})")
    if px or py:
        parts.append(f"translate({px} {py})")
    if rot:
        parts.append(f"rotate({rot})")
    if sx != 1 or sy != 1:
        parts.append(f"scale({sx} {sy})")
    if px or py:
        parts.append(f"translate({-px} {-py})")
    return " ".join(parts)


def render(el: ET.Element, overrides: dict) -> str:
    tag = el.tag.split("}")[-1]
    name = el.get(A + "name")
    out = []
    if tag == "group":
        rotation = overrides.get((name, "rotation"))
        transform = group_transform(el, float(rotation) if rotation is not None else None)
        inner = render_children(el, overrides)
        out.append(f'<g transform="{transform}">{inner}</g>' if transform else f"<g>{inner}</g>")
    elif tag == "path":
        data = overrides.get((name, "pathData"), el.get(A + "pathData"))
        if data:
            attrs = [f'd="{data.strip()}"']
            gradient = el.find(f"{AAPT}attr[@name='android:fillColor']/gradient")
            if gradient is not None:
                gradient_id = f"gradient{next(CLIP_IDS)}"
                stops = "".join(
                    f'<stop offset="{item.get(A + "offset")}" stop-color="{color(item.get(A + "color"))}"/>'
                    for item in gradient.findall("item")
                )
                coords = " ".join(f'{svg}="{gradient.get(A + android)}"' for svg, android in
                                  [("x1", "startX"), ("y1", "startY"), ("x2", "endX"), ("y2", "endY")])
                out.append(f'<defs><linearGradient id="{gradient_id}" gradientUnits="userSpaceOnUse" {coords}>'
                           f"{stops}</linearGradient></defs>")
                attrs.append(f'fill="url(#{gradient_id})"')
            elif el.get(A + "fillColor"):
                attrs.append(f'fill="{color(el.get(A + "fillColor"))}"')
            else:
                attrs.append('fill="none"')
            if el.get(A + "fillType") == "evenOdd":
                attrs.append('fill-rule="evenodd"')
            if el.get(A + "strokeColor"):
                attrs.append(f'stroke="{color(el.get(A + "strokeColor"))}"')
                attrs.append(f'stroke-width="{el.get(A + "strokeWidth", "1")}"')
            alpha = el.get(A + "fillAlpha")
            if alpha:
                attrs.append(f'fill-opacity="{alpha}"')
            out.append("<path " + " ".join(attrs) + "/>")
    return "".join(out)


CLIP_IDS = iter(range(1_000_000))


def render_children(el: ET.Element, overrides: dict) -> str:
    """A container's children; an Android clip-path clips the siblings that follow it."""
    clips = [child for child in el if child.tag.split("}")[-1] == "clip-path"]
    inner = "".join(render(child, overrides) for child in el)
    for clip in clips:
        clip_id = f"clip{next(CLIP_IDS)}"
        inner = (
            f'<defs><clipPath id="{clip_id}"><path d="{clip.get(A + "pathData")}"/></clipPath></defs>'
            f'<g clip-path="url(#{clip_id})">{inner}</g>'
        )
    return inner


def vector_svg(vector: ET.Element, overrides: dict) -> str:
    width = float(vector.get(A + "viewportWidth"))
    height = float(vector.get(A + "viewportHeight"))
    dp_w = vector.get(A + "width", "24dp").replace("dp", "")
    dp_h = vector.get(A + "height", "24dp").replace("dp", "")
    body = render_children(vector, overrides)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{dp_w}" height="{dp_h}" '
        f'viewBox="0 0 {width:g} {height:g}">{body}</svg>\n'
    )


def animated(name: str, file: str) -> None:
    root = ET.parse(RES / file).getroot()
    vector = root.find(".//vector")
    write_imageset(f"nav.{name}", vector_svg(vector, {}))
    ends = {}
    for target in root.findall("target"):
        for animator in target.iter("objectAnimator"):
            ends[(target.get(A + "name"), animator.get(A + "propertyName"))] = animator.get(A + "valueTo")
    write_imageset(f"nav.{name}.fill", vector_svg(vector, ends))


def static(name: str, file: str, template: bool = True) -> None:
    write_imageset(name, vector_svg(ET.parse(RES / file).getroot(), {}), template)


TRACKER_VECTORS = ["anilist", "myanimelist", "kitsu", "mangaupdates", "shikimori", "bangumi", "hikka"]
TRACKER_BITMAPS = ["comick", "mangabaka"]


def bitmap(name: str, webp: Path) -> None:
    """A WebP logo as a PNG (sips converts it), shown as is."""
    folder = OUT / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["sips", "-s", "format", "png", str(webp), "--out", str(folder / f"{name}.png")],
                   check=True, capture_output=True)
    contents = {
        "images": [{"filename": f"{name}.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "original"},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    (OUT / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    count = material_symbols()
    for tab in ["library", "updates", "history"]:
        animated(tab, f"animated_{tab}.xml")
    animated("browse", "animated_browse_enter.xml")
    # animated_more_* places its three dots through animated groups; this is its resting state.
    dots = "".join(f'<circle cx="{x}" cy="480" r="90"/>' for x in (210, 480, 750))
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 960 960">{dots}</svg>\n'
    write_imageset("nav.more", svg)
    write_imageset("nav.more.fill", svg)
    static("wordmark", "ic_docho_wordmark.xml")
    for server in ["kavita", "komga", "bookorbit", "koreader", "suwayomi"]:
        static(f"brand.{server}", f"brand_{server}.xml", template=False)
    for tracker in TRACKER_VECTORS:
        static(f"brand.{tracker}", f"brand_{tracker}.xml", template=False)
    for tracker in TRACKER_BITMAPS:
        bitmap(f"brand.{tracker}", ROOT / f"app/src/main/res/drawable-nodpi/brand_{tracker}.webp")
    logos = 5 + len(TRACKER_VECTORS) + len(TRACKER_BITMAPS)
    print(f"{count} symbols, 5 navigation icons, the wordmark and {logos} server and tracker logos written to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
