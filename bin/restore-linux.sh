#!/usr/bin/env bash
# restore-linux.sh - undo apply-linux.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

DRY_RUN=0
KEEP_STATE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --keep-state) KEEP_STATE=1 ;;
    -h|--help)
      echo "Usage: restore-linux.sh [--dry-run] [--keep-state]"
      exit 0
      ;;
    *) fc_die "unknown arg: $arg" ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || fc_die "This script is for Linux."
fc_require_cmds python3
fc_log_init "restore-linux $*"

[[ -f "$FC_STATE_FILE" ]] || fc_die "no state at $FC_STATE_FILE"

echo ""
echo "fuck-claude restore (Linux)  v${FC_VERSION}"
echo "state: ${FC_STATE_FILE}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  python3 - <<'PY'
import json, pathlib
s = json.loads(pathlib.Path.home().joinpath(".fuck-claude/state.json").read_text())
print("[dry-run] timezone ->", s["system"].get("timezone"))
print("[dry-run] lang ->", s["system"].get("lang"))
print("[dry-run] browsers from", s.get("backup_dir"))
PY
  exit 0
fi

# Load state fields
eval "$(python3 - <<'PY'
import json, pathlib, shlex
s = json.loads(pathlib.Path.home().joinpath(".fuck-claude/state.json").read_text())
sys_ = s["system"]
print("RESTORE_TZ=%s" % shlex.quote(sys_.get("timezone") or "UTC"))
print("RESTORE_LANG=%s" % shlex.quote(sys_.get("lang") or ""))
print("RESTORE_BACKUP=%s" % shlex.quote(s.get("backup_dir") or ""))
print("RESTORE_ENV=%s" % shlex.quote(s.get("user_env_file") or ""))
pathlib.Path("/tmp/fuck-claude-linux-state.json").write_text(json.dumps(s), encoding="utf-8")
PY
)"

# Timezone
fc_info "restoring timezone to ${RESTORE_TZ}..."
if command -v timedatectl >/dev/null 2>&1 && [[ -n "$RESTORE_TZ" && "$RESTORE_TZ" != "unknown" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    timedatectl set-timezone "$RESTORE_TZ" || true
  else
    sudo timedatectl set-timezone "$RESTORE_TZ" || true
  fi
  fc_ok "timezone -> $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
else
  fc_warn "could not restore timezone automatically"
fi

# User env file
if [[ -n "$RESTORE_ENV" && -f "$RESTORE_ENV" ]]; then
  fc_info "removing fuck-claude user env ${RESTORE_ENV}"
  rm -f "$RESTORE_ENV"
fi
# Note: shell rc source lines left as harmless no-ops if file missing

# Browsers
fc_info "restoring browser Preferences..."
for b in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser; do
  pkill -x "$b" 2>/dev/null || true
done
sleep 1
if [[ -n "$RESTORE_BACKUP" ]]; then
  python3 "${ROOT}/lib/browsers.py" restore "$RESTORE_BACKUP"
  fc_ok "browsers restored"
else
  fc_warn "no backup_dir in state"
fi

if [[ $KEEP_STATE -eq 0 ]]; then
  ARCH="${FC_STATE_DIR}/restored-$(date -u +%Y%m%dT%H%M%SZ).json"
  cp "$FC_STATE_FILE" "$ARCH"
  rm -f "$FC_STATE_FILE"
  fc_ok "archived state -> $ARCH"
fi

rm -f /tmp/fuck-claude-linux-state.json

echo ""
echo "=================================================="
echo " restore (Linux) complete"
echo "=================================================="
echo " timezone : $(timedatectl show -p Timezone --value 2>/dev/null || echo '?')"
echo "Reopen browsers / new shell for locale."
echo ""
