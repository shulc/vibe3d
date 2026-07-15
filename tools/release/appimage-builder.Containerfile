# syntax=docker/dockerfile:1
#
# Old-glibc build environment for the self-contained Linux AppImage.
#
# We build vibe3d + pack the AppImage INSIDE Ubuntu 20.04 (glibc 2.31) so the
# resulting binary is floored at glibc 2.31 — it then runs on essentially every
# Linux from 2020 onward (Ubuntu 20.04+, Debian 11+, Fedora 32+, RHEL 9, …),
# instead of at the Fedora-43 dev host's glibc 2.42 (which runs almost nowhere).
#
# The GENERATED code is what we care about: the whole native toolchain (gcc, ld,
# the SDL2/GTK3/-dev libs, the static-assimp C++ build) is Ubuntu 20.04's, so it
# links against glibc 2.31. LDC's prebuilt druntime/phobos .a files carry NO
# versioned glibc references (verified: all plain `U` symbols), so they bind to
# the 2.31 libc at final link — the output floors at 2.31 (measured lower still,
# ~2.17, for the base binary; the bundled Ubuntu-20.04 libs set the real floor).
#
# The one snag: LDC 1.42's prebuilt `ldc2` + `dub` binaries were themselves built
# on a newer distro and REQUIRE glibc >= 2.34 to *execute* — they won't even
# start on Ubuntu 20.04. We fix that WITHOUT raising the output floor: bundle a
# newer glibc (from ubuntu:22.04) and point ONLY those two tool binaries at it
# via `patchelf --set-interpreter/--set-rpath`. Their child processes (the native
# gcc/ld that actually link the output) keep the system glibc 2.31 — the patched
# rpath is per-binary, never inherited — so nothing about the produced binary
# changes. This is the standard "run a modern compiler, emit old-glibc code" trick.
#
# LDC >= 1.41 is REQUIRED (frontend 2.111+; Ubuntu 20.04's apt ldc is far older).
#
# Build (via the wrapper, which tags + caches this image):
#   tools/release/build_linux_appimage_container.sh
# or by hand:
#   podman build -t vibe3d-appimage-builder:ubuntu20.04 \
#     -f tools/release/appimage-builder.Containerfile tools/release

# --- Stage 1: harvest a consistent newer-glibc runtime set (2.35) -----------
# Used ONLY to let the prebuilt ldc2/dub binaries execute (see above). None of
# these files end up in the produced AppImage.
FROM ubuntu:22.04 AS glibc-donor
RUN set -eux; \
    mkdir -p /glibc-run; \
    for f in ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libpthread.so.0 \
             librt.so.1 libdl.so.2 libresolv.so.2 libgcc_s.so.1; do \
        if   [ -e "/usr/lib/x86_64-linux-gnu/$f" ]; then cp -L "/usr/lib/x86_64-linux-gnu/$f" /glibc-run/; \
        elif [ -e "/lib/x86_64-linux-gnu/$f"     ]; then cp -L "/lib/x86_64-linux-gnu/$f"     /glibc-run/; fi; \
    done; \
    ls -l /glibc-run

# --- Stage 2: the Ubuntu 20.04 (glibc 2.31) build environment ----------------
FROM ubuntu:20.04

# Never let apt block on tzdata/keyboard prompts in a non-interactive build.
ENV DEBIAN_FRONTEND=noninteractive
# appimagetool / linuxdeploy are themselves AppImages; containers lack FUSE, so
# they must self-extract. Honoured by the packaging tools AND by the produced
# AppImage during --verify.
ENV APPIMAGE_EXTRACT_AND_RUN=1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        `# --- build toolchain (cmake comes portable below; 20.04's 3.16` \
        `#     is too old for assimp 6, which needs >= 3.22). ninja: nfde's` \
        `#     CMake build uses the Ninja generator. unzip: onnxruntime SDK.` \
        build-essential git curl ca-certificates xz-utils unzip \
        ninja-build pkg-config dpkg-dev libcurl4 \
        `# --- link-time / bundling-source dev libs ---------------------` \
        `#     (NB: no libsdl2-dev — focal ships SDL 2.0.10, below the` \
        `#     SDL_2020 binding's 2.0.20 runtime floor; SDL2 is built from` \
        `#     source below so a modern-enough libSDL2 gets bundled.) ------` \
        zlib1g-dev \
        libgtk-3-dev \
        libgdk-pixbuf2.0-dev \
        libglib2.0-dev \
        libgl1-mesa-dev libegl1-mesa-dev \
        libwayland-dev libwayland-egl1 wayland-protocols \
        libxkbcommon-dev libxkbcommon-x11-dev \
        `# --- SDL2-from-source build deps: X11 + input + dbus ----------` \
        libx11-dev libxext-dev libxcursor-dev libxi-dev libxfixes-dev \
        libxrandr-dev libxrender-dev libxss-dev libxinerama-dev \
        libdbus-1-dev libudev-dev \
        `# --- packaging / linuxdeploy + gtk plugin helper tools --------` \
        patchelf file desktop-file-utils \
        librsvg2-2 librsvg2-common \
        libgtk-3-bin libgdk-pixbuf2.0-bin libglib2.0-bin \
        `# --- --verify runtime: X11 (Xvfb) + headless Wayland (weston) -` \
        `# + mesa software GL/EGL so a GL context comes up without a GPU  ` \
        xvfb xauth \
        weston \
        libgl1-mesa-dri libglx-mesa0 libegl1 libegl-mesa0 libgbm1 \
    ; \
    rm -rf /var/lib/apt/lists/*

# --- Portable CMake (assimp 6.0.5 needs >= 3.22; focal apt ships 3.16) -------
# The upstream Kitware binary is built for broad glibc compat and runs fine on
# 2.31. Put it FIRST on PATH so it shadows any apt cmake.
ARG CMAKE_VERSION=3.31.6
RUN set -eux; \
    url="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"; \
    curl -fSL --retry 3 --connect-timeout 30 -o /tmp/cmake.tar.gz "$url"; \
    mkdir -p /opt/cmake; \
    tar -xzf /tmp/cmake.tar.gz -C /opt/cmake --strip-components=1; \
    rm -f /tmp/cmake.tar.gz; \
    /opt/cmake/bin/cmake --version
ENV PATH=/opt/cmake/bin:${PATH}

# --- SDL2 from source (>= 2.0.20 for the SDL_2020 bindbc binding) ------------
# focal's libsdl2 is 2.0.10, which bindbc-sdl rejects at runtime ("Failed to
# load SDL2"). Build a modern SDL2 with the X11 + Wayland video backends. Install
# into the multiarch path /usr/lib/x86_64-linux-gnu (prefix=/usr) so the D-ImGui
# link helper (which probes that exact path, not /usr/local), ldconfig, and
# linuxdeploy all pick up THIS libSDL2. Links against the native glibc 2.31, so
# no floor impact.
ARG SDL2_VERSION=2.30.11
RUN set -eux; \
    url="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz"; \
    curl -fSL --retry 3 --connect-timeout 30 -o /tmp/SDL2.tar.gz "$url"; \
    mkdir -p /tmp/sdl2-src; \
    tar -xzf /tmp/SDL2.tar.gz -C /tmp/sdl2-src --strip-components=1; \
    cmake -S /tmp/sdl2-src -B /tmp/sdl2-build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
        -DSDL_X11=ON -DSDL_WAYLAND=ON -DSDL_OPENGL=ON -DSDL_OPENGLES=ON; \
    cmake --build /tmp/sdl2-build --parallel; \
    cmake --install /tmp/sdl2-build; \
    ldconfig; \
    rm -rf /tmp/SDL2.tar.gz /tmp/sdl2-src /tmp/sdl2-build; \
    ldconfig -p | grep 'libSDL2-2.0.so.0'; \
    test -e /usr/lib/x86_64-linux-gnu/libSDL2-2.0.so.0

# --- LDC 1.42.0 (portable tarball; bundles dub + rdmd) ----------------------
ARG LDC_VERSION=1.42.0
RUN set -eux; \
    url="https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/ldc2-${LDC_VERSION}-linux-x86_64.tar.xz"; \
    curl -fSL --retry 3 --connect-timeout 30 -o /tmp/ldc2.tar.xz "$url"; \
    mkdir -p /opt/ldc2; \
    tar -xJf /tmp/ldc2.tar.xz -C /opt/ldc2 --strip-components=1; \
    rm -f /tmp/ldc2.tar.xz

# Bundle the newer glibc and re-target ONLY the ldc2/dub binaries at it so they
# can execute on glibc 2.31. Everything they SPAWN (the native gcc/ld doing the
# actual linking) keeps the system 2.31 loader, so the produced binary is
# unaffected and stays floored at 2.31.
COPY --from=glibc-donor /glibc-run /opt/glibc-run
# NB: the rpath MUST be DT_RPATH (transitive), NOT DT_RUNPATH — dub transitively
# pulls the system libpthread (via the system libcurl it dlopens), and only
# DT_RPATH is honoured for the whole dependency chain, so ALL glibc components
# resolve to the single consistent 2.35 set (a 2.35 libc + 2.31 libpthread mix
# crashes on __libc_pthread_init@GLIBC_PRIVATE). patchelf 0.10 only downgrades a
# pre-existing DT_RUNPATH to DT_RPATH if we --remove-rpath first.
RUN set -eux; \
    for bin in /opt/ldc2/bin/ldc2 /opt/ldc2/bin/dub; do \
        patchelf --remove-rpath "$bin"; \
        patchelf --set-interpreter /opt/glibc-run/ld-linux-x86-64.so.2 \
                 --force-rpath --set-rpath /opt/glibc-run "$bin"; \
        readelf -d "$bin" | grep -q 'RPATH' || { echo "ERROR: $bin lacks DT_RPATH" >&2; exit 1; }; \
    done; \
    /opt/ldc2/bin/ldc2 --version; \
    /opt/ldc2/bin/dub --version

ENV PATH=/opt/ldc2/bin:${PATH}
# bundle_linux_appimage.sh honours $DC when it does its own build; ldc2 is on
# PATH regardless (used via --compiler=ldc2 for the wrapper's explicit build).
ENV DC=/opt/ldc2/bin/ldc2

# Smoke-test the toolchain: a threaded D program must build native and floor at
# glibc <= 2.31 (proves the shim did not leak the 2.35 loader into the output).
RUN set -eux; \
    printf 'import core.thread, core.stdc.stdio;\nvoid main(){auto t=new Thread({});t.start();t.join();printf("ok\\n");}\n' > /tmp/hello.d; \
    ldc2 -of=/tmp/hello /tmp/hello.d; \
    /tmp/hello; \
    floor="$(objdump -T /tmp/hello | grep -oE 'GLIBC_[0-9.]+' | sed 's/GLIBC_//' | sort -V | tail -1)"; \
    echo "toolchain self-test: output glibc floor = $floor (build-host glibc $(getconf GNU_LIBC_VERSION | awk '{print $2}'))"; \
    rm -f /tmp/hello /tmp/hello.d

WORKDIR /src
