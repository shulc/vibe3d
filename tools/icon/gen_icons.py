#!/usr/bin/env python3
"""Regenerate all raster icon assets from assets/icon/vibe3d.svg.

The SVG is the source of truth: a flat list of <polygon> facets. This script
rasterizes the polygons directly (4x supersampled, transparent background) so
no external SVG renderer is needed — only Pillow.

Outputs (all under assets/icon/):
  png/vibe3d_{16,32,48,64,128,256,512,1024}.png   Linux hicolor set + master
  vibe3d.ico                                       Windows (16..256 multi-res)
  vibe3d.res                                       pre-compiled Windows resource
                                                   (RT_GROUP_ICON, linked into
                                                   the .exe via dub on Windows)
  vibe3d.icns                                      macOS (16..1024)
  icon_64.rgba                                     raw RGBA for SDL_SetWindowIcon

Usage: python3 tools/icon/gen_icons.py
"""
import re
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent.parent
ICON_DIR = ROOT / "assets" / "icon"
SVG = ICON_DIR / "vibe3d.svg"
CANVAS = 1024  # SVG viewBox is 0 0 1024 1024
SS = 4  # supersampling factor

PNG_SIZES = [16, 32, 48, 64, 128, 256, 512, 1024]
ICO_SIZES = [16, 24, 32, 48, 64, 256]
ICNS_SIZES = [16, 32, 64, 128, 256, 512, 1024]
RGBA_SIZE = 64  # embedded window icon


def parse_svg(path):
    """Extract (points, color) facets from the flat-polygon SVG."""
    text = path.read_text()
    faces = []
    for m in re.finditer(r'<polygon points="([^"]+)" fill="#([0-9a-fA-F]{6})"', text):
        pts = [tuple(float(v) for v in p.split(",")) for p in m.group(1).split()]
        rgb = tuple(int(m.group(2)[i : i + 2], 16) for i in (0, 2, 4))
        faces.append((pts, rgb))
    if not faces:
        sys.exit(f"no polygons parsed from {path}")
    return faces


def render_master(faces):
    img = Image.new("RGBA", (CANVAS * SS, CANVAS * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for pts, rgb in faces:
        spts = [(x * SS, y * SS) for x, y in pts]
        c = rgb + (255,)
        # outline in the fill color seals hairline seams between facets
        d.polygon(spts, fill=c, outline=c, width=SS + 2)
    return img


def write_res(path, images):
    """Write a pre-compiled Win32 .res with the app icon.

    A .res is a flat sequence of [RESOURCEHEADER + data] records: one empty
    sentinel record, one RT_ICON (type 3) per image (PNG-compressed entries,
    supported since Vista), and one RT_GROUP_ICON (type 14) directory that
    references the RT_ICON records by id. Linkers (link.exe / lld-link via
    dmd/ldc) accept it directly, so no rc.exe/windres is needed at build time.
    """

    def record(rtype, name_id, data, mem_flags=0x1010, lang=0x0409):
        hdr = struct.pack(
            "<II", len(data), 32
        ) + struct.pack(  # DataSize, HeaderSize
            "<HHHH", 0xFFFF, rtype, 0xFFFF, name_id  # TYPE, NAME ordinals
        ) + struct.pack(
            "<IHHII", 0, mem_flags, lang, 0, 0
        )  # DataVersion, MemoryFlags, LanguageId, Version, Characteristics
        pad = b"\0" * (-len(data) % 4)
        return hdr + data + pad

    blob = record(0, 0, b"", mem_flags=0, lang=0)  # sentinel record
    entries = b""
    for i, im in enumerate(images, start=1):
        import io

        buf = io.BytesIO()
        im.save(buf, format="PNG")
        png = buf.getvalue()
        blob += record(3, i, png)  # RT_ICON
        w = im.width if im.width < 256 else 0
        entries += struct.pack("<BBBBHHIH", w, w, 0, 0, 1, 32, len(png), i)
    # GRPICONDIR: idReserved, idType=1 (icon), idCount, then the entries
    group = struct.pack("<HHH", 0, 1, len(images)) + entries
    blob += record(14, 1, group)  # RT_GROUP_ICON
    path.write_bytes(blob)


def main():
    faces = parse_svg(SVG)
    master = render_master(faces)
    print(f"{len(faces)} facets parsed from {SVG.relative_to(ROOT)}")

    png_dir = ICON_DIR / "png"
    png_dir.mkdir(parents=True, exist_ok=True)
    by_size = {}
    for s in sorted(set(PNG_SIZES + ICO_SIZES + ICNS_SIZES + [RGBA_SIZE])):
        by_size[s] = master.resize((s, s), Image.LANCZOS)
    for s in PNG_SIZES:
        out = png_dir / f"vibe3d_{s}.png"
        by_size[s].save(out)
        print(f"  {out.relative_to(ROOT)}")

    ico = ICON_DIR / "vibe3d.ico"
    by_size[max(ICO_SIZES)].save(ico, sizes=[(s, s) for s in ICO_SIZES])
    print(f"  {ico.relative_to(ROOT)} ({', '.join(map(str, ICO_SIZES))})")

    res = ICON_DIR / "vibe3d.res"
    write_res(res, [by_size[s] for s in ICO_SIZES])
    print(f"  {res.relative_to(ROOT)} ({res.stat().st_size} bytes)")

    icns = ICON_DIR / "vibe3d.icns"
    by_size[1024].save(
        icns, append_images=[by_size[s] for s in ICNS_SIZES if s != 1024]
    )
    print(f"  {icns.relative_to(ROOT)} ({', '.join(map(str, ICNS_SIZES))})")

    # raw RGBA blob embedded into the binary for SDL_SetWindowIcon:
    # 8-byte header (u32 LE width, height) + width*height*4 bytes RGBA
    rgba = ICON_DIR / f"icon_{RGBA_SIZE}.rgba"
    im = by_size[RGBA_SIZE]
    rgba.write_bytes(struct.pack("<II", RGBA_SIZE, RGBA_SIZE) + im.tobytes())
    print(f"  {rgba.relative_to(ROOT)} ({rgba.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
