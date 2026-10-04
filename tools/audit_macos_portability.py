"""Audit the expanded deliverable without installing, audio or cloud calls.

Dependency closure and a clean Rime data directory do NOT substitute for another
Mac, older macOS, fresh TCC grants, or Apple distribution signing acceptance.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MAGICS = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe',
          b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
          b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}

def run(argv):
    p = subprocess.run([str(v) for v in argv], capture_output=True, text=True, timeout=60)
    return {'argv': [str(v) for v in argv], 'exit_code': p.returncode,
            'output': p.stdout + p.stderr, 'stdout': p.stdout, 'stderr': p.stderr}

def required(argv):
    p = run(argv)
    if p['exit_code']: raise RuntimeError(p['output'])
    return p['stdout']

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def rpaths(image):
    load = required(['/usr/bin/otool', '-l', image])
    return re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset \d+\)', load)

def expand(value, image, executable):
    return value.replace('@loader_path', str(image.parent)).replace('@executable_path', str(executable.parent))

def main():
    installer = json.loads((ROOT/'evidence/macos-installer.json').read_text())
    package = Path(installer['package'])
    assert installer['status']=='PASS' and sha(package)==installer['sha256']
    expanded = Path(installer['extracted'])
    app = next(p for p in expanded.rglob('SquirrelEnhancedDev.app') if p.is_dir())
    executable = app/'Contents/MacOS/SquirrelEnhancedDev'
    main_rpaths = rpaths(executable)
    images = []; seen = set(); missing = []; external = []
    for image in sorted(app.rglob('*')):
        if not image.is_file() or image.resolve() in seen: continue
        with image.open('rb') as stream: magic = stream.read(4)
        if magic not in MAGICS: continue
        seen.add(image.resolve())
        arches = required(['/usr/bin/lipo', '-archs', image]).strip().split()
        load = required(['/usr/bin/otool', '-l', image])
        minimums = sorted(set(re.findall(r'^\s+minos ([\d.]+)$',load,re.M) +
                              re.findall(r'^\s+version ([\d.]+)$',load,re.M)))
        paths = [expand(p,image,executable) for p in rpaths(image)+main_rpaths]
        dependencies = []
        own_ids = {line.strip() for line in required(['/usr/bin/otool','-D',image]).splitlines()
                   if line.strip() and not line.rstrip().endswith(':')}
        names = list(dict.fromkeys(re.findall(r'^\s+(.+?) \(compatibility version',
                                              required(['/usr/bin/otool','-L',image]),re.M)))
        for name in names:
            item = {'dependency': name}
            if name in own_ids:
                item['resolution']='LC_ID_DYLIB (this image identity, not a dependency)'
            elif name.startswith(('/usr/lib/','/System/Library/')):
                item['resolution']='macOS system framework/runtime'
            elif name.startswith('/'):
                external.append({'image':str(image.relative_to(app)),'dependency':name})
                item['resolution']='UNBUNDLED ABSOLUTE DEPENDENCY'
            else:
                options = [Path(p)/name[len('@rpath/'):] for p in paths] if name.startswith('@rpath/') else [Path(expand(name,image,executable))]
                resolved = next((p.resolve() for p in options if p.is_file() and p.resolve().is_relative_to(app.resolve())),None)
                if resolved: item['resolution']=str(resolved.relative_to(app.resolve()))
                else:
                    item['resolution']='MISSING'
                    missing.append({'image':str(image.relative_to(app)),'dependency':name})
            dependencies.append(item)
        images.append({'image':str(image.relative_to(app)),'architectures':arches,
                       'minos':minimums,'dependencies':dependencies})
    checks = [run(['/usr/bin/codesign','--verify','--deep','--strict',app]),
              run(['/usr/sbin/pkgutil','--check-signature',package]),
              run(['/usr/sbin/spctl','--assess','--type','install','--verbose=4',package]),
              run(['/usr/sbin/spctl','--assess','--type','execute','--verbose=4',app])]
    main_info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    helper_info = plistlib.loads((app/'Contents/Resources/SquirrelVoiceHelper.app/Contents/Info.plist').read_bytes())
    all_arm = bool(images) and all('arm64' in i['architectures'] for i in images)
    dependency_pass = all_arm and not missing and not external and checks[0]['exit_code']==0
    report = {'utc':datetime.now(timezone.utc).isoformat(),
       'status':('PASS' if dependency_pass else 'FAIL')+' dependency closure; release Gatekeeper acceptance '+('PASS' if checks[2]['exit_code']==checks[3]['exit_code']==0 else 'BLOCKED'),
       'package':str(package),'package_sha256':sha(package),'package_app':str(app),
       'app_version':main_info['CFBundleShortVersionString'],'macho_images':images,
       'source_sha256':{str(Path(__file__).relative_to(ROOT)):sha(Path(__file__))},
       'unbundled_non_system_dependencies':external,'missing_dependencies':missing,
       'all_images_support_arm64':all_arm,'dependency_closure_passed':dependency_pass,
       'commands':checks,'clean_default_rime_probe':installer['clean_default_rime_probe'],
       'main_microphone_description':bool(main_info.get('NSMicrophoneUsageDescription')),
       'helper_microphone_description':bool(helper_info.get('NSMicrophoneUsageDescription')),
       'new_computer_tested':False,'older_macos_tested':False,
       'gatekeeper_install_accepted':checks[2]['exit_code']==0,
       'gatekeeper_execute_accepted':checks[3]['exit_code']==0,
       'developer_id_identity_available':False,'microphone_used':False,'cloud_calls':0,
       'scope':'Freshly expanded package and empty Rime user data on this computer; no new OS user or second Mac, registration, TCC, microphone or cloud acceptance.'}
    (ROOT/'evidence/macos-fresh-computer-package-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['status','app_version','all_images_support_arm64','dependency_closure_passed','gatekeeper_install_accepted','gatekeeper_execute_accepted','new_computer_tested']},ensure_ascii=False))
    return int(not dependency_pass)

if __name__=='__main__':raise SystemExit(main())
