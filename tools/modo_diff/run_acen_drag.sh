#!/bin/bash
# Cross-check vibe3d ACEN modes against MODO via real mouse-drag-driven
# Tool Pipe evaluate. Architectural reasons (see
# memory/modo_acen_select_headless.md) prevent the headless
# `modo_cl + tool.doApply` path from triggering ACEN evaluate; we need a
# full GUI MODO + Xvfb + matchbox WM + xdotool drag.
#
# This is a SEPARATE one-off check, NOT part of the regular test suite.
# Run only when ACEN/AXIS Tool Pipe stages change in a way that warrants
# re-verification against MODO ground truth.
#
# Requires: Xvfb, matchbox-window-manager, xdotool, ImageMagick (import).
# Override with env vars: MODO_BIN, MODO_LD, MODO_CONTENT.
#
# Usage:
#   run_acen_drag.sh                          # all modes × default patterns
#   run_acen_drag.sh select                   # one mode × default patterns
#   run_acen_drag.sh select origin border     # subset of modes
#
# Override PATTERNS env var to pick selection patterns:
#   PATTERNS="single_top asymmetric" run_acen_drag.sh
#
# single_top:  unit cube, top face only — all centroid modes converge.
# asymmetric:  2x2x2 segment cube, two top -X polys + one disjoint
#              bottom +X+Z poly. Distinguishes Select / Border / Local.
#
# Exit 0 = all PASS. Exit 1 = at least one FAIL. Exit 2+ = setup error.

set -uo pipefail

DISPLAY_NUM=:99
MODO_BIN=${MODO_BIN:-/home/ashagarov/Program/Modo902/modo}
MODO_LD=${MODO_LD:-/home/ashagarov/.local/lib}
MODO_CONTENT=${MODO_CONTENT:-/home/ashagarov/.luxology/Content}
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
USER_SCRIPTS=$HOME/.luxology/Scripts
SYSTEM_SCRIPTS=$(dirname "$MODO_BIN")/extra/Scripts

# Default mode list. Each mode predicts a pivot; the verifier checks the
# resulting cube vertices match.
DEFAULT_MODES=(select selectauto auto border origin local)
MODES=("${@:-${DEFAULT_MODES[@]}}")
PATTERNS_LIST=(${PATTERNS:-single_top asymmetric})
TOOLS_LIST=(${TOOLS:-scale move})
# sphere_top + rotate are wired up but not in defaults yet — sphere
# triggers a setup race (the drag fires before the scene is fully
# updated for sphere geometry), and rotate via TransformRotate doesn't
# pick up dragAxis cleanly under our xdotool path. Run with
# `PATTERNS=sphere_top` or `TOOLS=rotate` to debug.

# UI coordinates for MODO under matchbox WM at 1920x1080.
FILE_MENU_X=17;     FILE_MENU_Y=10
RESET_ITEM_X=40;    RESET_ITEM_Y=778
POPUP_OK_X=1175;    POPUP_OK_Y=538
CMD_BAR_X=1750;     CMD_BAR_Y=1063
CUBE_DRAG_X=1000;   CUBE_DRAG_Y=580

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

cleanup() {
  pkill -9 -f Modo902 2>/dev/null || true
  pkill -9 -f foundrycrashhandler 2>/dev/null || true
  pkill -9 -f matchbox-window-manager 2>/dev/null || true
  local pid=$(pgrep -f "Xvfb $DISPLAY_NUM" 2>/dev/null | head -1)
  [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  sleep 1
  rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
}
trap cleanup EXIT

ui_click() {
  DISPLAY="$DISPLAY_NUM" xdotool mousemove "$1" "$2"
  sleep 0.3
  DISPLAY="$DISPLAY_NUM" xdotool click 1
}

ui_type() {
  ui_click "$CMD_BAR_X" "$CMD_BAR_Y"
  sleep 0.3
  DISPLAY="$DISPLAY_NUM" xdotool type --delay 30 "$1"
  sleep 0.3
  DISPLAY="$DISPLAY_NUM" xdotool key Return
}

mouse_drag() {
  DISPLAY="$DISPLAY_NUM" xdotool mousemove "$1" "$2"
  sleep 0.5
  DISPLAY="$DISPLAY_NUM" xdotool mousedown 1
  sleep 0.3
  local x=$1
  local y=$2
  for step in 20 40 60 80 100; do
    DISPLAY="$DISPLAY_NUM" xdotool mousemove "$((x + step))" "$y"
    sleep 0.05
  done
  sleep 0.3
  DISPLAY="$DISPLAY_NUM" xdotool mouseup 1
}

blue "=== prereqs ==="
for cmd in xdotool matchbox-window-manager Xvfb import python3; do
  if ! command -v "$cmd" >/dev/null; then
    red "ERROR: $cmd not in PATH"; exit 2
  fi
done
[ -x "$MODO_BIN" ] || { red "ERROR: $MODO_BIN not executable"; exit 2; }
[ -d "$USER_SCRIPTS" ] || { red "ERROR: $USER_SCRIPTS missing"; exit 2; }
[ -d "$SYSTEM_SCRIPTS" ] || { red "ERROR: $SYSTEM_SCRIPTS missing"; exit 2; }
[ -f "$SCRIPT_DIR/modo_drag_setup.py" ] || { red "ERROR: missing modo_drag_setup.py"; exit 2; }
[ -f "$SCRIPT_DIR/modo_dump_verts.py" ] || { red "ERROR: missing modo_dump_verts.py"; exit 2; }

blue "=== starting Xvfb on $DISPLAY_NUM ==="
cleanup
Xvfb "$DISPLAY_NUM" -screen 0 1920x1080x24 -nolisten tcp \
  > /tmp/modo_acen_xvfb.log 2>&1 &
disown
sleep 2
DISPLAY="$DISPLAY_NUM" xdpyinfo > /dev/null 2>&1 \
  || { red "ERROR: Xvfb failed to start"; exit 3; }

blue "=== starting matchbox WM ==="
DISPLAY="$DISPLAY_NUM" matchbox-window-manager -use_titlebar no \
  > /tmp/modo_acen_matchbox.log 2>&1 &
disown
sleep 2
DISPLAY="$DISPLAY_NUM" xprop -root 2>/dev/null \
  | grep -q _NET_SUPPORTING_WM_CHECK \
  || { red "ERROR: matchbox didn't register as WM"; exit 3; }

blue "=== copying MODO scripts ==="
cp "$SCRIPT_DIR/modo_drag_setup.py" "$USER_SCRIPTS/"
cp "$SCRIPT_DIR/modo_drag_setup.py" "$SYSTEM_SCRIPTS/"
cp "$SCRIPT_DIR/modo_dump_verts.py" "$USER_SCRIPTS/"
cp "$SCRIPT_DIR/modo_dump_verts.py" "$SYSTEM_SCRIPTS/"

blue "=== launching MODO ==="
DISPLAY="$DISPLAY_NUM" LIBGL_ALWAYS_SOFTWARE=1 \
  LD_LIBRARY_PATH="$MODO_LD" NEXUS_CONTENT="$MODO_CONTENT" \
  "$MODO_BIN" > /tmp/modo_acen_log.txt 2>&1 &
disown

blue "=== waiting for MODO viewport render ==="
RENDERED=0
for i in $(seq 1 60); do
  pid=$(ps -eo pid,cmd | awk '$2 ~ /Modo902\/modo$/ { print $1 }' | head -1)
  if [ -z "$pid" ]; then red "ERROR: MODO died"; exit 4; fi
  DISPLAY="$DISPLAY_NUM" import -window root /tmp/modo_acen_poll.png 2>/dev/null
  size=$(stat -c%s /tmp/modo_acen_poll.png 2>/dev/null || echo 0)
  if [ "$size" -gt 50000 ]; then
    echo "  rendered in ${i}s (${size}b)"
    RENDERED=1
    break
  fi
  sleep 1
done
[ "$RENDERED" -eq 1 ] || { red "ERROR: MODO didn't render within 60s"; exit 4; }

blue "=== File → Reset → OK ==="
ui_click "$FILE_MENU_X"  "$FILE_MENU_Y";  sleep 1
ui_click "$RESET_ITEM_X" "$RESET_ITEM_Y"; sleep 2
ui_click "$POPUP_OK_X"   "$POPUP_OK_Y";   sleep 3

# Run the test for each (tool, pattern, mode) combination.
PASS_LIST=()
FAIL_LIST=()

for tool in "${TOOLS_LIST[@]}"; do
for pattern in "${PATTERNS_LIST[@]}"; do
for mode in "${MODES[@]}"; do
  label="${tool}/${pattern}/${mode}"
  blue ""
  blue "============================================================"
  blue "=== tool: xfrm.${tool}   pattern: ${pattern}   mode: actr.${mode}"
  blue "============================================================"

  rm -f /tmp/modo_drag_state.json /tmp/modo_drag_result.json

  ui_type "@modo_drag_setup.py ${mode} ${pattern} ${tool}"
  sleep 4

  if [ ! -f /tmp/modo_drag_state.json ]; then
    red "  ERROR: setup did not produce /tmp/modo_drag_state.json"
    FAIL_LIST+=("${label} (setup failed)")
    continue
  fi

  mouse_drag "$CUBE_DRAG_X" "$CUBE_DRAG_Y"
  sleep 2

  ui_type "@modo_dump_verts.py"
  sleep 3

  if [ ! -f /tmp/modo_drag_result.json ]; then
    red "  ERROR: dump did not produce /tmp/modo_drag_result.json"
    FAIL_LIST+=("${label} (dump failed)")
    continue
  fi

  if MODE="$mode" python3 "$SCRIPT_DIR/verify_acen_drag.py" \
       /tmp/modo_drag_result.json; then
    PASS_LIST+=("${label}")
  else
    FAIL_LIST+=("${label}")
  fi
done
done
done

blue ""
blue "============================================================"
blue "=== summary"
blue "============================================================"
for m in "${PASS_LIST[@]}"; do green "  PASS: $m"; done
for m in "${FAIL_LIST[@]}"; do red   "  FAIL: $m"; done

if [ ${#FAIL_LIST[@]} -eq 0 ]; then
  echo
  green "All ${#PASS_LIST[@]} ACEN modes match expected pivot."
  exit 0
else
  echo
  red "${#FAIL_LIST[@]} of $((${#PASS_LIST[@]} + ${#FAIL_LIST[@]})) ACEN modes failed."
  exit 1
fi
