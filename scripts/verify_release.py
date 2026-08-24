#!/usr/bin/env python3
import argparse, hashlib, json, re, zipfile
from pathlib import Path

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--package', required=True)
    ap.add_argument('--manifest', required=True)
    ap.add_argument('--plugin-dir', required=True)
    ap.add_argument('--version', required=True)
    args = ap.parse_args()

    package = Path(args.package)
    manifest = json.loads(Path(args.manifest).read_text(encoding='utf-8'))
    assert manifest['schema'] == 1
    assert manifest['plugin'] == args.plugin_dir
    assert manifest['version'] == args.version
    assert manifest['package_type'] == 'full'
    assert manifest['size'] == package.stat().st_size
    assert manifest['sha256'].lower() == sha256(package).lower()

    prefix = args.plugin_dir.rstrip('/') + '/'
    with zipfile.ZipFile(package, 'r') as zf:
        names = zf.namelist()
        assert names, 'empty package'
        for name in names:
            assert name.startswith(prefix), f'path outside plugin dir: {name}'
            tail = name[len(prefix):]
            assert tail and not tail.startswith('/')
            parts = Path(tail).parts
            assert '..' not in parts, f'unsafe path: {name}'
        meta_name = prefix + '_meta.lua'
        assert meta_name in names, '_meta.lua missing from package'
        meta = zf.read(meta_name).decode('utf-8')
        m = re.search(r'\bversion\s*=\s*["\']([^"\']+)["\']', meta)
        assert m and m.group(1) == args.version, 'package _meta.lua version mismatch'
    print('release verification passed')

if __name__ == '__main__':
    main()
