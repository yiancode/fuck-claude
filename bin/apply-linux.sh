#!/usr/bin/env bash
# apply-linux.sh - reshape Linux env for fuck-claude.app scans
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

DRY_RUN=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: apply-linux.sh [--dry-run] [--force]

Changes:
  1) timedatectl timezone -> America/Los_Angeles (or $FUCK_CLAUDE_TIMEZONE)
  2) Prefer en_US.UTF-8 locale (localectl / user env)
  3) Patch Chrome/Chromium/Edge/Brave Accept-Language + DNT (+ Brave GPC/FP)
  4) Optional ~/.curlrc GPC/DNT headers

Requires: python3, timedatectl (systemd). sudo for timezone/locale.
State: ~/.fuck-claude/state.json
EOF
      exit 0
      ;;
    *) fc_die "unknown arg: $arg" ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || fc_die "This script is for Linux (use apply.sh router)."
fc_require_cmds python3 date
fc_log_init "apply-linux $*"
fc_ensure_state_dir

if [[ -f "$FC_STATE_FILE" && $FORCE -eq 0 ]]; then
  fc_die "state exists at $FC_STATE_FILE — run restore first or use --force"
fi

echo ""
echo "fuck-claude apply (Linux)  v${FC_VERSION}"
echo "target timezone : ${FC_TARGET_TIMEZONE}"
echo "target locale   : ${FC_TARGET_LOCALE}.UTF-8"
echo "state file      : ${FC_STATE_FILE}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  fc_info "[dry-run] timedatectl set-timezone ${FC_TARGET_TIMEZONE}"
  fc_info "[dry-run] localectl / LANG -> en_US.UTF-8"
  fc_info "[dry-run] patch chromium browsers under ~/.config"
  exit 0
fi

# Snapshot
SNAPSHOT_TS="$(date -u +%Y%m%dT%H%M%SZ)"
TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime 2>/dev/null || echo unknown)"
LANG_NOW="${LANG:-}"
LC_ALL_NOW="${LC_ALL:-}"
LOCALE_CTL_NOW="$(localectl status 2>/dev/null | tr '\n' '|' || echo "")"

python3 - <<PY
import json, os, pathlib, subprocess
from datetime import datetime, timezone
import sys
sys.path.insert(0, "${ROOT}/lib")
import browsers

backup = pathlib.Path(os.path.expanduser("${FC_BACKUP_DIR}")) / "${SNAPSHOT_TS}"
manifest = browsers.backup_browsers(backup)

state = {
    "version": "${FC_VERSION}",
    "platform": "Linux",
    "created_at": datetime.now(timezone.utc).isoformat(),
    "snapshot_ts": "${SNAPSHOT_TS}",
    "system": {
        "timezone": """${TZ_NOW}""",
        "lang": """${LANG_NOW}""",
        "lc_all": """${LC_ALL_NOW}""",
        "localectl": """${LOCALE_CTL_NOW}""",
    },
    "targets": {
        "timezone": "${FC_TARGET_TIMEZONE}",
        "locale": "${FC_TARGET_LOCALE}.UTF-8",
        "languages": "${FC_TARGET_LANGS}",
    },
    "backup_dir": str(backup),
    "user_env_file": str(pathlib.Path.home() / ".config/fuck-claude/env.sh"),
}
pathlib.Path(os.path.expanduser("${FC_STATE_FILE}")).write_text(
    json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
)
print("wrote state; backed up", len(manifest["profiles"]), "browser profiles")
PY
fc_ok "snapshot saved"

# Timezone
fc_info "setting timezone to ${FC_TARGET_TIMEZONE} (may ask sudo)..."
if command -v timedatectl >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then
    timedatectl set-timezone "$FC_TARGET_TIMEZONE"
  else
    sudo timedatectl set-timezone "$FC_TARGET_TIMEZONE"
  fi
  fc_ok "timezone -> $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
else
  fc_warn "timedatectl not found — set timezone manually to ${FC_TARGET_TIMEZONE}"
fi

# Locale
TARGET_LANG="${FC_TARGET_LOCALE}.UTF-8"
fc_info "preferring locale ${TARGET_LANG}..."
if command -v localectl >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then
    localectl set-locale "LANG=${TARGET_LANG}" 2>/dev/null || true
  else
    sudo localectl set-locale "LANG=${TARGET_LANG}" 2>/dev/null || true
  fi
fi
# User-level env (always works without sudo)
mkdir -p "${HOME}/.config/fuck-claude"
cat >"${HOME}/.config/fuck-claude/env.sh" <<EOF
# managed by fuck-claude apply-linux
export LANG=${TARGET_LANG}
export LC_ALL=${TARGET_LANG}
export LANGUAGE=en_US:en
EOF
# Source from bashrc/zshrc once
for rc in "${HOME}/.bashrc" "${HOME}/.zshrc" "${HOME}/.profile"; do
  if [[ -f "$rc" ]] || [[ "$rc" == *"profile" ]]; then
    touch "$rc"
    if ! grep -q 'fuck-claude/env.sh' "$rc" 2>/dev/null; then
      {
        echo ""
        echo "# fuck-claude locale"
        echo '[ -f "$HOME/.config/fuck-claude/env.sh" ] && . "$HOME/.config/fuck-claude/env.sh"'
      } >>"$rc"
    fi
  fi
done
fc_ok "user locale env written"

# Browsers — try to quit
for b in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser; do
  pkill -x "$b" 2>/dev/null || true
done
sleep 1

fc_info "patching browser Preferences..."
python3 "${ROOT}/lib/browsers.py" patch "en-US,en"
fc_ok "browsers patched"

# curlrc
if [[ -f "${HOME}/.curlrc" ]]; then
  if ! grep -q "Sec-GPC" "${HOME}/.curlrc" 2>/dev/null; then
    {
      echo ""
      echo "# added by fuck-claude apply-linux"
      echo 'header = "Sec-GPC: 1"'
      echo 'header = "DNT: 1"'
      echo 'header = "Accept-Language: en-US,en;q=0.9"'
    } >>"${HOME}/.curlrc"
  fi
else
  cat >"${HOME}/.curlrc" <<'EOF'
# managed by fuck-claude apply-linux
header = "Sec-GPC: 1"
header = "DNT: 1"
header = "Accept-Language: en-US,en;q=0.9"
EOF
fi

echo ""
echo "=================================================="
echo " apply (Linux) complete"
echo "=================================================="
echo " timezone : $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
echo " offset   : $(date +%z)"
echo " state    : ${FC_STATE_FILE}"
echo ""
echo "Next: reopen browser, open https://fuck-claude.app/"
echo "      new shells load LANG from ~/.config/fuck-claude/env.sh"
echo "Restore: ./bin/restore.sh"
echo ""
