"""Exercise real hidden settings views with bounded synthetic updates, offline."""
import argparse,hashlib,json,subprocess,tempfile
from pathlib import Path
from macos_sdk import select_sdk
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser()
    p.add_argument('--label',default='current')
    p.add_argument('--mode',choices=['closed','hidden','visible','miniaturized'],default='closed')
    args=p.parse_args()
    project=ROOT/'enhanced-squirrel'
    bins=project/'build/swift-clt/arm64-apple-macosx/debug'
    work=Path(tempfile.mkdtemp(prefix='helper-memory-',dir=project/'build'))
    sources=[p for p in sorted((project/'Enhancements/Sources/VoiceHelper').glob('*.swift')) if p.name!='Main.swift']
    objects=[p for name in ['EnhancementCore','EnhancementIPC','EnhancementUI'] for p in sorted((bins/(name+'.build')).glob('*.swift.o'))]
    assert objects,'Build Helper modules first'
    cmd=['xcrun','swiftc','-swift-version','5','-sdk',select_sdk(),'-I',str(bins/'Modules'),*map(str,sources),str(ROOT/'tools/NativeHelperMemoryProbe.swift'),*map(str,objects),'-o',str(work/'probe')]
    evidence=ROOT/'evidence/memory-20261026';evidence.mkdir(parents=True,exist_ok=True)
    result=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
    (evidence/(args.label+'.compile.txt')).write_text(result.stdout+result.stderr)
    if result.returncode: print(result.stderr[-5000:]);return result.returncode
    run=subprocess.run([str(work/'probe'),str(work/'settings'),args.mode],capture_output=True,text=True,timeout=120)
    (evidence/(args.label+'.console.txt')).write_text(run.stdout+run.stderr)
    if run.returncode: print(run.stderr[-5000:]);return run.returncode
    report=json.loads(run.stdout);report['binary']=str(work/'probe')
    report['source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[ROOT/'tools/NativeHelperMemoryProbe.swift']}
    (evidence/(args.label+'.json')).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='source_sha256'},indent=2))
    return int(report['status']!='PASS')
if __name__=='__main__':raise SystemExit(main())
