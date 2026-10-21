#!/usr/bin/env python3
"""Package only explicit public sources and the built native helper."""
import hashlib
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '4.2.0'
ALLOWED = ('README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md',
           '.gitignore', 'build.sh', 'native', 'lua', 'scripts', 'tests', 'docs', 'build/ShotKit.app')


def main():
    if not (ROOT / 'build/ShotKit.app/Contents/MacOS/ShotKit').is_file():
        raise SystemExit('Build zsh build.sh before packaging.')
    destination = ROOT / 'dist'
    destination.mkdir(exist_ok=True)
    archive = destination / f'shotkit-macos-v{VERSION}-arm64.zip'
    prefix = f'shotkit-macos-v{VERSION}'
    files = []
    for entry in ALLOWED:
        path = ROOT / entry
        candidates = sorted(path.rglob('*')) if path.is_dir() else [path]
        files.extend(p for p in candidates if p.is_file() and '__pycache__' not in p.parts and p.suffix != '.pyc' and p.name != '.DS_Store')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as zipped:
        for path in files:
            zipped.write(path, f'{prefix}/{path.relative_to(ROOT).as_posix()}')
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (destination / 'SHA256SUMS.txt').write_text(f'{checksum}  {archive.name}\n')
    print(f'{archive.name}: {len(files)} files, {archive.stat().st_size} bytes')
    print(f'SHA256 {checksum}')


if __name__ == '__main__':
    main()
