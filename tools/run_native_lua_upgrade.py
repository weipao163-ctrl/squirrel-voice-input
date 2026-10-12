"""Execute the production Lua upgrader against disposable macOS file fixtures."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SWIFT = r'''
import Foundation
let base = URL(fileURLWithPath:CommandLine.arguments[1])
let previous = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
let bundled = Bundle.main.url(forResource:"letter_selection",withExtension:"lua")!
let replacement = try Data(contentsOf:bundled)
let fm = FileManager.default
var rows:[[String:String]] = []
func require(_ value:Bool) throws { if !value { throw NSError(domain:"fixture",code:1) } }
func fixture(_ name:String,_ data:Data?) throws -> URL {
  let root = base.appendingPathComponent(name)
  try fm.createDirectory(at:root.appendingPathComponent("lua"),withIntermediateDirectories:true)
  if let data { try data.write(to:root.appendingPathComponent("lua/letter_selection.lua")) }
  return root
}
func rejects(_ root:URL) throws {
  do { try EnhancementPatch.upgradeBundledLua(directory:root) }
  catch { return }
  throw NSError(domain:"fixture did not reject",code:2)
}
func test(_ name:String,_ body:() throws -> Void) {
  do { try body(); rows.append(["name":name,"status":"PASS"]) }
  catch { rows.append(["name":name,"status":"FAIL","error":String(describing:error)]) }
}
test("known_previous_resource_backed_up_and_replaced") {
  let root=try fixture("known",previous)
  try EnhancementPatch.upgradeBundledLua(directory:root)
  try require(try Data(contentsOf:root.appendingPathComponent("lua/letter_selection.lua"))==replacement)
  try require(try Data(contentsOf:root.appendingPathComponent("lua/letter_selection.lua.before-0.1.25"))==previous)
}
test("repeated_upgrade_preserves_bytes_and_timestamp") {
  let root=try fixture("current",replacement),lua=root.appendingPathComponent("lua/letter_selection.lua")
  let before=try fm.attributesOfItem(atPath:lua.path)[.modificationDate] as! Date
  try EnhancementPatch.upgradeBundledLua(directory:root)
  try require(before==(try fm.attributesOfItem(atPath:lua.path)[.modificationDate] as! Date))
}
test("user_modified_resource_untouched") {
  let bytes=Data("-- custom user source\n".utf8),root=try fixture("modified",bytes)
  try rejects(root)
  try require(try Data(contentsOf:root.appendingPathComponent("lua/letter_selection.lua"))==bytes)
}
test("conflicting_backup_preserves_current") {
  let root=try fixture("backup",previous)
  try Data("KEEP".utf8).write(to:root.appendingPathComponent("lua/letter_selection.lua.before-0.1.25"))
  try rejects(root)
  try require(try Data(contentsOf:root.appendingPathComponent("lua/letter_selection.lua"))==previous)
}
test("symlink_resource_preserves_external_target") {
  let root=try fixture("link",nil),target=base.appendingPathComponent("outside.lua")
  try previous.write(to:target)
  try fm.createSymbolicLink(at:root.appendingPathComponent("lua/letter_selection.lua"),withDestinationURL:target)
  try rejects(root); try require(try Data(contentsOf:target)==previous)
}
test("oversize_resource_not_replaced") {
  let bytes=Data(repeating:32,count:256*1024+1),root=try fixture("oversize",bytes)
  try rejects(root); try require(try Data(contentsOf:root.appendingPathComponent("lua/letter_selection.lua"))==bytes)
}
test("dangling_backup_link_preserves_current") {
  let root=try fixture("dangling-backup",previous)
  try fm.createSymbolicLink(at:root.appendingPathComponent("lua/letter_selection.lua.before-0.1.25"),withDestinationURL:base.appendingPathComponent("nonexistent"))
  try rejects(root); try require(try Data(contentsOf:root.appendingPathComponent("lua/letter_selection.lua"))==previous)
}
test("missing_user_resource_is_not_installed_or_enabled") {
  let root=try fixture("missing",nil)
  try EnhancementPatch.upgradeBundledLua(directory:root)
  try require(!fm.fileExists(atPath:root.appendingPathComponent("lua/letter_selection.lua").path))
}
test("missing_bundled_resource_preserves_current") {
  let root=try fixture("missing-bundle",previous)
  try fm.removeItem(at:bundled)
  defer { try? replacement.write(to:bundled) }
  try rejects(root); try require(try Data(contentsOf:root.appendingPathComponent("lua/letter_selection.lua"))==previous)
}
let result:[String:Any] = ["status":rows.allSatisfy{$0["status"]=="PASS"} ? "PASS":"FAIL","cases":rows]
print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
exit(rows.allSatisfy{$0["status"]=="PASS"} ? 0:1)
'''

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous-lua",required=True,type=Path)
    args=parser.parse_args()
    project=ROOT/"enhanced-squirrel"
    sdk=json.loads((project/"build/evidence/clt-build-complete.json").read_text())["sdk"]
    bins=Path(subprocess.check_output(["swift","build","--package-path",str(project/"Enhancements"),"--build-system","native","--sdk",sdk,"--scratch-path",str(project/"build/swift-clt"),"--show-bin-path"],text=True).strip())
    stage=Path(tempfile.mkdtemp(prefix="lua-upgrade-",dir=project/"build"))
    app=stage/"Probe.app"; exe=app/"Contents/MacOS/Probe"; resources=app/"Contents/Resources"
    exe.parent.mkdir(parents=True);resources.mkdir()
    (app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable":"Probe","CFBundleIdentifier":"org.rime.fixture.LuaUpgrade","CFBundlePackageType":"APPL"}))
    (resources/"letter_selection.lua").write_bytes((ROOT/"lua/letter_selection.lua").read_bytes())
    source=stage/"main.swift";source.write_text(SWIFT)
    library=Path.home()/"Library/Input Methods/SquirrelEnhancedDev.app/Contents/Frameworks/librime.1.dylib"
    command=["xcrun","swiftc","-swift-version","5","-sdk",sdk,"-I",str(bins/"Modules"),"-I",str(project/"librime/src"),"-I",str(project/"librime/include"),"-import-objc-header",str(project/"sources/Squirrel-Bridging-Header.h"),str(source),str(project/"sources/EnhancementPatch.swift"),*[str(p) for p in (bins/"EnhancementCore.build").glob("*.swift.o")],str(library),"-o",str(exe)]
    command += ["-Xlinker","-rpath","-Xlinker",str(library.parent)]
    build=subprocess.run(command,capture_output=True,text=True)
    if build.returncode: raise RuntimeError(build.stderr)
    run=subprocess.run([str(exe),str(stage),str(args.previous_lua.resolve())],capture_output=True,text=True)
    if not run.stdout: raise RuntimeError(run.stderr)
    report=json.loads(run.stdout); report.update(kind="actual_production_upgrader_in_disposable_macOS_file_fixtures",user_data_modified=False)
    (ROOT/"evidence/native-lua-upgrade.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(report["status"],len(report["cases"])); print(run.stderr if run.returncode else "")
    return run.returncode

if __name__=="__main__": raise SystemExit(main())
