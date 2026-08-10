#!/usr/bin/env bash
# Shared helpers for fuck-claude apply/restore (macOS only).
set -euo pipefail

FC_VERSION="1.0.0"
FC_NAME="fuck-claude"
FC_STATE_DIR="${FUCK_CLAUDE_STATE_DIR:-$HOME/.fuck-claude}"
FC_STATE_FILE="${FC_STATE_DIR}/state.json"
FC_BACKUP_DIR="${FC_STATE_DIR}/backups"
FC_LOG_FILE="${FC_STATE_DIR}/last-run.log"

# Target environment that tends to pass https://fuck-claude.app/
# (timezone is the only signal documented as matching Claude Code 1:1)
FC_TARGET_TIMEZONE="${FUCK_CLAUDE_TIMEZONE:-America/Los_Angeles}"
FC_TARGET_LOCALE="${FUCK_CLAUDE_LOCALE:-en_US}"
# English only by default (zh-CN in Accept-Language is a high-weight signal)
FC_TARGET_LANGS="${FUCK_CLAUDE_LANGS:-en-US}"

fc_die() {
  echo "error: $*" >&2
  exit 1
}

fc_info() {
  echo "→ $*"
}

fc_ok() {
  echo "✓ $*"
}

fc_warn() {
  echo "warning: $*" >&2
}

fc_require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fc_die "This tool only supports macOS."
}

fc_require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fc_die "missing command: $c"
  done
}

fc_ensure_state_dir() {
  mkdir -p "$FC_STATE_DIR" "$FC_BACKUP_DIR"
}

fc_log_init() {
  fc_ensure_state_dir
  {
    echo "==== $(date -u +%Y-%m-%dT%H:%M:%SZ) $FC_NAME $FC_VERSION ===="
    echo "argv: $*"
  } >>"$FC_LOG_FILE"
}

fc_has_python() {
  command -v python3 >/dev/null 2>&1
}

# Admin shell via GUI password prompt (no plaintext password)
fc_admin() {
  local script="$1"
  if [[ ! -f "$script" ]]; then
    fc_die "admin script not found: $script"
  fi
  chmod +x "$script"
  osascript -e "do shell script \"/bin/bash $(printf %q "$script")\" with administrator privileges"
}

fc_current_timezone() {
  if command -v systemsetup >/dev/null 2>&1; then
    # may need admin; fall back to localtime link
    local out
    out="$(readlink /etc/localtime 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      # strip prefix .../zoneinfo/
      echo "${out#*/zoneinfo/}"
      return
    fi
  fi
  echo "unknown"
}

fc_current_offset() {
  date +%z
}

fc_json_escape() {
  # minimal escape for embedding in JSON strings
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"$1"
}

fc_read_defaults_array() {
  # prints space-separated values of a defaults array domain key, or empty
  local domain="$1" key="$2"
  defaults read "$domain" "$key" 2>/dev/null | tr -d '(),"' | xargs || true
}
