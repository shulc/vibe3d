# Application icon

`vibe3d.svg` is the source of truth — 24 flat-color polygon facets, transparent
background, 1024×1024 viewBox. Every other file here is generated from it:

```bash
python3 tools/icon/gen_icons.py     # requires Pillow
```

| File | Used by |
|---|---|
| `png/vibe3d_{16..1024}.png` | Linux: install as `hicolor/<S>x<S>/apps/vibe3d.png` |
| `vibe3d.desktop` | Linux: desktop entry (Wayland takes the window icon from here) |
| `vibe3d.ico` | Windows: standalone multi-res icon (16–256) |
| `vibe3d.res` | Windows: pre-compiled resource, linked into the .exe by dub (`sourceFiles-windows`) — no rc.exe needed |
| `vibe3d.icns` | macOS: goes into the `.app` bundle (`CFBundleIconFile`) |
| `icon_64.rgba` | Embedded into the binary (`import()`) for `SDL_SetWindowIcon` at startup (X11/Windows titlebar + taskbar); 8-byte LE w/h header + raw RGBA8 |
