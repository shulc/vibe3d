#!/usr/bin/env bash
set -e

DUB_PKGS=~/.dub/packages
SDL=1.5.2
OGL=1.1.1
LOADER=1.1.5
COMMON=1.0.5
DIMGUI=1.89.7
SNPRINTF=1.2.3

ldc2 \
  -I${DUB_PKGS}/bindbc-sdl/${SDL}/bindbc-sdl/source \
  -I${DUB_PKGS}/bindbc-opengl/${OGL}/bindbc-opengl/source \
  -I${DUB_PKGS}/bindbc-loader/${LOADER}/bindbc-loader/source \
  -I${DUB_PKGS}/bindbc-common/${COMMON}/bindbc-common/source \
  -I${DUB_PKGS}/d_snprintf/${SNPRINTF}/d_snprintf/source \
  -I${DUB_PKGS}/d_imgui/${DIMGUI}/d_imgui/source \
  -I${DUB_PKGS}/d_imgui/${DIMGUI}/d_imgui \
  -I${DUB_PKGS}/d_imgui/${DIMGUI} \
  -Isource \
  -d-version=SDL_2020 \
  -d-version=GL_33 \
  -d-version=IMGUI_OPENGL3 \
  source/app.d \
  source/imgui_impl_sdl2.d \
  source/math.d \
  source/mesh.d \
  source/eventlog.d \
  source/handler.d \
  source/tool.d \
  $(find ${DUB_PKGS}/d_snprintf/${SNPRINTF}/d_snprintf/source -name "*.d") \
  $(find ${DUB_PKGS}/d_imgui/${DIMGUI}/d_imgui/source -name "*.d") \
  ${DUB_PKGS}/d_imgui/${DIMGUI}/d_imgui/backends_d/imgui_impl_opengl3.d \
  ${DUB_PKGS}/d_imgui/${DIMGUI}/d_imgui/backends_d/imgui_impl_opengl3_loader.d \
  $(find ${DUB_PKGS}/bindbc-sdl/${SDL}/bindbc-sdl/source -name "*.d") \
  $(find ${DUB_PKGS}/bindbc-opengl/${OGL}/bindbc-opengl/source -name "*.d") \
  $(find ${DUB_PKGS}/bindbc-loader/${LOADER}/bindbc-loader/source -name "*.d") \
  $(find ${DUB_PKGS}/bindbc-common/${COMMON}/bindbc-common/source -name "*.d") \
  -of=gl_triangle

echo "Build successful: ./gl_triangle"
