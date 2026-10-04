"""Publication guard verifies staged bytes and rejects personal/build artifacts."""
import contextlib
import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("public_guard", ROOT/"tools/check_public_source.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.old = guard.ROOT
        guard.ROOT = self.root
        public = Path("enhanced-squirrel/resources/Quick5")
        shutil.copytree(ROOT/public, self.root/public)
    def tearDown(self):
        guard.ROOT = self.old
        self.temp.cleanup()
    def result(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return guard.main()
    def write(self, name, value):
        path = self.root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value)
    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, capture_output=True, check=True)
    def test_public_provenance_passes(self):
        self.assertEqual(self.result(), 0)
    def test_personal_dictionary_rejected(self):
        self.write("custom/private.dict.yaml", b"fixture")
        self.assertEqual(self.result(), 1)
    def test_signing_key_rejected(self):
        self.write("local.key", b"synthetic fixture")
        self.assertEqual(self.result(), 1)
    def test_build_output_rejected(self):
        self.write("build/result.txt", b"fixture")
        self.assertEqual(self.result(), 1)
    def test_service_credential_rejected(self):
        self.write("example.txt", ("sk-" + "a"*32).encode())
        self.assertEqual(self.result(), 1)
    def test_compiled_magic_rejected(self):
        self.write("program", bytes([0x7f, 0x45, 0x4c, 0x46]))
        self.assertEqual(self.result(), 1)
    def test_upstream_dictionary_mutation_rejected(self):
        self.write("enhanced-squirrel/resources/Quick5/quick5.dict.yaml", b"changed fixture")
        self.assertEqual(self.result(), 1)
    def test_staged_secret_detected_after_working_copy_cleaned(self):
        self.git("init", "-q")
        self.write("example.txt", ("sk-" + "a"*32).encode())
        self.git("add", ".")
        self.write("example.txt", b"working copy has been cleaned")
        self.assertEqual(self.result(), 1)
    def test_ignored_local_output_is_not_published(self):
        self.git("init", "-q")
        self.write(".gitignore", b"build/\n")
        self.git("add", ".")
        self.write("build/local.key", b"synthetic private fixture")
        self.assertEqual(self.result(), 0)

if __name__ == "__main__":
    unittest.main()
