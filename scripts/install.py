#!/usr/bin/env python3
"""Install the independent ShotKit app, optionally disabling only the old screenshot module."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
STATE_NAME = 'shotkit-native-install.json'
MARKER = '-- ShotKit screenshots now run in the independent ShotKit.app (Hammerspoon is not required).'
START = re.compile(r'^([ \t]*)require[ \t]*\([ \t]*["\']screenshot["\'][ \t]*\)[ \t]*\.[ \t]*start[ \t]*\([ \t]*\)[ \t]*;?[ \t]*(?:--[^\n]*)?$', re.M)


def digest(path):
    path = Path(path)
    if not path.exists():
        return None
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    h = hashlib.sha256()
    for p in sorted(path.rglob('*')):
        if p.is_file():
            h.update(p.relative_to(path).as_posix().encode())
            h.update(p.read_bytes())
    return h.hexdigest()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name('.' + path.name + '-' + uuid.uuid4().hex)
    try:
        temporary.write_bytes(data)
        temporary.chmod(0o600)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def migrated_init(original):
    """Recognize only a complete standalone startup statement; never rewrite unrelated Lua."""
    changed, count = START.subn(lambda m: m[1] + MARKER, original)
    if not count and 'screenshot' in original and re.search(r'(?m)^\s*[^-\n].*screenshot.*start', original):
        raise RuntimeError('Unrecognized screenshot startup statement. Disable only that module manually; init.lua was not changed.')
    return changed, count


def verify_app(app):
    if sys.platform != 'darwin':
        raise RuntimeError('ShotKit runs on macOS.')
    if not (app / 'Contents/MacOS/ShotKit').is_file():
        raise RuntimeError('Missing ShotKit.app. Run zsh build.sh or use a complete release archive.')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def ensure_regular(path):
    if path.is_symlink():
        raise RuntimeError(f'Refusing to replace symlink: {path}')


def ensure_not_running(target):
    executable = str(target / 'Contents/MacOS/ShotKit')
    result = subprocess.run(['/usr/bin/pgrep', '-f', '^' + re.escape(executable) + r'( |$)'],
                            capture_output=True, timeout=5)
    if result.returncode == 0:
        raise RuntimeError('Quit the installed ShotKit app before replacing or restoring it; no files were changed.')


def stop_legacy(cli=None):
    cli = cli or Path('/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs')
    if not cli.is_file():
        return False
    # Hammerspoon IPC, scoped to this project's module. Never reload or stop other scripts.
    try:
        result = subprocess.run([str(cli), '-c', 'local s=package.loaded["screenshot"]; if s and s.status then local x=s.status(); if x.selecting or x.capturing or x.longScreenshot then return "shotkit-busy" end end; if s and s.stop then s.stop() end; return "shotkit-stopped"'],
                                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and 'shotkit-stopped' in result.stdout


def install(app, target, config, migrate=False, dry_run=False):
    app, target, config = Path(app).expanduser().absolute(), Path(target).expanduser().absolute(), Path(config).expanduser().absolute()
    verify_app(app)
    ensure_not_running(target)
    for p in (target, target.parent / '.shotkit-native-backups', target.parent / STATE_NAME):
        ensure_regular(p)
    init = config / 'init.lua'
    if migrate:
        ensure_regular(init)
    original = init.read_bytes() if migrate and init.exists() else None
    modified, count = migrated_init(original.decode('utf-8')) if original is not None else ('', 0)
    if migrate:
        ensure_regular(init)
    result = {'app': str(target), 'standalone': True, 'legacy_startup_statements': count,
              'history_retained': True, 'other_hammerspoon_scripts_unchanged': True}
    if dry_run:
        return dict(result, dry_run=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = target.parent / '.shotkit-native-backups' / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    backup.mkdir(parents=True, mode=0o700)
    old_app = target.exists()
    if old_app:
        shutil.copytree(target, backup / 'ShotKit.app')
    manifest_path = target.parent / STATE_NAME
    if manifest_path.exists():
        shutil.copy2(manifest_path, backup / STATE_NAME)
    if original is not None:
        write_atomic(backup / 'init.lua', original)
    staged = target.with_name('.ShotKit-' + uuid.uuid4().hex + '.app')
    try:
        shutil.copytree(app, staged)
        verify_app(staged)
        if target.exists():
            shutil.rmtree(target)
        staged.replace(target)
        if original is not None and count:
            write_atomic(init, modified.encode('utf-8'))
        stopped = stop_legacy() if migrate and count else False
        # If IPC is unavailable, never claim the old global hotkeys have been released.
        result['legacy_runtime_stopped'] = stopped
        state = dict(result, version='5.0.4', backup=str(backup), had_app=old_app,
                     init_path=str(init), init_changed=bool(original is not None and count),
                     installed_app=digest(target), installed_init=digest(init) if original is not None and count else None)
        write_atomic(manifest_path, (json.dumps(state, ensure_ascii=False, indent=2) + '\n').encode())
        return dict(result, backup=str(backup), installed=True)
    except Exception:
        if target.exists():
            shutil.rmtree(target)
        if old_app:
            shutil.copytree(backup / 'ShotKit.app', target)
        if original is not None:
            write_atomic(init, original)
        raise
    finally:
        if staged.exists():
            shutil.rmtree(staged)


def restore(target, dry_run=False):
    target = Path(target).expanduser().absolute()
    state_file = target.parent / STATE_NAME
    ensure_regular(target)
    ensure_not_running(target)
    state = json.loads(state_file.read_text())
    backup = Path(state['backup'])
    if backup.parent != target.parent / '.shotkit-native-backups' or not backup.is_dir():
        raise RuntimeError('Invalid backup directory; no files changed.')
    if digest(target) != state['installed_app']:
        raise RuntimeError('The installed app changed. Preserve the newer version before restoring.')
    init = Path(state['init_path'])
    if state['init_changed']:
        ensure_regular(init)
        if digest(init) != state['installed_init']:
            raise RuntimeError('init.lua changed after migration. Restore only the screenshot startup line from the backup manually; no files changed.')
    if dry_run:
        return {'dry_run': True, 'backup': str(backup), 'history_retained': True}
    if target.exists():
        shutil.rmtree(target)
    if state['had_app']:
        shutil.copytree(backup / 'ShotKit.app', target)
    if state['init_changed']:
        write_atomic(init, (backup / 'init.lua').read_bytes())
    previous = backup / STATE_NAME
    if previous.exists():
        write_atomic(state_file, previous.read_bytes())
    else:
        state_file.unlink()
    return {'restored': True, 'history_retained': True, 'backup_retained': str(backup)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    bundled = ROOT / 'ShotKit.app'
    parser.add_argument('--app', type=Path, default=bundled if bundled.exists() else ROOT / 'build/ShotKit.app')
    parser.add_argument('--target', type=Path, default=Path.home() / 'Applications/ShotKit.app')
    parser.add_argument('--config', type=Path, default=Path.home() / '.hammerspoon')
    parser.add_argument('--migrate-hammerspoon', action='store_true', help='Back up init.lua, disable only require("screenshot").start(), stop only that module through IPC')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--restore', action='store_true')
    args = parser.parse_args()
    try:
        result = restore(args.target, args.dry_run) if args.restore else install(args.app, args.target, args.config, args.migrate_hammerspoon, args.dry_run)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'ShotKit: {error}\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if args.dry_run:
        print('Dry run: no files or running modules were changed.')
    elif args.restore:
        print('Quit native ShotKit before restoring. If reverting to Hammerspoon, reload its configuration yourself when ready.')
    elif result.get('legacy_startup_statements') and not result.get('legacy_runtime_stopped'):
        print('The old module could not be stopped through IPC. Quit any active screenshot, then reload Hammerspoon yourself to release its hotkeys.')
    else:
        print('Open the installed ShotKit.app. Allow Screen Recording in its setup window. Accessibility is optional for content detection.')


if __name__ == '__main__':
    main()
