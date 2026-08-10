#!/usr/bin/env bash
# apply.sh - OS router for fuck-claude apply (macOS / Linux / WSL)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
OS="$(uname -s 2>/dev/null || echo unknown)"

case "$OS" in
  Darwin)
    exec "$ROOT/bin/apply-macos.sh" "$@"
    ;;
  Linux)
    if fc_is_wsl; then
      exec "$ROOT/bin/apply-wsl.sh" "$@"
    fi
    exec "$ROOT/bin/apply-linux.sh" "$@"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "On native Windows use: powershell -ExecutionPolicy Bypass -File bin/apply.ps1 $*" >&2
    echo "Inside WSL use:        ./bin/apply.sh   (or ./bin/apply-wsl.sh)" >&2
    exit 2
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    echo "  macOS   : ./bin/apply.sh" >&2
    echo "  Linux   : ./bin/apply.sh" >&2
    echo "  WSL     : ./bin/apply.sh  (or ./bin/apply-wsl.sh)" >&2
    echo "  Windows : .\\bin\\apply.ps1" >&2
    exit 2
    ;;
esac
