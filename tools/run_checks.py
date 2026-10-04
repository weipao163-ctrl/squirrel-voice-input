#!/usr/bin/env python3
"""Run unit/real-Rime checks; write UTF-8 logs and JSON without shell redirection."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, help="Omit to run only unit tests")
    parser.add_argument("--plugin", type=Path, action="append", default=[])
    parser.add_argument("--local-rime", type=Path)
    parser.add_argument("--shared", type=Path)
    parser.add_argument("--installer-bash", type=Path, help="Run the isolated shared installer file transaction tests; not native installation")
    args = parser.parse_args()
    runs = [("unit", [sys.executable, str(ROOT / "tests" / "test_letter_selection.py")], "unit-test-console.txt")]
    if args.installer_bash:
        runs.append(("app_install_transaction", [sys.executable, str(ROOT/'tests/test_app_install_transaction.py'), '--bash', str(args.installer_bash)], 'app-install-transaction-console.txt'))
    if args.library:
        command = [sys.executable, str(ROOT / "tests" / "run_real_rime.py"), "--library", str(args.library)]
        for plugin in args.plugin:
            command.extend(["--plugin", str(plugin)])
        if args.local_rime:
            command.extend(["--local-rime", str(args.local_rime)])
        if args.shared:
            command.extend(["--shared", str(args.shared)])
        runs.append(("real_rime", command, "real-rime-console.txt"))
        recipe_command=[sys.executable,str(ROOT/'tests/test_native_patch_recipes.py'),"--library",str(args.library)]
        for plugin in args.plugin: recipe_command.extend(["--plugin",str(plugin)])
        runs.append(("native_golden_recipes",recipe_command,"native-patch-recipes-console.txt"))
    report = {"utc": datetime.now(timezone.utc).isoformat(), "commands": [], "macOS_UI_tested": False}
    evidence = ROOT / "evidence"
    evidence.mkdir(exist_ok=True)
    for name, command, log in runs:
        run = subprocess.run(command, cwd=ROOT, capture_output=True, encoding="utf-8", errors="replace")
        (evidence / log).write_text(run.stdout + "\n--- STDERR ---\n" + run.stderr, encoding="utf-8")
        report["commands"].append({"name": name, "argv": command, "exit_code": run.returncode, "log": log})
        print(f"{name}: exit_code={run.returncode}")
        if run.returncode:
            print((run.stdout + run.stderr)[-6000:])
    report["implementation_sha256"] = {
        str(path.relative_to(ROOT)).replace("\\", "/"): hashlib.sha256(path.read_bytes()).hexdigest()
        for folder in ["lua", "config", "tests", "tools"]
        for path in sorted((ROOT / folder).glob("*")) if path.is_file() and path.suffix in [".lua", ".py", ".yaml"]}
    (evidence / "checks.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return int(any(run["exit_code"] for run in report["commands"]))


if __name__ == "__main__":
    sys.exit(main())
