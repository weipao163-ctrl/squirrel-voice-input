"""Execute the production directory migration with real Foundation file operations.

Only the app entry point and its fixed user directory are replaced by a fixture.
The migration function is extracted verbatim from Main.swift. No IMK, personal
Rime files, microphone, Keychain, or network is accessed.
"""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / "enhanced-squirrel/sources/Main.swift"
    text = source.read_text()
    start = text.index("  static func prepareUserDirectory() throws {")
    stop = text.index("\n  // swiftlint:disable:next cyclomatic_complexity", start)
    production = text[start:stop]
    swift = r'''
import Foundation
enum SquirrelApp {
  static var userDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
__PRODUCTION__
}
let fm = FileManager.default
var checks: [[String: Any]] = []
func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]) }
func write(_ data: String, _ url: URL) throws {
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(data.utf8).write(to: url)
}
func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
let current = SquirrelApp.userDir
let legacy = URL(fileURLWithPath: current.path(percentEncoded: true), isDirectory: true)
try write("old user preference", legacy.appendingPathComponent("user.yaml"))
try write("learning fixture", legacy.appendingPathComponent("luna_pinyin.userdb/CURRENT"))
try write("outdated cache", legacy.appendingPathComponent("build/luna_pinyin.schema.yaml"))
try write("old patch", legacy.appendingPathComponent("luna_pinyin.custom.yaml"))
try write("GUI patch", current.appendingPathComponent("luna_pinyin.custom.yaml"))
try fm.createSymbolicLink(at: legacy.appendingPathComponent("linked.yaml"), withDestinationURL: legacy.appendingPathComponent("user.yaml"))
try SquirrelApp.prepareUserDirectory()
check("decoded_native_path_matches_real_URL_directory", fm.fileExists(atPath: current.path) && current.path != current.path(percentEncoded: true))
check("GUI_patch_is_never_overwritten", read(current.appendingPathComponent("luna_pinyin.custom.yaml")) == "GUI patch")
check("missing_user_preferences_preserved", read(current.appendingPathComponent("user.yaml")) == "old user preference")
check("missing_learning_directory_preserved", read(current.appendingPathComponent("luna_pinyin.userdb/CURRENT")) == "learning fixture")
check("legacy_preferences_retained_for_rollback", read(legacy.appendingPathComponent("user.yaml")) == "old user preference")
check("legacy_learning_retained_for_rollback", read(legacy.appendingPathComponent("luna_pinyin.userdb/CURRENT")) == "learning fixture")
check("generated_cache_is_not_migrated", !fm.fileExists(atPath: current.appendingPathComponent("build").path))
check("legacy_symlink_is_not_copied", !fm.fileExists(atPath: current.appendingPathComponent("linked.yaml").path))
try write("new preference", current.appendingPathComponent("user.yaml"))
try SquirrelApp.prepareUserDirectory()
check("repeat_migration_preserves_later_user_edit", read(current.appendingPathComponent("user.yaml")) == "new preference")
check("no_partial_migration_directory_remains", try fm.contentsOfDirectory(atPath: current.path).allSatisfy { !$0.hasPrefix(".migration-") })
let second = current.deletingLastPathComponent().appendingPathComponent("Second Rime", isDirectory: true)
let secondLegacy = URL(fileURLWithPath: second.path(percentEncoded: true), isDirectory: true)
try fm.createSymbolicLink(at: secondLegacy, withDestinationURL: legacy)
SquirrelApp.userDir = second
var rejected = false
do { try SquirrelApp.prepareUserDirectory() } catch { rejected = true }
check("symlinked_legacy_directory_rejected", rejected)
check("symlink_rejection_does_not_copy_preferences", !fm.fileExists(atPath: second.appendingPathComponent("user.yaml").path))
let report: [String: Any] = ["status": checks.allSatisfy { $0["passed"] as? Bool == true } ? "PASS" : "FAIL", "checks": checks]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
exit(checks.allSatisfy { $0["passed"] as? Bool == true } ? 0 : 1)
'''.replace("__PRODUCTION__", production)
    work = Path(tempfile.mkdtemp(prefix="native-rime-directory-", dir=ROOT / "enhanced-squirrel/build"))
    script = work / "Probe.swift"
    script.write_text(swift)
    executable = work / "Probe"
    compile_args = ["xcrun", "swiftc", "-sdk", "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk", str(script), "-o", str(executable)]
    compiled = subprocess.run(compile_args, capture_output=True, text=True, timeout=120)
    assert compiled.returncode == 0, compiled.stderr
    # Canonical ASCII temp root keeps encoded fixture paths within this root.
    with tempfile.TemporaryDirectory(prefix="squirrel-directory-fixture-") as directory:
        fixture = Path(directory).resolve() / "Library/Application Support/Rime"
        result = subprocess.run([str(executable), str(fixture)], capture_output=True, text=True, timeout=30)
    assert result.stdout, result.stderr
    report = json.loads(result.stdout)
    report.update(utc=datetime.now(timezone.utc).isoformat(), layer="verbatim production Swift migration; real Foundation filesystem fixtures; NOT installed Rime or IMK",
                  production_function_sha256=hashlib.sha256(production.encode()).hexdigest(),
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [source, Path(__file__).resolve()]},
                  compile_exit_code=compiled.returncode, exit_code=result.returncode,
                  microphone_used=False, cloud_calls=0)
    (ROOT / "evidence/macos-rime-directory.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(report["status"], len(report["checks"]), "native directory checks")
    return int(result.returncode != 0 or report["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
