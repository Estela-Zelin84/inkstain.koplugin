#!/usr/bin/env python3
import argparse, hashlib, json, os, re, sys, zipfile
from pathlib import Path

EXCLUDED_TOP = {'.git', '.github', 'scripts', 'dist', '__pycache__'}
EXCLUDED_NAMES = {'.DS_Store'}

def read_version(meta: Path) -> str:
    text = meta.read_text(encoding='utf-8')
    m = re.search(r'\bversion\s*=\s*["\']([^"\']+)["\']', text)
    if not m:
        raise SystemExit('_meta.lua does not contain a literal version = "x.y.z"')
    return m.group(1)

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def should_include(rel: Path) -> bool:
    if not rel.parts:
        return False
    if rel.parts[0] in EXCLUDED_TOP:
        return False
    if any(p in EXCLUDED_NAMES for p in rel.parts):
        return False
    if rel.suffix in {'.pyc', '.zip'}:
        return False
    return True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo-root', default='.')
    ap.add_argument('--plugin-dir', required=True)
    ap.add_argument('--package-prefix', required=True)
    ap.add_argument('--repo', required=True)
    ap.add_argument('--channel', default='stable')
    ap.add_argument('--output', default='dist')
    args = ap.parse_args()

    root = Path(args.repo_root).resolve()
    version = read_version(root / '_meta.lua')
    out = (root / args.output)
    out.mkdir(parents=True, exist_ok=True)
    package_name = f'{args.package_prefix}-v{version}.zip'
    package_path = out / package_name

    files = []
    for p in root.rglob('*'):
        if p.is_file():
            rel = p.relative_to(root)
            if should_include(rel):
                files.append((rel.as_posix(), p))
    files.sort(key=lambda x: x[0])

    with zipfile.ZipFile(package_path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel, src in files:
            zi = zipfile.ZipInfo(f'{args.plugin_dir}/{rel}')
            zi.date_time = (1980, 1, 1, 0, 0, 0)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o100644 << 16
            zf.writestr(zi, src.read_bytes())

    digest = sha256(package_path)
    size = package_path.stat().st_size
    tag = f'v{version}'
    package_url = f'https://github.com/{args.repo}/releases/download/{tag}/{package_name}'
    manifest = {
        'schema': 1,
        'plugin': args.plugin_dir,
        'version': version,
        'channel': args.channel,
        'package_type': 'full',
        'package_url': package_url,
        'size': size,
        'sha256': digest,
        'summary': f'InkStain {version}',
    }
    (out / 'update.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (out / 'package_name.txt').write_text(package_name + '\n', encoding='utf-8')
    print(f'version={version}')
    print(f'package={package_path}')
    print(f'size={size}')
    print(f'sha256={digest}')

if __name__ == '__main__':
    main()
