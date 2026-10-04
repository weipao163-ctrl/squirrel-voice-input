"""Real, certificate-signed private UNIX socket peers. No IMK install, keys or audio."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]

def run(argv, timeout=60):
    result=subprocess.run([str(v) for v in argv],capture_output=True,text=True,timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stdout+result.stderr)
    return result

def main():
    project=ROOT/'enhanced-squirrel'
    (project/'build').mkdir(exist_ok=True)
    (ROOT/'evidence').mkdir(exist_ok=True)
    signing=project/'build/local-signing'
    signer=project/'build/signing-tools/apple-codesign-0.29.0-aarch64-apple-darwin/rcodesign'
    stage=Path(tempfile.mkdtemp(prefix='ipc-trust-',dir=project/'build'))
    stage.chmod(0o700)
    peer_source=project/'Enhancements/Sources/EnhancementIPC/PeerTrust.swift'
    probe_source=ROOT/'tools/NativeIPCTrustProbe.swift'
    unsigned=stage/'unsigned'
    bins=Path(run(['swift','build','--package-path',project/'Enhancements','--build-system','native','--sdk',
        subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip(),'--scratch-path',project/'build/swift-clt','--show-bin-path']).stdout.strip())
    objects=[*sorted((bins/'EnhancementCore.build').glob('*.swift.o')),*sorted((bins/'EnhancementIPC.build').glob('*.swift.o'))]
    run(['xcrun','swiftc','-sdk',subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip(),'-parse-as-library','-I',bins/'Modules',probe_source,*objects,'-o',unsigned])
    validation=json.loads(run([unsigned,'validate']).stdout)
    fingerprint=plistlib.loads((project/'build/CLT/SquirrelEnhancedDev.app/Contents/Info.plist').read_bytes())['SquirrelEnhancementCertificateSHA1']
    assert len(fingerprint)==40
    # A second signer is an adversarial fixture, never a product identity.
    run(['openssl','req','-new','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','2',
         '-config',signing/'openssl.cnf','-keyout',stage/'other.key','-out',stage/'other.crt'])
    (stage/'other.key').chmod(0o600)
    other=run(['openssl','x509','-in',stage/'other.crt','-noout','-fingerprint','-sha1']).stdout.strip().split('=')[-1].replace(':','')
    def signed(name,identifier,cert,key):
        target=stage/name
        run([signer,'-C','/dev/null','sign','--pem-file',cert,'--pem-file',key,
             '--timestamp-url','none','--code-signature-flags','runtime',
             '--binary-identifier',identifier,unsigned,target])
        run(['codesign','--verify','--strict',target])
        return target
    parent=signed('parent','org.rime.inputmethod.SquirrelEnhanced.Development',signing/'local.crt',signing/'local.key')
    helper=signed('helper','org.rime.SquirrelEnhanced.Development.VoiceHelper',signing/'local.crt',signing/'local.key')
    wrong_signer=signed('wrong-signer','org.rime.SquirrelEnhanced.Development.VoiceHelper',stage/'other.crt',stage/'other.key')
    wrong_id=signed('wrong-id','org.rime.Unrelated',signing/'local.crt',signing/'local.key')
    wrong_parent=signed('wrong-parent-id','org.rime.Unrelated',signing/'local.crt',signing/'local.key')
    (stage/'other.key').unlink()
    cases=[]
    for name,parent_binary,child,parent_pin,expect,reject,mode in [
        ('matching peers exchange a real 64 KiB reply',parent,helper,fingerprint,'accept',False,'normal'),
        ('parent rejects foreign certificate',parent,wrong_signer,fingerprint,'reject',False,'normal'),
        ('parent rejects foreign identifier',parent,wrong_id,fingerprint,'reject',False,'normal'),
        ('helper rejects foreign parent signer',parent,helper,other,'reject',False,'normal'),
        ('parent rejects unlaunched PID',parent,helper,fingerprint,'reject',True,'normal'),
        ('helper rejects foreign parent identifier',wrong_parent,helper,fingerprint,'reject',False,'normal'),
        ('private bootstrap rejects wrong token',parent,helper,fingerprint,'reject',False,'wrongToken'),
        ('private bootstrap rejects wrong parent PID',parent,helper,fingerprint,'reject',False,'wrongParentPID'),
        ('oversized frame closes authenticated connection',parent,helper,fingerprint,'reject',False,'oversized'),
        ('malformed JSON closes authenticated connection',parent,helper,fingerprint,'reject',False,'malformed'),
        ('unknown method closes authenticated connection',parent,helper,fingerprint,'reject',False,'unknown'),
        ('oversized decoded payload closes authenticated connection',parent,helper,fingerprint,'reject',False,'oversizedPayload')]:
        command=[parent_binary,'parent',child,fingerprint,parent_pin,expect,'rejectPID' if reject else 'normal',mode]
        result=run(command,timeout=20)
        cases.append({'name':name,**json.loads(result.stdout)})
    report={'utc':datetime.now(timezone.utc).isoformat(),
      'layer':'real macOS private AF_UNIX stream with kernel audit-token signature validation, exact identifiers, certificate pins, UID/PID routing, private bootstrap and owner-loss cleanup',
      'certificate_sha1':fingerprint,'configuration_checks':validation['passed'],'bootstrap_checks':validation['bootstrap_checks'],'cases':cases,
      'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [peer_source,peer_source.with_name('AuthenticatedIPC.swift'),peer_source.with_name('IPC.swift'),probe_source,Path(__file__)]},
      'installed':False,'microphone_used':False,'cloud_calls':0,
      'status':'PASS' if all(c['passed'] for c in cases) and validation['passed']==11 and validation['bootstrap_checks']==11 and len(cases)==12 else 'FAIL'}
    (ROOT/'evidence/macos-ipc-trust.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report['status'],len(cases),'native authenticated IPC cases and',validation['passed'],'configuration checks')
    return int(report['status']!='PASS')

if __name__=='__main__':raise SystemExit(main())
