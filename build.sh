#!/usr/bin/env bash
set -e

DUB_PKGS=~/.dub/packages
SDL=1.5.2
OGL=1.1.1
LOADER=1.1.5
COMMON=1.0.5

ldc2 \
  -I${DUB_PKGS}/bindbc-sdl/${SDL}/bindbc-sdl/source \
  -I${DUB_PKGS}/bindbc-opengl/${OGL}/bindbc-opengl/source \
  -I${DUB_PKGS}/bindbc-loader/${LOADER}/bindbc-loader/source \
  -I${DUB_PKGS}/bindbc-common/${COMMON}/bindbc-common/source \
  -d-version=SDL_2020 \
  -d-version=GL_33 \
  source/app.d \
  $(find ${DUB_PKGS}/bindbc-sdl/${SDL}/bindbc-sdl/source -name "*.d") \
  $(find ${DUB_PKGS}/bindbc-opengl/${OGL}/bindbc-opengl/source -name "*.d") \
  $(find ${DUB_PKGS}/bindbc-loader/${LOADER}/bindbc-loader/source -name "*.d") \
  $(find ${DUB_PKGS}/bindbc-common/${COMMON}/bindbc-common/source -name "*.d") \
  -of=gl_triangle

echo "Build successful: ./gl_triangle"
