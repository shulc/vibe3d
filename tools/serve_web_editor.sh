#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
port=${1:-8788}
"$repo_root/tools/stage_web_editor.sh"
printf 'Open http://127.0.0.1:%s/\n' "$port"
exec python3 -m http.server "$port" --bind 127.0.0.1 --directory "$repo_root/.build/web-editor"
