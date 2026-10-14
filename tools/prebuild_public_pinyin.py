"""Prebuild public tables in a new disposable directory, never user Rime data."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from bundle_public_pinyin import ROOT, RESOURCE, verify_bundle


def main(app):
    verify_bundle(app)
    # Keep diagnostics outside the signing stage: build-clt moves the app and
    # requires its temporary parent to become empty before recording completion.
    build = ROOT / 'enhanced-squirrel/build'
    build.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='public-prebuild-', dir=build))
    binary = work / 'NativeCleanRimeProbe'
    source = ROOT / 'tools/NativeCleanRimeProbe.cpp'
    subprocess.run(['/usr/bin/xcrun', 'clang++', '-std=c++17', '-O2', '-I',
                    str(ROOT / 'enhanced-squirrel/librime/src'), str(source), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(app / 'Contents/Frameworks/librime.1.dylib'),
                             str(app / 'Contents/SharedSupport'), str(work / 'empty-user')],
                            capture_output=True, text=True, timeout=180)
    (work / 'probe.stderr.txt').write_text(result.stderr)
    if result.returncode: raise RuntimeError('Public prebuild failed; inspect ' + str(work))
    report = json.loads(result.stdout)
    assert report['status'] == 'PASS' and report['empty_user_directory']
    files = {}
    destination = app / 'Contents/SharedSupport/build'
    destination.mkdir(exist_ok=True)
    for kind in ['table', 'prism', 'reverse']:
        name = 'squirrel_public_pinyin.' + kind + '.bin'
        src = work / 'empty-user/build' / name
        assert src.is_file() and not src.is_symlink()
        target = destination / name
        assert not target.is_symlink()
        shutil.copyfile(src, target)
        files['SharedSupport/build/' + name] = hashlib.sha256(target.read_bytes()).hexdigest()
    proof = {'version': 1, 'source_manifest_sha256': hashlib.sha256((ROOT / RESOURCE / 'UPSTREAM.json').read_bytes()).hexdigest(),
             'files_sha256': files, 'isolated_public_sources_only': True,
             'personal_data_read': False, 'microphone_used': False, 'cloud_calls': 0}
    (app / 'Contents/Resources/Licenses/PublicPinyin-PREBUILT.json').write_text(json.dumps(proof, indent=2) + '\n')
    verify_bundle(app, require_prebuilt=True)
    print('PASS: isolated public tables prebuilt; no user data included')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    main(parser.parse_args().app.resolve())
