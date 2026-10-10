# Viewport shading images — sources and licences

Every file in this directory is **CC0 1.0 Universal** (public-domain dedication); no attribution is
required. They are the images of the Reflection display style: three equirectangular environments and
eight two-layer material-capture (MatCap) spheres. The binary embeds them as string imports
(`source/viewport_env.d`).

All files are 16-bit RGB PNGs converted offline from the downloaded Radiance `.hdr` originals by
`tools/convert_shading_images.py` (stored value = `round(clamp(value / 16, 0, 1) * 65535)`; the
environments are also downsampled 1024x512 -> 512x256, prefiltered with a Gaussian, sigma = 2 px,
wrapping horizontally, and exposure-normalised: value = `x / (1 + x)` of `exposure * linear` per
channel, the per-image exposure (`MANIFEST.tsv` column `exposure`) solved so that the area-weighted
mean luma equals the reference level 0.5124). `MANIFEST.tsv` ties every output to its original by sha256 (input file, output
file, decoded pixels). Conversion command:

    python3 tools/convert_shading_images.py --in <originals> --out assets/shading

## Environments (equirectangular, 512x256)

| file | source | authors | licence |
|---|---|---|---|
| env_studio_small_09.png | https://polyhaven.com/a/studio_small_09 (`studio_small_09_1k.hdr`) | Sergej Majboroda | CC0 1.0 |
| env_kloofendal_48d_partly_cloudy_puresky.png | https://polyhaven.com/a/kloofendal_48d_partly_cloudy_puresky (`kloofendal_48d_partly_cloudy_puresky_1k.hdr`) | Greg Zaal, Jarod Guest | CC0 1.0 |
| env_courtyard.png | https://polyhaven.com/a/courtyard (`courtyard_1k.hdr`) | Greg Zaal | CC0 1.0 |

## MatCaps (256x256, two layers each)

From a community CC0 matcap set (released as CC0 / public domain), converted from multi-layer
originals (layers `diffuse` and `specular`) and downscaled 512 -> 256 with area filtering.
`_diffuse` is multiplied by the surface base colour; `_specular` is added on top.

| file | licence |
|---|---|
| matcap_basic_grey_diffuse.png | CC0 1.0 |
| matcap_basic_grey_specular.png | CC0 1.0 |
| matcap_basic_side_diffuse.png | CC0 1.0 |
| matcap_basic_side_specular.png | CC0 1.0 |
| matcap_clay_studio_diffuse.png | CC0 1.0 |
| matcap_clay_studio_specular.png | CC0 1.0 |
| matcap_ceramic_lightbulb_diffuse.png | CC0 1.0 |
| matcap_ceramic_lightbulb_specular.png | CC0 1.0 |
| matcap_hard_surface_grey_diffuse.png | CC0 1.0 |
| matcap_hard_surface_grey_specular.png | CC0 1.0 |
| matcap_metal_carpaint_diffuse.png | CC0 1.0 |
| matcap_metal_carpaint_specular.png | CC0 1.0 |
| matcap_toon_light_diffuse.png | CC0 1.0 |
| matcap_toon_light_specular.png | CC0 1.0 |
| matcap_check_rim_light_diffuse.png | CC0 1.0 |
| matcap_check_rim_light_specular.png | CC0 1.0 |

The sha256 of every original and every output is in `MANIFEST.tsv`.
