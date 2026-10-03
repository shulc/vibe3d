#!/usr/bin/env python3
"""Offline conversion of the viewport shading images (Reflection / MatCap).

The editor's image decoder reads PNG, not Radiance .hdr, so the downloaded CC0
originals are converted once, here, into 16-bit RGB PNGs that the binary embeds
(`assets/shading/`, string-imported by `source/viewport_env.d`).

    python3 tools/convert_shading_images.py --in <originals> --out assets/shading
    python3 tools/convert_shading_images.py --in <originals> --out /var/tmp/x --check

`<originals>` holds `env/<name>_1k.hdr` (equirect 1024x512),
`matcap/<name>_{diffuse,specular}.hdr` (256x256) and `SHA256SUMS`; every input is
verified against `SHA256SUMS` first (a mismatch refuses the whole run).

Steps, identical for every run:
  * env: INTER_AREA 1024x512 -> 512x256, then a Gaussian prefilter sigma = 2 px
    (kernel radius 3 sigma) that WRAPS horizontally (the equirect seam is
    continuous) and reflects vertically;
  * env only, EXPOSURE NORMALISATION: value = reinhard(exposure * linear) per
    channel, reinhard(x) = x / (1 + x), with the per-image `exposure` solved by
    bisection (log space, 200 steps, deterministic) so that the area-weighted
    (sin(theta) per row) mean Rec.709 luma of the tone-mapped image equals
    ENV_TARGET_MEAN_LUMA — the reference level, measured as the area-weighted
    mean luma of the reference reflection cube's 8-bit texels used directly
    (the reference multiplies its stored values, no decode; our arm writes
    env unlit, with no gamma). Reinhard: monotone (so the solve
    has one root), parameter-free (nothing tuned), strictly below 1 (no
    channel clips at the 16-bit ceiling), near-identity in the darks and
    desaturating the hot spots toward white the way an LDR exposure does;
    MatCaps are not touched (their two layers ARE the lighting);
  * every file: stored = round(clamp(value / 16, 0, 1) * 65535) as uint16 RGB,
    PNG compression 9. The one linear scale (16) is `kShadingImageLinearScale`
    in `source/viewport_env.d`; the decoder multiplies it back — one decode
    path for both kinds (a normalised env simply occupies [0, 1/16) of the
    range: 4096 levels across [0, 1], far below one 8-bit display step). An env
    texel that rounds up to ENV_CLIP_LEVEL (4096, value 1.0) is refused: the
    Reinhard curve never reaches 1, so a texel there was clipped, not stored.

`MANIFEST.tsv` (written beside the outputs) ties each output to its input:
input sha256, output file sha256, and the sha256 of the DECODED pixels (uint16
little-endian, RGB, top row first) — file bytes can differ across zlib builds,
pixels cannot. `--check` converts into `--out` and compares those pixel hashes
against `--manifest` (default `assets/shading/MANIFEST.tsv`), printing
`PIXELS MATCH n/N` and `EXPOSURE MATCH n/N` (the `exposure` column, compared as
its 6-decimal text); exit status 1 on any mismatch.
"""
import argparse
import hashlib
import os
import sys

import cv2
import numpy as np

LINEAR_SCALE = 16.0
ENV_SIZE = (512, 256)
ENV_SIGMA = 2.0
# The reference level (see the docstring): area-weighted mean luma of the
# reference reflection cube's stored texels, measured 2026-10-03 -> 0.5124.
# `viewport_env.kEnvTargetMeanLuma` is the same number.
ENV_TARGET_MEAN_LUMA = 0.5124
# Residual after the solve: only the 16-bit rounding, at most half a step per
# channel = 0.5 * 16 / 65535 = 1.22e-4 (the luma weights sum to 1).
ENV_LEVEL_TOLERANCE = 1.25e-4
# The stored level of value 1.0 (65535 / LINEAR_SCALE, rounded): no env texel
# may reach it (the clip bound; Reinhard output is strictly below 1).
ENV_CLIP_LEVEL = 4096
LUMA = np.array([0.2126, 0.7152, 0.0722])   # Rec.709, applied to RGB
LICENCE = "CC0-1.0"

ENV_NAMES = ["studio_small_09", "kloofendal_48d_partly_cloudy_puresky", "courtyard"]
MATCAP_NAMES = ["basic_grey", "basic_side", "clay_studio", "ceramic_lightbulb",
                "hard_surface_grey", "metal_carpaint", "toon_light", "check_rim_light"]

HEADER = ["output", "input", "input_sha256", "output_sha256", "pixels_sha256",
          "width", "height", "linear_scale", "prefilter_sigma", "exposure", "licence"]


def sha256_file(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def jobs():
    """(output name, input relative path, is_env) in manifest order."""
    out = []
    for n in ENV_NAMES:
        out.append((f"env_{n}.png", f"env/{n}_1k.hdr", True))
    for n in MATCAP_NAMES:
        for layer in ("diffuse", "specular"):
            out.append((f"matcap_{n}_{layer}.png", f"matcap/{n}_{layer}.hdr", False))
    return out


def read_sums(src):
    sums = {}
    with open(os.path.join(src, "SHA256SUMS")) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                sums[parts[1]] = parts[0]
    return sums


def env_prefilter(img):
    r = int(round(3 * ENV_SIGMA))
    padded = np.concatenate([img[:, -r:], img, img[:, :r]], axis=1)
    k = 2 * r + 1
    blurred = cv2.GaussianBlur(padded, (k, k), ENV_SIGMA, borderType=cv2.BORDER_REFLECT)
    return blurred[:, r:-r]


def reinhard(x):
    return x / (1.0 + x)


def env_mean_luma(rgb):
    """Area-weighted mean luma of an equirect image (rows weighted sin(theta)
    at the row centre). `rgb` is H x W x 3 in R, G, B order."""
    h = rgb.shape[0]
    w = np.sin((np.arange(h) + 0.5) / h * np.pi)
    row = (rgb.astype(np.float64) @ LUMA).mean(axis=1)
    return float(np.sum(row * w) / np.sum(w))


def solve_exposure(rgb):
    """The exposure s with env_mean_luma(reinhard(s * rgb)) == the target."""
    lo, hi = np.log(1e-4), np.log(1e4)
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if env_mean_luma(reinhard(np.exp(mid) * rgb)) < ENV_TARGET_MEAN_LUMA:
            lo = mid
        else:
            hi = mid
    return float(np.exp(0.5 * (lo + hi)))


def convert(src_path, is_env):
    """(uint16 BGR image, exposure); exposure 1 for a MatCap layer."""
    img = cv2.imread(src_path, cv2.IMREAD_ANYDEPTH | cv2.IMREAD_COLOR)   # BGR float32
    if img is None:
        raise SystemExit(f"cannot read {src_path}")
    exposure = 1.0
    if is_env:
        img = cv2.resize(img, ENV_SIZE, interpolation=cv2.INTER_AREA)
        img = env_prefilter(img).astype(np.float64)
        exposure = solve_exposure(img[:, :, ::-1])
        img = reinhard(exposure * img)
    q = np.round(np.clip(img / LINEAR_SCALE, 0.0, 1.0) * 65535.0).astype(np.uint16)
    if is_env:
        hot = int(q.max())
        if hot >= ENV_CLIP_LEVEL:
            raise SystemExit(f"{src_path}: a stored env texel reaches {hot} >= {ENV_CLIP_LEVEL} "
                             "(value 1.0, the clip bound)")
        got = env_mean_luma(q[:, :, ::-1] / 65535.0 * LINEAR_SCALE)
        if abs(got - ENV_TARGET_MEAN_LUMA) > ENV_LEVEL_TOLERANCE:
            raise SystemExit(f"{src_path}: stored mean luma {got:.6f}, target {ENV_TARGET_MEAN_LUMA}")
    return q, exposure


def pixels_sha(bgr16):
    rgb = np.ascontiguousarray(bgr16[:, :, ::-1]).astype("<u2")
    return hashlib.sha256(rgb.tobytes()).hexdigest()


def read_manifest(path):
    rows = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            cols = line.rstrip("\n").split("\t")
            if cols[0] == "output":
                continue
            rows[cols[0]] = dict(zip(HEADER, cols))
    return rows


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--manifest", default=os.path.join(here, "..", "assets", "shading", "MANIFEST.tsv"))
    a = ap.parse_args()

    sums = read_sums(a.src)
    bad = []
    for _, rel, _ in jobs():
        p = os.path.join(a.src, rel)
        if not os.path.exists(p) or sums.get(rel) != sha256_file(p):
            bad.append(rel)
    if bad:
        raise SystemExit("input sha256 mismatch against SHA256SUMS: " + ", ".join(bad))

    os.makedirs(a.out, exist_ok=True)
    rows = []
    total = 0
    for out_name, rel, is_env in jobs():
        q, exposure = convert(os.path.join(a.src, rel), is_env)
        dst = os.path.join(a.out, out_name)
        cv2.imwrite(dst, q, [cv2.IMWRITE_PNG_COMPRESSION, 9])
        total += os.path.getsize(dst)
        rows.append([out_name, os.path.basename(rel), sums[rel], sha256_file(dst), pixels_sha(q),
                     str(q.shape[1]), str(q.shape[0]), f"{LINEAR_SCALE:g}",
                     f"{ENV_SIGMA:g}" if is_env else "0", f"{exposure:.6f}", LICENCE])

    if a.check:
        ref = read_manifest(a.manifest)
        ok = sum(1 for r in rows if r[0] in ref and ref[r[0]]["pixels_sha256"] == r[4])
        exp_ok = sum(1 for r in rows if r[0] in ref and ref[r[0]]["exposure"] == r[9])
        print(f"PIXELS MATCH {ok}/{len(rows)}")
        print(f"EXPOSURE MATCH {exp_ok}/{len(rows)}")
        for r in rows:
            if r[0] in ref and ref[r[0]]["exposure"] != r[9]:
                print(f"  {r[0]}: exposure {r[9]}, manifest {ref[r[0]]['exposure']}")
        return 0 if ok == exp_ok == len(rows) == len(ref) else 1

    with open(os.path.join(a.out, "MANIFEST.tsv"), "w") as f:
        f.write(f"# numpy {np.__version__} opencv {cv2.__version__}; "
                "pixels_sha256 = sha256 of uint16 little-endian RGB, top row first\n")
        f.write("\t".join(HEADER) + "\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"wrote {len(rows)} files, {total} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
