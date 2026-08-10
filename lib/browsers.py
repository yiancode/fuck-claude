#!/usr/bin/env python3
"""Cross-platform Chromium browser Preference backup / patch / restore for fuck-claude."""

from __future__ import annotations

import json
import os
import platform
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def home() -> Path:
    return Path.home()


def browser_roots() -> Dict[str, Path]:
    """Return installed browser user-data roots for the current OS."""
    system = platform.system()
    h = home()
    roots: Dict[str, Path] = {}

    if system == "Darwin":
        candidates = {
            "chrome": h / "Library/Application Support/Google/Chrome",
            "edge": h / "Library/Application Support/Microsoft Edge",
            "brave": h / "Library/Application Support/BraveSoftware/Brave-Browser",
        }
    elif system == "Linux":
        candidates = {
            "chrome": h / ".config/google-chrome",
            "chromium": h / ".config/chromium",
            "edge": h / ".config/microsoft-edge",
            "brave": h / ".config/BraveSoftware/Brave-Browser",
        }
    elif system == "Windows":
        local = Path(os.environ.get("LOCALAPPDATA", str(h / "AppData/Local")))
        candidates = {
            "chrome": local / "Google/Chrome/User Data",
            "edge": local / "Microsoft/Edge/User Data",
            "brave": local / "BraveSoftware/Brave-Browser/User Data",
        }
    else:
        candidates = {}

    for name, path in candidates.items():
        if path.is_dir():
            roots[name] = path
    return roots


def iter_preferences(root: Path) -> List[Path]:
    prefs: List[Path] = []
    # Profile dirs: Default, Profile 1, ...
    for pref in root.glob("*/Preferences"):
        s = str(pref)
        if "System Profile" in s or "Guest Profile" in s:
            continue
        prefs.append(pref)
    # Some layouts put Preferences directly under User Data/Default only — covered by */
    return prefs


def backup_browsers(backup_root: Path) -> Dict[str, Any]:
    backup_root.mkdir(parents=True, exist_ok=True)
    manifest: Dict[str, Any] = {
        "profiles": [],
        "created_at": datetime.now(timezone.utc).isoformat(),
        "platform": platform.system(),
    }
    for name, root in browser_roots().items():
        for pref in iter_preferences(root):
            rel = pref.relative_to(root)
            dest = backup_root / name / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(pref, dest)
            try:
                data = json.loads(pref.read_text(encoding="utf-8"))
            except Exception:
                data = {}
            intl = data.get("intl", {})
            manifest["profiles"].append(
                {
                    "browser": name,
                    "path": str(pref),
                    "backup": str(dest),
                    "accept_languages": intl.get("accept_languages"),
                    "selected_languages": intl.get("selected_languages"),
                    "enable_do_not_track": data.get("enable_do_not_track"),
                }
            )
    (backup_root / "browser-manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return manifest


def patch_browsers(
    accept_languages: str = "en-US,en",
    forced: Optional[List[str]] = None,
) -> int:
    if forced is None:
        forced = ["en-US", "en"]
    n = 0
    for name, root in browser_roots().items():
        is_brave = "brave" in name.lower()
        for pref in iter_preferences(root):
            try:
                data = json.loads(pref.read_text(encoding="utf-8"))
            except Exception as e:
                print("skip", pref, e, file=sys.stderr)
                continue
            intl = data.setdefault("intl", {})
            intl["accept_languages"] = accept_languages
            intl["selected_languages"] = accept_languages
            intl["forced_languages"] = forced
            data["enable_do_not_track"] = True
            sc = data.setdefault("spellcheck", {})
            sc["dictionaries"] = ["en-US"]
            sc["dictionary"] = "en-US"
            if is_brave:
                brave = data.setdefault("brave", {})
                brave["gpc_enabled"] = True
                brave["fingerprinting_block_mode"] = 2
                dcsv = data.setdefault("profile", {}).setdefault(
                    "default_content_setting_values", {}
                )
                dcsv["brave_fingerprinting"] = 2
                dcsv["brave_fingerprinting_v2"] = 2
            profile = data.setdefault("profile", {})
            if profile.get("exit_type") == "Crashed":
                profile["exit_type"] = "Normal"
            pref.write_text(
                json.dumps(data, ensure_ascii=False, separators=(",", ":")),
                encoding="utf-8",
            )
            n += 1
    return n


def restore_browsers(backup_dir: Path) -> int:
    manifest_path = backup_dir / "browser-manifest.json"
    if not manifest_path.is_file():
        print("no browser-manifest.json — skip", file=sys.stderr)
        return 0
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    n = 0
    for item in manifest.get("profiles", []):
        src = Path(item["backup"])
        dst = Path(item["path"])
        if not src.is_file():
            print("missing backup:", src, file=sys.stderr)
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        n += 1
    return n


def main(argv: List[str]) -> int:
    if len(argv) < 2:
        print(
            "usage: browsers.py backup <dir> | patch [langs] | restore <dir> | roots",
            file=sys.stderr,
        )
        return 2
    cmd = argv[1]
    if cmd == "roots":
        for k, v in browser_roots().items():
            print(f"{k}\t{v}")
        return 0
    if cmd == "backup":
        if len(argv) < 3:
            return 2
        m = backup_browsers(Path(argv[2]))
        print("backed up %d profiles" % len(m["profiles"]))
        return 0
    if cmd == "patch":
        langs = argv[2] if len(argv) > 2 else "en-US,en"
        n = patch_browsers(accept_languages=langs)
        print("patched %d profiles" % n)
        return 0
    if cmd == "restore":
        if len(argv) < 3:
            return 2
        n = restore_browsers(Path(argv[2]))
        print("restored %d profiles" % n)
        return 0
    print("unknown command", cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
