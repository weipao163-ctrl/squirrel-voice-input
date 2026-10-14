"""Verify pinned public dictionary sources and copy only their declared files."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = Path('enhanced-squirrel/resources/PublicPinyin')


def verify_sources(root=ROOT, read=None):
    read = read or (lambda path: path.read_bytes())
    source = root / RESOURCE
    manifest = json.loads(read(source / 'UPSTREAM.json'))
    assert manifest['version'] == 1 and manifest['local_or_personal_data_used'] is False
    expected = {'dictionaries/8105.dict.yaml', 'dictionaries/base.dict.yaml',
                'dictionaries/ext.dict.yaml', 'dictionaries/tencent.dict.yaml', 'dictionaries/others.dict.yaml',
                'luna_pinyin.schema.yaml', 'squirrel_public_pinyin.dict.yaml',
                'RimeIce-LICENSE', 'LunaPinyin-LICENSE', 'LunaPinyin-AUTHORS'}
    assert set(manifest['files_sha256']) == expected, 'Unexpected public resource set'
    for name, digest in manifest['files_sha256'].items():
        assert hashlib.sha256(read(source / name)).hexdigest() == digest, 'Public source hash mismatch: ' + name
    assert set(manifest['bundled_shared_support']) == expected - set(manifest['bundled_licenses'])
    assert set(manifest['bundled_licenses']) == {'RimeIce-LICENSE', 'LunaPinyin-LICENSE', 'LunaPinyin-AUTHORS'}
    expected_paths = {'luna_pinyin.schema.yaml', 'squirrel_public_pinyin.dict.yaml',
                      *('squirrel_public_pinyin/' + n + '.dict.yaml' for n in ['8105', 'base', 'ext', 'tencent', 'others'])}
    assert set(manifest['bundled_shared_support'].values()) == expected_paths
    assert set(manifest['bundled_licenses'].values()) == {
        'rime-ice-GPL-3.0.txt', 'rime-luna-pinyin-LGPL-3.0.txt', 'rime-luna-pinyin-AUTHORS.txt'}
    return manifest


def verify_bundle(app, root=ROOT, require_prebuilt=False):
    manifest = verify_sources(root)
    contents = app / 'Contents'
    for group, folder in [('bundled_shared_support', 'SharedSupport'), ('bundled_licenses', 'Resources/Licenses')]:
        for source, destination in manifest[group].items():
            path = contents / folder / destination
            assert path.is_file() and not path.is_symlink(), 'Missing public resource: ' + destination
            assert hashlib.sha256(path.read_bytes()).hexdigest() == manifest['files_sha256'][source]
    tables = contents / 'SharedSupport/squirrel_public_pinyin'
    assert {p.name for p in tables.iterdir()} == {'8105.dict.yaml', 'base.dict.yaml', 'ext.dict.yaml', 'tencent.dict.yaml', 'others.dict.yaml'}, 'Unexpected dictionary in public namespace'
    provenance = contents / 'Resources/Licenses/PublicPinyin-UPSTREAM.json'
    assert provenance.read_bytes() == (root / RESOURCE / 'UPSTREAM.json').read_bytes()
    if require_prebuilt:
        proof = json.loads((contents / 'Resources/Licenses/PublicPinyin-PREBUILT.json').read_text())
        assert proof['version'] == 1 and proof['isolated_public_sources_only'] is True and proof['personal_data_read'] is False
        assert proof['source_manifest_sha256'] == hashlib.sha256(provenance.read_bytes()).hexdigest()
        assert set(proof['files_sha256']) == {
            'SharedSupport/build/squirrel_public_pinyin.' + kind + '.bin' for kind in ['table', 'prism', 'reverse']}
        for name, digest in proof['files_sha256'].items():
            target = contents / name
            assert not target.is_symlink() and hashlib.sha256(target.read_bytes()).hexdigest() == digest
    return manifest


def bundle(app, root=ROOT):
    manifest = verify_sources(root)
    assert app.is_dir() and not app.is_symlink()
    for group, folder in [('bundled_shared_support', 'SharedSupport'), ('bundled_licenses', 'Resources/Licenses')]:
        for source, destination in manifest[group].items():
            path = app / 'Contents' / folder / destination
            path.parent.mkdir(parents=True, exist_ok=True)
            assert not path.is_symlink()
            shutil.copyfile(root / RESOURCE / source, path)
    shutil.copyfile(root / RESOURCE / 'UPSTREAM.json', app / 'Contents/Resources/Licenses/PublicPinyin-UPSTREAM.json')
    verify_bundle(app, root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    bundle(args.app.resolve())
    print('PASS: pinned public pinyin resources; no local dictionaries read')
