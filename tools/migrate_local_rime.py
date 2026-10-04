"""Copy the authorized local Rime data into the isolated IME, never into packages.

Requires both input methods to be stopped. Original source files are read-only;
conflicting destination files and settings receive a private recoverable backup.
"""
import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid
from ruamel.yaml import YAML

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path.home()/'Library/Rime'
BASE = Path.home()/'Library/Application Support/SquirrelEnhancedDev'
TARGET = BASE/'Rime'
SKIP = {'build','installation.yaml','user.yaml','sync','.DS_Store'}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def reject_symlinks(base):
    assert base.is_dir() and not base.is_symlink()
    assert base == base.resolve(), 'A migration root resolves outside its literal path'
    for path in base.rglob('*'):
        assert not path.is_symlink(), 'Symlink in Rime data; preserve it for manual review'

def source_files():
    return sorted(p for p in SOURCE.rglob('*') if p.is_file() and p.relative_to(SOURCE).parts[0] not in SKIP)

def current_source_schema():
    yaml = YAML(typ='safe')
    patch = yaml.load(SOURCE/'default.custom.yaml').get('patch',{})
    rows = patch.get('schema_list',[])
    schema = rows[0]['schema'] if rows else ''
    assert schema and (SOURCE/(schema+'.schema.yaml')).is_file()
    return schema

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    reject_symlinks(SOURCE); reject_symlinks(TARGET)
    files=source_files(); schema=current_source_schema()
    if not args.apply:
        print(json.dumps({'apply':False,'files':len(files),'bytes':sum(p.stat().st_size for p in files),'schema':schema,'no_copy_performed':True},ensure_ascii=False))
        return 0
    assert os.getuid() >= 500
    running=subprocess.run(['pgrep','-f',r'/Input Methods/(Squirrel|SquirrelEnhancedDev)\.app/Contents/MacOS/(Squirrel|SquirrelEnhancedDev)'],capture_output=True,text=True)
    assert running.returncode==1, 'Input methods are still running; no copy performed'
    settings=BASE/'settings.json'
    assert settings.is_file() and not settings.is_symlink()
    settings_before=settings.read_bytes()
    original_settings=json.loads(settings_before)
    before={str(p.relative_to(SOURCE)):digest(p) for p in files}
    backups=BASE/'rime-migrations';backups.mkdir(mode=0o700,exist_ok=True)
    assert not backups.is_symlink()
    work=backups/(datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8]);work.mkdir(mode=0o700)
    stage=work/'Rime-staged';old=work/'Rime-before';committed=False
    with ExitStack() as stack:
        # LevelDB uses POSIX record locks. Keep the source/target stores quiescent
        # throughout snapshotting; an active dictionary makes this fail safely.
        for base in [SOURCE,TARGET]:
            for database in sorted(base.glob('*.userdb')):
                lock=database/'LOCK'
                if lock.exists():
                    handle=stack.enter_context(lock.open('r+b'))
                    fcntl.lockf(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        assert before=={str(p.relative_to(SOURCE)):digest(p) for p in files}
        try:
            shutil.copytree(TARGET,stage,ignore=shutil.ignore_patterns('build'))
            for path in files:
                destination=stage/path.relative_to(SOURCE)
                destination.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(path,destination)
            assert all(digest(stage/name)==expected for name,expected in before.items())
            next_settings=json.loads(settings_before)
            letters=next_settings.setdefault('letters',{})
            if schema not in letters:
                template=next((value.copy() for value in letters.values() if value.get('enabled')),None)
                if template is None:
                    template={'enabled':False,'keys':'asdfghjkl','pageSize':9,'hideCandidates':True}
                template['useDefaultAppearance']=True
                letters[schema]=template
            else:
                # Preserve all existing key/custom-style values, select the
                # transferred IME appearance as explicitly requested.
                letters[schema]['useDefaultAppearance']=True
            next_settings['revision']=int(next_settings.get('revision',0))+1
            assert next_settings['revision'] <= 2**64-1
            assert next_settings.get('voice')==original_settings.get('voice')
            backup_settings=work/'settings-before.json';backup_settings.write_bytes(settings_before);backup_settings.chmod(0o600)
            staged_settings=work/'settings-staged.json';staged_settings.write_text(json.dumps(next_settings,ensure_ascii=False,indent=2)+'\n');staged_settings.chmod(0o600)
            assert settings.read_bytes()==settings_before
            TARGET.rename(old)
            try:
                stage.rename(TARGET)
                os.replace(staged_settings,settings)
                committed=True
            except Exception:
                if TARGET.exists():TARGET.rename(work/'Rime-failed')
                old.rename(TARGET)
                raise
            after={str(p.relative_to(SOURCE)):digest(p) for p in source_files()}
            assert before==after, 'Source changed during migration; retain both snapshots for review'
            assert all(digest(TARGET/name)==expected for name,expected in before.items())
            private_report={'source_sha256':before,'source_unchanged':True,'destination_copy_exact':True,'schema':schema,'settings_voice_preserved':True}
            (work/'private-copy-manifest.json').write_text(json.dumps(private_report,ensure_ascii=False,indent=2)+'\n')
            report={'utc':datetime.now(timezone.utc).isoformat(),'status':'COPIED_NOT_YET_DEPLOYED','source':str(SOURCE),'target':str(TARGET),'backup':str(work),
                'copied_files':len(files),'copied_bytes':sum(p.stat().st_size for p in files),'schema':schema,'source_unchanged':True,'destination_copy_exact':True,
                'previous_destination_and_settings_backed_up':True,'installation_identity_preserved':True,'generated_build_cache_copied':False,
                'voice_settings_preserved':True,'new_schema_uses_default_appearance':True,'personal_data_stored_in_workspace':False,
                'personal_dictionary_in_package':False,'deployed':False,'native_input_verified':False,'cloud_calls':0}
            (ROOT/'evidence/macos-local-rime-migration.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
            print(json.dumps({key:report[key] for key in ['status','copied_files','copied_bytes','schema','source_unchanged','destination_copy_exact']},ensure_ascii=False))
        except Exception:
            if not committed and old.exists() and not TARGET.exists():old.rename(TARGET)
            raise
    return 0

if __name__=='__main__':raise SystemExit(main())
