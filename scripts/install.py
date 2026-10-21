#!/usr/bin/env python3
"""Install or restore only ShotKit's files; never collect screenshot data."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
MODULES = ("screenshot.lua", "screenshot_snap.lua", "screenshot_overlay.lua", "screenshot_native.lua")
FILES = (*MODULES, "ShotKit.app")
STATE = "shotkit-install.json"
BLOCK = '\n-- BEGIN SHOTKIT\nrequire("screenshot").start()\n-- END SHOTKIT\n'


def digest(path):
    path = Path(path)
    if not path.exists():
        return None
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    h = hashlib.sha256()
    for child in sorted(path.rglob("*")):
        if child.is_file():
            h.update(child.relative_to(path).as_posix().encode())
            h.update(child.read_bytes())
    return h.hexdigest()


def verify_app(app):
    if not (app / "Contents/MacOS/ShotKit").is_file():
        raise RuntimeError("Missing native helper. Build with zsh build.sh or use the complete release archive.")
    if sys.platform != "darwin":
        raise RuntimeError("ShotKit runs on macOS.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def copy_item(source, target):
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        shutil.copy2(source, target)


def replace_item(source, target):
    staged = target.with_name("." + target.name + ".shotkit-" + uuid.uuid4().hex)
    copy_item(source, staged)
    if target.is_dir():
        shutil.rmtree(target)
    os.replace(staged, target)


def write_atomic(path, text):
    staged = path.with_name("." + path.name + ".shotkit-" + uuid.uuid4().hex)
    staged.write_text(text, encoding="utf-8")
    os.replace(staged, path)


def preflight(config, names):
    for name in names:
        path = config / name
        if path.is_symlink():
            raise RuntimeError(f"Refusing to replace symlink: {path}. Use --no-init for a linked init.lua, or install manually.")


def init_content(original):
    if "-- BEGIN SHOTKIT" in original:
        pattern = r"\n?-- BEGIN SHOTKIT\n.*?-- END SHOTKIT\n?"
        return re.sub(pattern, BLOCK, original, count=1, flags=re.S)
    if re.search(r'require\s*\(\s*[\"\']screenshot[\"\']\s*\)\s*\.\s*start\s*\(', original):
        return original
    return original.rstrip("\n") + BLOCK


def install(config, app, dry_run=False, no_init=False):
    config, app = Path(config).expanduser().resolve(), Path(app).expanduser().resolve()
    verify_app(app)
    for name in MODULES:
        if not (ROOT / "lua" / name).is_file():
            raise RuntimeError(f"Missing source: {name}")
    names = list(FILES) + ([] if no_init else ["init.lua"])
    preflight(config, names + [STATE, ".shotkit-backups"])
    if dry_run:
        return {"dry_run": True, "config": str(config), "files": names}
    config.mkdir(parents=True, exist_ok=True)
    backup = config / ".shotkit-backups" / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    backup.mkdir(parents=True, mode=0o700)
    present = []
    for name in names:
        if (config / name).exists():
            copy_item(config / name, backup / name)
            present.append(name)
    if (config / STATE).exists():
        shutil.copy2(config / STATE, backup / STATE)
    changed = []
    try:
        for name in FILES:
            changed.append(name)
            replace_item(app if name == "ShotKit.app" else ROOT / "lua" / name, config / name)
        if not no_init:
            init = config / "init.lua"
            original = init.read_text(encoding="utf-8") if init.exists() else ""
            changed.append("init.lua")
            write_atomic(init, init_content(original))
        data = config / "screenshot-data"
        data.mkdir(mode=0o700, exist_ok=True)
        state = {"version": "4.2", "backup": str(backup), "files": names, "original_files": present,
                 "installed": {name: digest(config / name) for name in names}}
        write_atomic(config / STATE, json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    except Exception:
        for name in reversed(changed):
            target = config / name
            if name in present:
                replace_item(backup / name, target)
            elif target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
        raise
    return {"installed": True, "backup": str(backup), "config": str(config)}


def uninstall(config, dry_run=False):
    config = Path(config).expanduser().resolve()
    state = json.loads((config / STATE).read_text(encoding="utf-8"))
    backup = Path(state["backup"]).resolve()
    if backup.parent != (config / ".shotkit-backups").resolve() or not backup.is_dir():
        raise RuntimeError("Invalid or missing backup; no files were changed.")
    names = state["files"]
    if set(names) - set((*FILES, "init.lua")):
        raise RuntimeError("Invalid installation manifest.")
    preflight(config, names + [STATE])
    for name in FILES:
        if digest(config / name) != state["installed"].get(name):
            raise RuntimeError(f"{name} changed after installation. Preserve your edits before restoring; no files were changed.")
    for name in state["original_files"]:
        if name not in names or not (backup / name).exists():
            raise RuntimeError("An original backup file is missing; no files were changed.")
    if dry_run:
        return {"dry_run": True, "restore": str(backup), "history_retained": True}
    for name in names:
        target = config / name
        if name == "init.lua" and digest(target) != state["installed"].get(name):
            if target.exists():
                current = target.read_text(encoding="utf-8")
                write_atomic(target, current.replace(BLOCK, "\n"))
            continue
        if name in state["original_files"]:
            replace_item(backup / name, target)
        elif target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
    previous = backup / STATE
    if previous.exists():
        replace_item(previous, config / STATE)
    else:
        (config / STATE).unlink()
    return {"restored": True, "history_retained": True, "backup_retained": str(backup)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path.home() / ".hammerspoon")
    parser.add_argument("--app", type=Path, default=ROOT / "build/ShotKit.app")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-init", action="store_true", help="Do not modify init.lua; add require(\"screenshot\").start() yourself")
    parser.add_argument("--uninstall", action="store_true", help="Restore the previous installation; keep screenshot history")
    args = parser.parse_args()
    try:
        result = uninstall(args.config, args.dry_run) if args.uninstall else install(args.config, args.app, args.dry_run, args.no_init)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"ShotKit: {error}\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print("Quit any active capture/editor first, then choose Hammerspoon → Reload Config. No automatic reload was performed.")


if __name__ == "__main__":
    main()
