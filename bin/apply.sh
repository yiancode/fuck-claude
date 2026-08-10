#!/usr/bin/env bash
# apply.sh - OS router for fuck-claude apply
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS="$(uname -s 2>/dev/null || echo unknown)"

case "$OS" in
  Darwin)
    exec "$ROOT/bin/apply-macos.sh" "$@"
    ;;
  Linux)
    exec "$ROOT/bin/apply-linux.sh" "$@"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "On Windows use: powershell -ExecutionPolicy Bypass -File bin/apply.ps1 $*" >&2
    exit 2
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    echo "  macOS : ./bin/apply.sh  (or apply-macos.sh)" >&2
    echo "  Linux : ./bin/apply.sh  (or apply-linux.sh)" >&2
    echo "  Windows: .\\bin\\apply.ps1" >&2
    exit 2
    ;;
esac
