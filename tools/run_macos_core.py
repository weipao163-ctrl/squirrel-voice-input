#!/usr/bin/env python3
"""Run the existing Core test bodies with Apple's Swift Testing when CLT lacks XCTest.

Copies production Core and unchanged assertions into a fresh temporary package.
Only discovery/imports/base class are adapted; no test is removed or skipped.
Assertion compatibility functions report failures to the real Testing runtime.
This is Swift Testing evidence, never described as native XCTest or IMK testing.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
COMPAT = r'''
import Foundation
import Testing
private func location(_ id:String,_ path:String,_ line:Int)->SourceLocation {
  SourceLocation(fileID:id,filePath:path,line:line,column:1)
}
func XCTFail(_ message:String = "Assertion failed",file:String = #fileID,path:String = #filePath,line:Int = #line) {
  Issue.record(Comment(rawValue:message),sourceLocation:location(file,path,line))
}
func XCTAssertTrue(_ value:@autoclosure () throws -> Bool,_ message:String = "",file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try !value() { XCTFail("Expected true. " + message,file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertFalse(_ value:@autoclosure () throws -> Bool,_ message:String = "",file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try value() { XCTFail("Expected false. " + message,file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertEqual<T:Equatable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,_ message:String = "",file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  let left=try a(),right=try b()
  if left != right { XCTFail("Expected equality: \(left) != \(right). " + message,file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertEqual(_ a:@autoclosure () throws -> Double,_ b:@autoclosure () throws -> Double,accuracy:Double,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  let left=try a(),right=try b()
  if !(abs(left-right) <= accuracy) { XCTFail("Values differ beyond \(accuracy).",file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertNotEqual<T:Equatable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try a() == b() { XCTFail("Expected inequality.",file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertNil<T>(_ a:@autoclosure () throws -> T?,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try a() != nil { XCTFail("Expected nil.",file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertNotNil<T>(_ a:@autoclosure () throws -> T?,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try a() == nil { XCTFail("Expected non-nil.",file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertGreaterThan<T:Comparable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try !(a() > b()) { XCTFail("Expected greater than.",file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertLessThan<T:Comparable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try !(a() < b()) { XCTFail("Expected less than.",file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertLessThanOrEqual<T:Comparable>(_ a:@autoclosure () throws -> T,_ b:@autoclosure () throws -> T,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do {
  if try !(a() <= b()) { XCTFail("Expected less than or equal.",file:file,path:path,line:line) }
  } catch { XCTFail("Unexpected evaluation error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertNoThrow<T>(_ expression:@autoclosure () throws -> T,file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do { _ = try expression() } catch { XCTFail("Unexpected error: \(error)",file:file,path:path,line:line) }
}
func XCTAssertThrowsError<T>(_ expression:@autoclosure () throws -> T,_ handler:(Error)->Void = {_ in},file:String = #fileID,path:String = #filePath,line:Int = #line) {
  do { _ = try expression(); XCTFail("Expected an error.",file:file,path:path,line:line) } catch { handler(error) }
}
private enum UnwrapFailure:Error { case missing }
func XCTUnwrap<T>(_ expression:@autoclosure () throws -> T?,file:String = #fileID,path:String = #filePath,line:Int = #line) throws -> T {
  if let value=try expression() { return value }
  XCTFail("Unwrap failed.",file:file,path:path,line:line); throw UnwrapFailure.missing
}
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--sdk', type=Path, default=Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()))
    ap.add_argument('--report', type=Path, default=ROOT / 'evidence/macos-core.json')
    args = ap.parse_args()
    source = ROOT / 'enhanced-squirrel/Enhancements'
    work = Path(tempfile.mkdtemp(prefix='squirrel-macos-core-'))
    shutil.copytree(source / 'Sources/EnhancementCore', work / 'Sources/EnhancementCore')
    original = source / 'Tests/EnhancementCoreTests/CoreTests.swift'
    text = original.read_text()
    names = re.findall(r'  func (test\w+)\(', text)
    adapted = text.replace('import XCTest', 'import Foundation\nimport Testing', 1).replace(
        'final class CoreTests:XCTestCase', '@Suite(.serialized) struct CoreTests', 1)
    adapted = re.sub(r'(?m)^(  func test\w+\()', r'  @Test\n\1', adapted)
    # Check the transformation reverses exactly: no weakened or dropped body.
    reversed_text = adapted.replace('import Foundation\nimport Testing', 'import XCTest', 1).replace(
        '@Suite(.serialized) struct CoreTests', 'final class CoreTests:XCTestCase', 1).replace('  @Test\n', '')
    assert reversed_text == text and len(names) == len(set(names))
    tests = work / 'Tests/EnhancementCoreTests'
    tests.mkdir(parents=True)
    (tests / 'CoreTests.swift').write_text(adapted)
    (tests / 'AssertionCompatibility.swift').write_text(COMPAT)
    shutil.copytree(original.parent / 'Fixtures', tests / 'Fixtures')
    (work / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"MacCoreVerification",platforms:[.macOS(.v13)],
 targets:[.target(name:"EnhancementCore"),.testTarget(name:"EnhancementCoreTests",
 dependencies:["EnhancementCore"],resources:[.process("Fixtures")])],swiftLanguageModes:[.v5])
''')
    command = ['swift', 'test', '--package-path', str(work), '--build-system', 'native',
               '--sdk', str(args.sdk), '--disable-xctest', '-j', '4',
               '-Xswiftc', '-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks',
               '-Xlinker', '-rpath', '-Xlinker', '/Library/Developer/CommandLineTools/Library/Developer/Frameworks']
    run = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace', timeout=600)
    output = run.stdout + '\n' + run.stderr
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.with_suffix('.console.txt').write_text(output)
    passed = re.findall(r'Test (test\w+)\(\) passed', output)
    report = {'utc':datetime.now(timezone.utc).isoformat(), 'layer':'real Apple Swift Testing; unchanged Core XCTest bodies through assertion adapter; NOT XCTest, microphone, IMK or cloud',
              'argv':command,'exit_code':run.returncode,'work':str(work),'written_tests':len(names),
              'passed_tests':passed,'all_test_bodies_preserved':True,
              'source_sha256':hashlib.sha256(original.read_bytes()).hexdigest(),
              'production_source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in [*sorted((source/'Sources/EnhancementCore').glob('*.swift')),original,*sorted((original.parent/'Fixtures').glob('*'))]},
              'status':'PASS' if run.returncode == 0 and len(passed) == len(names) and set(passed) == set(names) else 'FAIL'}
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['status','exit_code','written_tests','all_test_bodies_preserved']},indent=2))
    print(output[-4500:] if report['status'] != 'PASS' else f'{len(passed)} tests passed; report {args.report}')
    return int(report['status'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
