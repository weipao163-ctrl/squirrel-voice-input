"""Compile Foundation/POSIX launch admission and fake lifecycle hooks only."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    evidence = ROOT / "evidence"
    evidence.mkdir(exist_ok=True)
    work_root = ROOT / "test-work"
    work_root.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="launch-admission-", dir=work_root))
    production = ROOT / "enhanced-squirrel/sources/LaunchAdmission.swift"
    entry = ROOT / "enhanced-squirrel/sources/Main.swift"
    delegate = ROOT / "enhanced-squirrel/sources/SquirrelApplicationDelegate.swift"
    probe = ROOT / "tools/NativeLaunchAdmissionProbe.swift"
    binary = work / "LaunchAdmissionProbe"
    build = subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", str(production), str(probe),
                            "-o", str(binary)], capture_output=True, text=True, timeout=120)
    (evidence / "launch-admission-probe.compile.txt").write_text(build.stdout + build.stderr)
    if build.returncode:
        print(build.stderr)
        return build.returncode
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    (evidence / "launch-admission-probe.console.txt").write_text(run.stdout + run.stderr)
    marker = "LAUNCH_ADMISSION_PROBE_REPORT="
    if marker not in run.stdout:
        print(run.stdout + run.stderr)
        return run.returncode or 1
    report = json.loads(run.stdout.split(marker)[-1])
    entry_text, delegate_text = entry.read_text(), delegate.read_text()
    build_branch = entry_text.split('case "--build":', 1)[1].split('case "--sync":', 1)[0]
    report["checks"].update({
        "main_rejects_unknown_before_cli_dispatch": entry_text.index("guard action != .rejected") < entry_text.index("let handled = autoreleasepool"),
        "settings_forwarding_requires_installed_owner": "LaunchAdmission.isInstalledBundle($0, home: LaunchAdmission.homeDirectory)" in entry_text,
        "main_uses_injected_service_boundary": "try LaunchAdmission.runService(" in entry_text,
        "delegate_explicitly_retained_through_run": "withExtendedLifetime(delegate) { app.run() }" in entry_text,
        "legacy_timestamp_gate_removed": "problematicLaunchDetected" not in entry_text + delegate_text and "squirrel_enhanced_dev_launch.json" not in entry_text + delegate_text,
        "no_spoken_startup_failure": '"/usr/bin/say"' not in entry_text,
        "offline_build_checks_legacy_owner_before_lease": build_branch.index("guard !hasInstalledServiceOwner()") < build_branch.index("try LaunchAdmission.withEngineLease("),
        "offline_build_lease_precedes_user_data_and_engine": build_branch.index("try LaunchAdmission.withEngineLease(") < build_branch.index("try prepareUserDirectory()") < build_branch.index("rimeAPI.setup("),
        "offline_build_finalizes_engine_within_lease": "defer { rimeAPI.finalize() }" in build_branch,
    })
    report.update(status="PASS" if all(report["checks"].values()) else "FAIL",
                  utc=datetime.now(timezone.utc).isoformat(), exit_code=run.returncode,
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [production, entry, delegate, probe, Path(__file__)]})
    (evidence / "launch-admission-probe.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return run.returncode or int(report["status"] != "PASS")


if __name__ == "__main__":
    raise SystemExit(main())
