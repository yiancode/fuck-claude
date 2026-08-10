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


def is_wsl() -> bool:
    """True when running inside Windows Subsystem for Linux."""
    if os.environ.get("WSL_DISTRO_NAME") or os.environ.get("WSL_INTEROP"):
        return True
    try:
        ver = Path("/proc/version").read_text(encoding="utf-8", errors="ignore").lower()
        if "microsoft" in ver or "wsl" in ver:
            return True
    except Exception:
        pass
    try:
        # WSL2 often has this file
        if Path("/proc/sys/fs/binfmt_misc/WSLInterop").exists():
            return True
    except Exception:
        pass
    return False


def windows_localappdata_from_wsl() -> Optional[Path]:
    """Resolve the Windows %LOCALAPPDATA% path mounted in WSL (e.g. /mnt/c/Users/x/AppData/Local)."""
    # 1) Explicit override
    override = os.environ.get("FUCK_CLAUDE_WIN_LOCALAPPDATA")
    if override:
        p = Path(override)
        return p if p.is_dir() else None

    # 2) cmd.exe
    for cmd in (
        ["cmd.exe", "/c", "echo %LOCALAPPDATA%"],
        ["/mnt/c/Windows/System32/cmd.exe", "/c", "echo %LOCALAPPDATA%"],
    ):
        try:
            import subprocess

            out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=15)
            win_path = out.strip().splitlines()[-1].strip().strip('"')
            if not win_path or win_path.startswith("%"):
                continue
            # wslpath -u 'C:\Users\...'
            try:
                unix = subprocess.check_output(
                    ["wslpath", "-u", win_path], text=True, stderr=subprocess.DEVNULL, timeout=10
                ).strip()
                p = Path(unix)
                if p.is_dir():
                    return p
            except Exception:
                # manual map C:\Users\foo -> /mnt/c/Users/foo
                if len(win_path) >= 3 and win_path[1] == ":":
                    drive = win_path[0].lower()
                    rest = win_path[2:].replace("\\", "/").lstrip("/")
                    p = Path(f"/mnt/{drive}/{rest}")
                    if p.is_dir():
                        return p
        except Exception:
            continue

    # 3) Heuristic via USERNAME
    for cmd in (
        ["cmd.exe", "/c", "echo %USERNAME%"],
        ["/mnt/c/Windows/System32/cmd.exe", "/c", "echo %USERNAME%"],
    ):
        try:
            import subprocess

            user = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=10)
            user = user.strip().splitlines()[-1].strip()
            if user:
                p = Path(f"/mnt/c/Users/{user}/AppData/Local")
                if p.is_dir():
                    return p
        except Exception:
            continue
    return None


def browser_roots() -> Dict[str, Path]:
    """Return installed browser user-data roots for the current OS.

    On WSL, returns both Linux (~/.config) and Windows host browsers under /mnt/c/...
    Prefix Windows roots with win_ so backup names do not collide.
    """
    system = platform.system()
    h = home()
    roots: Dict[str, Path] = {}
    mode = os.environ.get("FUCK_CLAUDE_BROWSER_MODE", "").lower()  # linux|windows|both|auto

    def add(prefix: str, candidates: Dict[str, Path]) -> None:
        for name, path in candidates.items():
            key = f"{prefix}{name}" if prefix else name
            if path.is_dir():
                roots[key] = path

    darwin = {
        "chrome": h / "Library/Application Support/Google/Chrome",
        "edge": h / "Library/Application Support/Microsoft Edge",
        "brave": h / "Library/Application Support/BraveSoftware/Brave-Browser",
    }
    linux = {
        "chrome": h / ".config/google-chrome",
        "chromium": h / ".config/chromium",
        "edge": h / ".config/microsoft-edge",
        "brave": h / ".config/BraveSoftware/Brave-Browser",
    }

    if system == "Darwin":
        add("", darwin)
        return roots

    if system == "Windows":
        local = Path(os.environ.get("LOCALAPPDATA", str(h / "AppData/Local")))
        add(
            "",
            {
                "chrome": local / "Google/Chrome/User Data",
                "edge": local / "Microsoft/Edge/User Data",
                "brave": local / "BraveSoftware/Brave-Browser/User Data",
            },
        )
        return roots

    if system == "Linux":
        wsl = is_wsl()
        include_linux = mode in ("", "auto", "linux", "both") or not wsl
        include_windows = mode in ("windows", "both") or (wsl and mode in ("", "auto"))

        if include_linux or not wsl:
            add("", linux)

        if wsl and include_windows:
            local = windows_localappdata_from_wsl()
            if local:
                add(
                    "win_",
                    {
                        "chrome": local / "Google/Chrome/User Data",
                        "edge": local / "Microsoft/Edge/User Data",
                        "brave": local / "BraveSoftware/Brave-Browser/User Data",
                    },
                )
        return roots

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
        is_brave = name.lower().endswith("brave") or name.lower() == "brave"
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
        print("wsl\t%s" % is_wsl())
        win_local = windows_localappdata_from_wsl() if is_wsl() else None
        print("win_localappdata\t%s" % (win_local or ""))
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
