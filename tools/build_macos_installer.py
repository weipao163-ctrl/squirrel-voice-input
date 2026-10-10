"""Create a real Installer product containing the compiled app and user transaction."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from macos_build_provenance import validate

ROOT=Path(__file__).resolve().parents[1]

def command(argv,check=True):
    result=subprocess.run([str(v) for v in argv],capture_output=True,text=True,timeout=120)
    record={'argv':[str(v) for v in argv],'exit_code':result.returncode,'output':result.stdout+result.stderr,'stdout':result.stdout,'stderr':result.stderr}
    if check and result.returncode: raise RuntimeError(record['output'])
    return record

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    project=ROOT/'enhanced-squirrel'
    app=project/'build/CLT/SquirrelEnhancedDev.app'
    provenance=validate(app)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    pin=info.get('SquirrelEnhancementCertificateSHA1','')
    assert len(pin)==40 and all(c in '0123456789abcdefABCDEF' for c in pin)
    ipc=json.loads((ROOT/'evidence/macos-ipc-trust.json').read_text())
    assert ipc['status']=='PASS' and ipc['certificate_sha1']==pin
    for name,digest in ipc['source_sha256'].items(): assert sha(ROOT/name)==digest
    checks=[command(['codesign','--verify','--deep','--strict',app])]
    helper=app/'Contents/Resources/SquirrelVoiceHelper.app'
    assert sha(app/'Contents/SharedSupport/squirrel.yaml') == sha(project/'resources/EnhancedDefaultSquirrel.yaml')
    # Local migration reads user dictionaries only into Library/Application
    # Support. They must never accidentally enter a compiled app or Scripts.
    private_names={'cn_dicts','en_dicts','custom_phrase.txt','sogou_personal.dict.yaml',
        'rime_ice.dict.yaml','rime_ice_quick_completion.dict.yaml','quick_single_char.dict.yaml',
        'radical_pinyin.dict.yaml','melt_eng.dict.yaml'}
    assert not any(private_names.intersection(p.relative_to(app).parts) or
        any(part.endswith('.userdb') for part in p.relative_to(app).parts) for p in app.rglob('*'))
    checks.append(command(['codesign','--verify','--strict','-R',f'=identifier "org.rime.inputmethod.SquirrelEnhanced.Development" and certificate leaf = H"{pin}"',app]))
    checks.append(command(['codesign','--verify','--strict','-R',f'=identifier "org.rime.SquirrelEnhanced.Development.VoiceHelper" and certificate leaf = H"{pin}"',helper]))
    stage=Path(tempfile.mkdtemp(prefix='installer-',dir=project/'build'))
    scripts=stage/'scripts';scripts.mkdir()
    checks.append(command(['/usr/bin/ditto',app,scripts/app.name]))
    for name,target in [('pkg-postinstall.sh','postinstall'),('pkg-user-install.sh','pkg-user-install.sh'),('app-install-transaction.sh','app-install-transaction.sh'),('app-update-preparation.sh','app-update-preparation.sh')]:
        destination=scripts/target;destination.write_bytes((project/'scripts'/name).read_bytes());destination.chmod(0o755)
        checks.append(command(['/bin/bash','-n',destination]))
    # Read-only/early-rejection checks: no real installation or registration.
    rejection=command(['/bin/bash',scripts/'postinstall','package','location','/Volumes/Other'],check=False)
    assert rejection['exit_code']==2
    home_rejection=command(['/bin/bash',scripts/'pkg-user-install.sh',scripts/app.name,'/not-the-user-home'],check=False)
    assert home_rejection['exit_code']==2
    identifier='org.rime.SquirrelEnhanced.Development.Installer'
    version='0.1.20261010.2'
    component=stage/'SquirrelVoiceInput.component.pkg'
    # Script-only package avoids Installer overwriting a live input method. The
    # signed app is inside Scripts and installed atomically by the shared tested
    # user transaction; root never writes the user's app or Rime data itself.
    checks.append(command(['/usr/bin/pkgbuild','--nopayload','--scripts',scripts,
      '--identifier',identifier,'--version',version,'--install-location','/',component]))
    requirements=stage/'requirements.plist'
    requirements.write_bytes(plistlib.dumps({'os':['13.0'],'arch':['arm64']}))
    distribution=stage/'Distribution.xml'
    checks.append(command(['/usr/bin/productbuild','--synthesize','--product',requirements,'--package',component,distribution]))
    tree=ET.parse(distribution);root=tree.getroot()
    ET.SubElement(root,'title').text='鼠须管语音增强输入法'
    ET.SubElement(root,'welcome',{'file':'Welcome.html','mime-type':'text/html'})
    ET.SubElement(root,'conclusion',{'file':'Conclusion.html','mime-type':'text/html'})
    resources=stage/'resources';resources.mkdir()
    template='<!doctype html><html lang="zh-CN"><meta charset="utf-8"><style>body{font:14px -apple-system,sans-serif;color:#333;line-height:1.65;margin:20px}h1{font-size:21px}li{margin:8px 0}.note{color:#666;font-size:12px}</style><body>__CONTENT__</body></html>'
    (resources/'Welcome.html').write_text(template.replace('__CONTENT__','''<h1>鼠须管语音增强输入法</h1><p>适用于 Apple Silicon · macOS 13 及以上。</p><p>安装到当前登录用户的 <b>Library/Input Methods/SquirrelEnhancedDev.app</b>。增强版使用独立设置与词库目录，已有增强版会先备份，保留现有鼠须管与正式词库。</p><p>更新时会先正常退出增强版；如有未保存设置，请处理保存或取消提示。正在使用增强版时会暂时切换到系统键盘输入源，让已有输入组合正常结束，再备份替换程序。不会强制结束进程。安装会注册独立的“鼠须管增强开发版”并尝试启用它。安装完成后请保存工作，注销当前用户，再重新登录；随后在输入法菜单或系统设置中选择增强版。语音设置中可以配置 API Key、长按热键、申请麦克风权限，并在测试框中真实试用。</p><p class="note">这是本机证书签名安装版本，未经过 Apple Developer ID 签名与公证。新电脑首次打开可能被系统拦截；确认来源后可在“系统设置 → 隐私与安全性”中使用“仍要打开”。不需要关闭系统安全保护。安装包不含任何 API Key 和个人词库，语音服务与权限需在新电脑重新设置。</p>'''),encoding='utf-8')
    (resources/'Conclusion.html').write_text(template.replace('__CONTENT__','''<h1>安装后的操作</h1><ol><li>保存正在编辑的内容，点击苹果菜单 → 注销当前用户，再重新登录 macOS。新的输入法需要在重新登录后刷新系统列表。</li><li>在菜单栏输入法菜单中选择“鼠须管增强开发版”。如尚未添加，请打开系统设置 → 键盘 → 文本输入 → 编辑，点击＋，在“简体中文”中添加增强版。</li><li>选择该输入法，从输入法菜单打开增强设置，进入“语音输入设置”。</li><li>填写自己的服务信息与 API Key，设置长按热键，点击“申请麦克风权限”和“授权输入法焦点检测”，按系统提示允许；随后“保存并应用”。新电脑不会继承另一台电脑的 Key、麦克风选择或授权。</li><li>在语音输入测试框中按住热键说话、松手结束。识别完成后自动插入；正常输入也无需人工确认。</li></ol><p>更新前的增强版位于 Library/Application Support/SquirrelEnhancedDev/install-backups；普通设置与正式词库均保留。</p>'''),encoding='utf-8')
    tree.write(distribution,encoding='utf-8',xml_declaration=True)
    output=ROOT/f'dist/SquirrelVoiceInput-{version}-arm64.pkg';output.parent.mkdir(exist_ok=True)
    candidate=stage/output.name
    checks.append(command(['/usr/bin/productbuild','--distribution',distribution,'--package-path',stage,'--resources',resources,candidate]))
    # Expand the deliverable itself into a new directory and verify that it
    # contains exactly the compiled binaries and intended installer scripts.
    expanded=stage/'expanded'
    checks.append(command(['/usr/sbin/pkgutil','--expand-full',candidate,expanded]))
    fresh_scripts=next(p for p in expanded.rglob('Scripts') if (p/app.name).is_dir())
    package_info=ET.parse(fresh_scripts.parent/'PackageInfo').getroot()
    assert package_info.attrib['identifier']==identifier and package_info.attrib['auth']=='root'
    assert package_info.find('./scripts/postinstall').attrib['file']=='./postinstall'
    assert package_info.find('./payload') is None
    fresh=fresh_scripts/app.name
    checks.append(command(['codesign','--verify','--deep','--strict',fresh]))
    checks.append(command(['codesign','--verify','--strict','-R',f'=identifier "org.rime.SquirrelEnhanced.Development.VoiceHelper" and certificate leaf = H"{pin}"',fresh/'Contents/Resources/SquirrelVoiceHelper.app']))
    hashes={str(p.relative_to(app)):sha(p) for p in app.rglob('*') if p.is_file()}
    extracted={str(p.relative_to(fresh)):sha(p) for p in fresh.rglob('*') if p.is_file()}
    assert hashes==extracted
    for name in ['postinstall','pkg-user-install.sh','app-install-transaction.sh','app-update-preparation.sh']:
        assert sha(scripts/name)==sha(fresh_scripts/name)
    probe_stage=stage/'real-rime-check'
    probe_command=[fresh/'Contents/MacOS/SquirrelLetterProbe',fresh/'Contents/Frameworks/librime.1.dylib',fresh/'Contents/Resources/LetterProbe',probe_stage,'asdfghjkl','true']
    probe_result=command(probe_command);checks.append(probe_result)
    probe=json.loads(probe_result['stdout']);assert probe['passed']==14 and probe['failed']==0
    # A developer machine's deployed/user dictionaries can hide missing default
    # resources. Test every enabled bundled schema in a NEW empty data directory.
    clean_source=ROOT/'tools/NativeCleanRimeProbe.cpp'
    clean_binary=stage/'NativeCleanRimeProbe'
    checks.append(command(['/usr/bin/xcrun','clang++','-std=c++17','-O2','-I',
      project/'librime/src',clean_source,'-o',clean_binary]))
    clean_result=command([clean_binary,fresh/'Contents/Frameworks/librime.1.dylib',
      fresh/'Contents/SharedSupport',stage/'clean-default-rime'])
    checks.append(clean_result)
    clean_probe=json.loads(clean_result['stdout'])
    assert clean_probe['status']=='PASS' and clean_probe['enabled_schemas']==6
    assert clean_probe['all_enabled_schema_sources_and_selection_verified']
    assert clean_probe['all_enabled_schemas_have_real_candidates']
    assert clean_probe['quick5_real_candidates'] and clean_probe['simplified_fixture_output']=='中国测试'
    choices=command(['/usr/sbin/installer','-pkg',candidate,'-target','/','-showChoicesXML']);checks.append(choices)
    plistlib.loads(choices['stdout'].encode())
    forbidden=[str(p.relative_to(fresh_scripts)) for p in fresh_scripts.rglob('*') if p.is_file() and (p.suffix in ['.key','.pem','.p12'] or p.name=='settings.json' or '.userdb' in p.name or p.suffix=='.log')]
    assert not forbidden
    build=json.loads((ROOT/'evidence/macos-build.json').read_text())
    assert build['status']=='PASS' and build['responsible_main_and_helper_audio_entitlements_valid']
    assert build['source_sha256']==provenance['source_sha256'] and build['binary_sha256']==provenance['binary_sha256']
    assert all(sha(app/name)==digest for name,digest in build['binary_sha256'].items())
    if output.exists(): output.rename(output.with_name(output.stem+'.previous-'+datetime.now().strftime('%H%M%S')+'.pkg'))
    candidate.replace(output)
    report={'utc':datetime.now(timezone.utc).isoformat(),'status':'PASS',
      'layer':'real pkgbuild/productbuild installer, fresh package expansion, exact app/script comparison, signature requirements, read-only Installer metadata, 14 letter cases and all 6 default schemas with empty user data',
      'package':str(output),'bytes':output.stat().st_size,'sha256':sha(output),'identifier':identifier,'version':version,
      'target':'current console user ~/Library/Input Methods/SquirrelEnhancedDev.app',
      'installer_postinstall_declared':True,'installer_payload_overwrite_disabled':True,
      'source_sha256':{str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),clean_source,project/'scripts/pkg-postinstall.sh',project/'scripts/pkg-user-install.sh',project/'scripts/app-install-transaction.sh',project/'scripts/app-update-preparation.sh']},
      'binary_sha256':build['binary_sha256'],'checks':checks,'probe':probe,'clean_default_rime_probe':clean_probe,'extracted':str(expanded),
      'early_rejection_checks':[rejection,home_rejection],'forbidden_private_or_runtime_files':forbidden,
      'application_signing':'local self-signed certificate; both IPC peers pinned to exact certificate/identifier',
      'bundled_default_appearance_matches_resource':True,'local_personal_dictionaries_excluded':True,
      'installer_developer_id_signed':False,'apple_notarized':False,'installed':False,'input_source_selected':False,'microphone_used':False,'cloud_calls':0,
      'full_goal_complete':False}
    (ROOT/'evidence/macos-installer.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    output.with_suffix('.pkg.sha256').write_text(report['sha256']+'  '+output.name+'\n')
    print('PASS',output.name,report['bytes'],'bytes; fresh package verified; NOT installed')
    return 0

if __name__=='__main__':raise SystemExit(main())
