"""Exercise the real Bash maintenance protocol with explicit process/UI doubles."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
SCRIPT=ROOT/'enhanced-squirrel/scripts/app-update-preparation.sh'

class PreparationTests(unittest.TestCase):
    def run_case(self,mode,running=True):
        with tempfile.TemporaryDirectory(prefix='squirrel-update-fixture-') as directory:
            base=Path(directory)
            source=base/'build with spaces/SquirrelEnhancedDev.app'
            executable=source/'Contents/MacOS/SquirrelEnhancedDev'
            executable.parent.mkdir(parents=True)
            target=base/'home with spaces/Library/Input Methods/SquirrelEnhancedDev.app'
            target.mkdir(parents=True)
            original=b'previous app and user edits'
            (target/'original').write_bytes(original)
            state=base/'state'; state.mkdir()
            if running: (state/'running').touch()
            executable.write_text('''#!/bin/bash
[[ "$1" == --quit && "$2" == --installed-app-path ]] || exit 99
printf '%s\\n' "$3" > "$FIXTURE_STATE/quit-target"
case "$FIXTURE_MODE" in
  exit) rm "$FIXTURE_STATE/running" ;;
  cancel) exit 17 ;;
  stuck) : ;;
esac
''')
            executable.chmod(0o755)
            command='''source "$1"
development_app_is_running() { [[ -e "$FIXTURE_STATE/running" ]]; }
prepare_development_app_update "$2" "$3"
'''
            result=subprocess.run(['/bin/bash','-c',command,'fixture',str(SCRIPT),str(source),str(target)],
                env={**os.environ,'FIXTURE_STATE':str(state),'FIXTURE_MODE':mode},capture_output=True,text=True,timeout=12)
            self.assertEqual((target/'original').read_bytes(),original)
            return result,(state/'quit-target').read_text().strip() if (state/'quit-target').exists() else None,str(target),(state/'running').exists()

    def test_no_running_process_does_not_request_quit(self):
        result,called,_,_=self.run_case('exit',False)
        self.assertEqual(result.returncode,0);self.assertIsNone(called)

    def test_running_app_exits_cooperatively_and_scopes_correct_target(self):
        result,called,target,running=self.run_case('exit')
        self.assertEqual(result.returncode,0);self.assertEqual(called,target);self.assertFalse(running)

    def test_cancel_preserves_original_and_running_app(self):
        result,called,target,running=self.run_case('cancel')
        self.assertEqual(result.returncode,2);self.assertEqual(called,target);self.assertTrue(running)
        self.assertIn('未替换',result.stderr)

    def test_successful_quit_request_without_exit_cannot_start_replacement(self):
        result,_,_,running=self.run_case('stuck')
        self.assertEqual(result.returncode,2);self.assertTrue(running)
        self.assertIn('保留原安装',result.stderr)

if __name__=='__main__':unittest.main()
