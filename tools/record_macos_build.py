"""Record the built app's real signatures and source/dependency hashes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
from macos_build_provenance import validate

ROOT=Path(__file__).resolve().parents[1]

def run(argv):
    value=subprocess.run(argv,capture_output=True,text=True,timeout=60)
    return {'argv':argv,'exit_code':value.returncode,'output':value.stdout+value.stderr,
            'stdout':value.stdout,'stderr':value.stderr}

def main():
    project=ROOT/'enhanced-squirrel'
    app=project/'build/CLT/SquirrelEnhancedDev.app'
    provenance=validate(app)
    helper=app/'Contents/Resources/SquirrelVoiceHelper.app'
    commands=[run(['codesign','--verify','--deep','--strict',str(app)]),
              run(['codesign','-d','--entitlements','-','--xml',str(helper)]),
              run(['file',str(app/'Contents/MacOS/SquirrelEnhancedDev')]),
              run(['swift','--version']),run(['sw_vers']),run(['security','find-identity','-v','-p','codesigning'])]
    main_entitlement_command=run(['codesign','-d','--entitlements','-','--xml',str(app)])
    commands.append(main_entitlement_command)
    sources=[*sorted((project/'sources').glob('*.swift')),*sorted((project/'Enhancements/Sources').rglob('*.swift')),
             project/'Enhancements/Package.swift',project/'Enhancements/Native/LetterProbe.cpp',
             project/'scripts/build-clt.sh',project/'scripts/local-signing.sh',project/'scripts/build-enhanced.sh',project/'scripts/helper.entitlements',project/'scripts/letter-probe.entitlements',
             project/'resources/Localizable.xcstrings',project/'resources/InfoPlist.xcstrings',project/'resources/Squirrel.entitlements',project/'resources/Info.plist',project/'resources/letter_selection.lua',project/'resources/EnhancedDefaultSquirrel.yaml']
    binary=[app/'Contents/MacOS/SquirrelEnhancedDev',app/'Contents/MacOS/SquirrelLetterProbe',
            helper/'Contents/MacOS/SquirrelVoiceHelper',app/'Contents/Frameworks/librime.1.dylib']
    # codesign writes the entitlement plist to stdout, diagnostics to stderr.
    def audio_entitlement(result):
        return result['exit_code']==0 and plistlib.loads(result['stdout'].encode()).get('com.apple.security.device.audio-input') is True
    microphone_entitlements=audio_entitlement(main_entitlement_command) and audio_entitlement(commands[1])
    main_plist=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    helper_plist=plistlib.loads((helper/'Contents/Info.plist').read_bytes())
    microphone_metadata=bool(main_plist.get('NSMicrophoneUsageDescription') and
       helper_plist.get('NSMicrophoneUsageDescription') and
       helper_plist.get('CFBundleIdentifier')=='org.rime.SquirrelEnhanced.Development.VoiceHelper')
    pin=main_plist.get('SquirrelEnhancementCertificateSHA1','')
    authenticated=False
    if pin:
        assert len(pin)==40 and all(c in '0123456789abcdefABCDEF' for c in pin)
        ipc=json.loads((ROOT/'evidence/macos-ipc-trust.json').read_text())
        authenticated=ipc['status']=='PASS' and ipc['certificate_sha1']==pin and helper_plist.get('SquirrelEnhancementCertificateSHA1')==pin
        for name,digest in ipc['source_sha256'].items():
            authenticated &= hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest
        for path,identifier in [(app,'org.rime.inputmethod.SquirrelEnhanced.Development'),(helper,'org.rime.SquirrelEnhanced.Development.VoiceHelper')]:
            commands.append(run(['codesign','--verify','--strict','-R',f'=identifier "{identifier}" and certificate leaf = H"{pin}"',str(path)]))
        assert authenticated,'Certificate-pinned IPC evidence is missing or stale'
    report={'utc':datetime.now(timezone.utc).isoformat(),'layer':'real macOS frontend/Helper/native worker build and verified signature; authenticated local IPC tested separately; NOT installed IMK',
       'app':str(app),'sdk':'MacOSX26.5.sdk','swift_language_mode':5,'commands':commands,
       'source_sha256':provenance['source_sha256'],
       'completed_build_provenance':provenance,
       'binary_sha256':{str(p.relative_to(app)):hashlib.sha256(p.read_bytes()).hexdigest() for p in binary},
       'plist':main_plist,'helper_plist':helper_plist,'microphone_usage_and_identity_valid':microphone_metadata,
       'responsible_main_and_helper_audio_entitlements_valid':microphone_entitlements,
       'sparkle_archive_sha256':hashlib.sha256((project/'download/Sparkle-2.6.2.tar.xz').read_bytes()).hexdigest(),
       'installed':False,'input_source_selected':False,'production_IPC_enabled':authenticated,'apple_notarized':False,'application_signing':'local certificate-pinned' if pin else 'ad-hoc; production IPC disabled',
       'status':'PASS' if all(c['exit_code']==0 for c in commands) and microphone_entitlements and microphone_metadata else 'FAIL'}
    (ROOT/'evidence/macos-build.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report['status']);return int(report['status']!='PASS')

if __name__=='__main__':raise SystemExit(main())
