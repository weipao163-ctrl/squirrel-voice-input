"""Compile/run the SAME bundled native GUI fixture worker, never the live Rime dir.

Windows requires the previously isolated official MSVC/SDK tree. On macOS,
uses Xcode clang++. No installer, microphone, cloud, current config or userdb.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--library',required=True,type=Path)
    ap.add_argument('--tools',type=Path)
    ap.add_argument('--cxx',type=Path)
    ap.add_argument('--windows-sdk',type=Path)
    ap.add_argument('--sdk-version',default='10.0.22000.0')
    ap.add_argument('--report',type=Path,default=ROOT/'evidence/native-letter-probe.json')
    args=ap.parse_args();work=Path(tempfile.mkdtemp(prefix='squirrel-native-probe-'))
    source=ROOT/'enhanced-squirrel/Enhancements/Native/LetterProbe.cpp'
    header=ROOT/'enhanced-squirrel/librime/src/rime_api.h'
    resources=ROOT/'enhanced-squirrel/resources/LetterProbe'
    shutil.copyfile(source,work/source.name);shutil.copyfile(header,work/header.name)
    env=os.environ.copy();extra=[]
    launch={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {}
    if os.name=='nt':
        if not args.tools:ap.error('Windows requires --tools; no system installation is attempted')
        tools=args.tools.resolve();vc=next((tools/'msvc/VC/Tools/MSVC').iterdir())
        # MSVC 14.44's STL requires Clang 19; the old Swift SDK has Clang 17.
        # Use the actual matching cl.exe, not a compiler-version guard bypass.
        cxx=args.cxx or vc/'bin/Hostx64/x64/cl.exe'
        kit=(args.windows_sdk or tools/'winsdk').resolve();inc=kit/'Include'/args.sdk_version;lib=kit/'Lib'/args.sdk_version
        env['PATH']=';'.join([str(cxx.parent),str(vc/'bin/Hostx64/x64')])+ ';'+env.get('PATH','')
        dirs=[vc/'include',inc/'ucrt',inc/'shared',inc/'um',inc/'winrt']
        env['INCLUDE']=';'.join(map(str,dirs))
        env['LIB']=';'.join(str(p) for p in [vc/'lib/x64',vc/'lib/onecore/x64',lib/'ucrt/x64',lib/'um/x64'])
        env['VCToolsInstallDir']=str(vc)+'\\';env['WindowsSdkDir']=str(kit)+'\\';env['WindowsSDKVersion']=args.sdk_version+'\\'
        for p in dirs:extra+=['-I',str(p)]
        extra+=['-fms-runtime-lib=static'];exe=work/'SquirrelLetterProbe.exe'
    else:
        cxx=args.cxx or Path(shutil.which('clang++') or 'clang++')
        extra+=['-mmacosx-version-min=13.0'] if __import__('sys').platform=='darwin' else ['-ldl']
        exe=work/'SquirrelLetterProbe'
    msvc=cxx.name.lower()=='cl.exe'
    version=subprocess.run([str(cxx)]+([] if msvc else ['--version']),capture_output=True,env=env,encoding='utf-8',errors='replace',timeout=30,**launch)
    command=[str(cxx),'-std=c++17','-O1','-Wall','-Wextra','-I',str(work),str(work/source.name),'-o',str(exe)]+extra
    if msvc:
        command=[str(cxx),'/nologo','/std:c++17','/O1','/W4','/MT','/EHsc','/utf-8','/I'+str(work),str(work/source.name),'/Fe:'+str(exe),'/Fo:'+str(work/'LetterProbe.obj'),'/link','/INCREMENTAL:NO']
    build=subprocess.run(command,cwd=work,env=env,capture_output=True,encoding='utf-8',errors='replace',timeout=120,**launch)
    report={'utc':datetime.now(timezone.utc).isoformat(),'layer':'same native GUI worker compiled and executed with real librime; NOT GUI or physical mouse/key events',
            'work':str(work),'compiler':(version.stdout+version.stderr).strip()[:1000],'build_argv':command,'build_exit_code':build.returncode,
            'build_output':build.stdout+build.stderr,'source_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in [source,header,*resources.glob('*'),ROOT/'enhanced-squirrel/resources/letter_selection.lua']},
            'cases':[],'negative_controls':[],'macOS_GUI_tested':False,'microphone_used':False,'cloud_calls':0,
            'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'library_sha256':hashlib.sha256(args.library.read_bytes()).hexdigest()}
    if build.returncode==0:
        for n,(keys,hide) in enumerate([('asdfghjkl',True),('abcdefghi',True),('qwertyuio',False),('a',True),('abcdefg',True),('asdfg',True)]):
            # Resource path deliberately remains the actual Unicode workspace
            # path: Windows wmain must correctly decode it, not hide that case.
            argv=[str(exe),str(args.library.resolve()),str(resources.resolve()),str(work/f'run-{n}'),keys,str(hide).lower()]
            run=subprocess.run(argv,cwd=work,env=env,capture_output=True,encoding='utf-8',errors='replace',timeout=90,**launch)
            row={'argv':argv,'exit_code':run.returncode,'stdout':run.stdout,'stderr':run.stderr,'runtime':None}
            try:row['runtime']=json.loads(run.stdout)
            except ValueError:pass
            report['cases'].append(row)
            runtime=row['runtime'] or {};print(keys,hide,'exit',run.returncode,'status',runtime.get('status'),'passed',runtime.get('passed'),'failed',runtime.get('failed'),flush=True)
        report['executable_sha256']=hashlib.sha256(exe.read_bytes()).hexdigest()
        bad_parent=work/'bad-resource';bad_resource=bad_parent/'LetterProbe';bad_resource.mkdir(parents=True)
        for p in resources.glob('*.yaml'):shutil.copyfile(p,bad_resource/p.name)
        existing=work/'existing';existing.mkdir();marker=existing/'marker';marker.write_bytes(b'KEEP')
        controls=[('existing_work_refused',resources,existing,'abcdefghi'),
                  ('invalid_keys_refused',resources,work/'invalid-keys','aa'),
                  ('missing_Lua_refused',bad_resource,work/'missing-lua','abcdefghi')]
        for name,resource,target,keys in controls+ [('bad_Lua_does_not_crash_or_claim_success',bad_resource,work/'bad-lua','abcdefghi')]:
            if name.startswith('bad_Lua'):(bad_parent/'letter_selection.lua').write_text("return 'not-a-processor'\n",encoding='utf-8')
            argv=[str(exe),str(args.library.resolve()),str(resource.resolve()),str(target),keys,'true']
            run=subprocess.run(argv,cwd=work,env=env,capture_output=True,encoding='utf-8',errors='replace',timeout=90,**launch)
            try:r=json.loads(run.stdout)
            except ValueError:r=None
            good=run.returncode==1 and r is not None and r['status']=='FAIL' and r['failed']>0 and marker.read_bytes()==b'KEEP'
            if name=='invalid_keys_refused':good &= not target.exists()
            if name.startswith('bad_Lua'):good &= len(r['tests'])==14 if r else False
            report['negative_controls'].append({'name':name,'status':'PASS' if good else 'FAIL','argv':argv,'exit_code':run.returncode,'stdout':run.stdout,'stderr':run.stderr,'runtime':r})
            print('negative',name,'PASS' if good else 'FAIL',flush=True)
    report['status']='PASS' if build.returncode==0 and len(report['cases'])==6 and all(c['exit_code']==0 and c['runtime'] and c['runtime']['status']=='PASS' and c['runtime']['failed']==0 for c in report['cases']) and len(report['negative_controls'])==4 and all(c['status']=='PASS' for c in report['negative_controls']) else 'FAIL'
    report['passed']=sum((c['runtime'] or {}).get('passed',0) for c in report['cases'])
    report['skipped']=sum((c['runtime'] or {}).get('skipped',0) for c in report['cases'])
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    if report['status']=='FAIL':print(build.stdout+build.stderr if build.returncode else 'Failure details saved in report')
    print(report['status'],args.report.resolve(),flush=True);return int(report['status']!='PASS')

if __name__=='__main__':raise SystemExit(main())
