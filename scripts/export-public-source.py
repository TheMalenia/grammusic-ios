#!/usr/bin/env python3
"""Export current source without Git history, private config, or internal documents."""
from pathlib import Path
import argparse
import shutil
import subprocess

PUBLIC_ROOT = {'README.md', 'LICENSE', 'project.yml', '.gitignore', 'PRIVACY_POLICY.md', 'CONTEXT.md'}
PUBLIC_DOCS = {'music-search.md', 'privacy-policy.md', 'release-notes-1.1.0.md',
               'testflight-notes.md', 'source-available.md'}
PUBLIC_CONFIG = {'Secrets.example.xcconfig', 'README.md'}
SOURCE_DIRS = {'GramMusic', 'GramMusicWidgets', 'GramMusicTests', 'GramMusicUITests'}


def permitted(path: Path) -> bool:
    if path.name == 'GoogleService-Info.plist' or 'ReviewerSession.bundle' in path.parts:
        return False
    if path.name.startswith('.env') or path.suffix.lower() in {'.p12', '.p8', '.pem', '.key', '.mobileprovision', '.sqlite', '.binlog'}:
        return False
    if len(path.parts) == 1:
        return path.name in PUBLIC_ROOT
    root = path.parts[0]
    if root == 'Config':
        return len(path.parts) == 2 and path.name in PUBLIC_CONFIG
    if root == 'docs':
        return len(path.parts) == 2 and path.name in PUBLIC_DOCS
    if root == 'scripts':
        return path.name == 'export-public-source.py'
    return root in SOURCE_DIRS and not any(part in {'xcuserdata', 'DerivedData', '.build'} for part in path.parts)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', nargs='?', default='public-source')
    args = parser.parse_args()
    repo = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
    destination = Path(args.destination).resolve()
    if destination.exists():
        parser.error('destination already exists; choose a new empty path')
    files = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'])
    destination.mkdir(parents=True)
    count = 0
    for name in sorted(set(files.decode().split('\0')) - {''}):
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or not permitted(path):
            continue
        source = repo / path
        if not source.is_file() or source.is_symlink() or not source.resolve().is_relative_to(repo):
            continue
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        count += 1
    print(f'Exported {count} files to {destination}; no Git history or generated Xcode project.')


if __name__ == '__main__':
    main()
