"""Real installed librime regression in NEW fixture data; no live input/data writes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from rime_api import Rime

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", type=Path, default=ROOT / "lua/letter_selection.lua")
    parser.add_argument("--report", type=Path, default=ROOT / "evidence/digit-input-regression.json")
    parser.add_argument("--local-rime", type=Path)
    args = parser.parse_args()
    (ROOT / "test-work").mkdir(exist_ok=True)
    installed = Path.home() / "Library/Input Methods/SquirrelEnhancedDev.app/Contents"
    work = Path(tempfile.mkdtemp(prefix="digit-regression-", dir=ROOT / "test-work"))
    shared, user = work / "shared", work / "user"
    shared.mkdir(); user.mkdir(); (user / "lua").mkdir()
    for src in (ROOT / "tests/fixtures").glob("*.yaml"):
        shutil.copy2(src, shared / src.name)
    (shared / "default.yaml").write_text("config_version: '1'\nschema_list:\n  - schema: letter_fixture\n")
    if args.local_rime:
        shutil.copytree(args.local_rime, user, dirs_exist_ok=True,
            ignore=shutil.ignore_patterns("build", "*.userdb*", "*.log", "sync", ".enhancement-*", ".letter-selection-backups"))
        shutil.copytree(installed / "SharedSupport", shared, dirs_exist_ok=True)
    shutil.copy2(args.lua, user / "lua/letter_selection.lua")
    shutil.copy2(shared / "letter_fixture.schema.yaml", user / "letter_fixture.schema.yaml")
    (user / "letter_fixture.custom.yaml").write_text("patch:\n  engine/processors/@before 0: lua_processor@*letter_selection\n  menu/page_size: 9\n  letter_selection/keys: abcdefghi\n  letter_selection/hide_candidates: true\n")
    r = Rime(installed / "Frameworks/librime.1.dylib", shared, user,
        [installed / "Frameworks/rime-plugins/librime-lua.dylib"])
    rows = []; sid = 0; steps = []
    def start(schema="letter_fixture"):
        nonlocal sid, steps
        if sid: r.clear_composition(sid); r.destroy_session(sid)
        sid = r.create_session(); assert r.select_schema(sid, schema.encode())
        r.set_option(sid, b"ascii_mode", 0); steps = []
    def key(code, mask=0):
        if isinstance(code, str): code = ord(code)
        handled = bool(r.process_key(sid, code, mask)); state = r.state(sid)
        steps.append({"code": code, "mask": mask, "handled": handled, "state": state})
        assert not state["error"], state
        return handled, state
    def typing(text):
        for ch in text:
            handled, state = key(ch); assert handled and not state["commit"], state
        return state
    def case(name, body):
        try: body(); rows.append({"name": name, "status": "PASS", "steps": list(steps)})
        except Exception as e: rows.append({"name": name, "status": "FAIL", "error": str(e), "steps": list(steps)})
        print(rows[-1]["status"], name, flush=True)
    try:
        assert r.deploy_schema(str(user / "letter_fixture.schema.yaml").encode())
        if args.local_rime: assert r.deploy_schema(str(user / "rime_ice.schema.yaml").encode())
        schemas = ["letter_fixture"] + (["rime_ice"] if args.local_rime else [])
        for schema in schemas:
            for digit in "0123456789":
                for showing in (False, True):
                    def digits(schema=schema, digit=digit, showing=showing):
                        start(schema); typing("nihao")
                        if showing: assert key(" ")[1]["phase"] == "selecting"
                        handled, state = key(digit)
                        assert handled and not state["commit"] and state["input"] == "nihao" + digit, state
                        assert state["phase"] != "selecting", state
                    case(f"{schema}_digit_{digit}_{'selecting' if showing else 'editing'}", digits)
            for text in ("lovewin2k", "abc123def456", "win0x64", "nihao2k"):
                def mixed(text=text, schema=schema):
                    start(schema); state = typing(text)
                    assert state["input"] == text, state
                    handled, state = key(0xff0d)
                    assert handled and state["commit"] == text and not state["input"], state
                case(f"{schema}_mixed_{text}", mixed)
            def edit(schema=schema):
                start(schema); typing("ab2c"); r.set_caret_pos(sid, 2)
                _, state = key("3"); assert state["input"] == "ab32c" and not state["commit"], state
                _, state = key(0xff08); assert state["input"] == "ab2c" and not state["commit"], state
                r.set_caret_pos(sid, 4)
                _, state = key(0xff0d); assert state["commit"] == "ab2c", state
            case(f"{schema}_caret_insert_delete", edit)
            def cancel(schema=schema):
                start(schema); typing("ab2c"); _, state = key(0xff1b)
                assert not state["input"] and not state["commit"], state
                state = typing("nihao"); assert state["phase"] == "editing", state
                _, opened = key(" "); assert opened["phase"] == "selecting", opened
            case(f"{schema}_cancel_and_resume_pinyin", cancel)
            def shortcut(schema=schema):
                start(schema); typing("nihao"); _, before = key(" ")
                handled, state = key("2", 4)
                assert state["phase"] != "literal", state
            case(f"{schema}_control_digit_not_literal", shortcut)
            def keypad(schema=schema):
                start(schema); typing("ni"); _,state=key(0xffb2)
                assert state["input"]=="ni2" and not state["commit"], state
                _,state=key("2"); assert state["input"]=="ni22" and not state["commit"],state
            case(f"{schema}_keypad_and_number_repeat",keypad)
            def space(schema=schema):
                start(schema); typing("lovewin2k"); _,state=key(" ")
                assert state["commit"]=="lovewin2k " and not state["input"],state
            case(f"{schema}_literal_space_boundary",space)
            def partial(schema=schema):
                start(schema); typing("nihaoshijie"); _,opened=key(" ")
                for _ in range(30):
                    if "你好" in opened["candidates"]: break
                    _,opened=key(0xff56)
                assert "你好" in opened["candidates"], opened
                index=opened["candidates"].index("你好")
                _,chosen=key(opened["original_keys"][index])
                assert not chosen["commit"] and chosen["input"]=="nihaoshijie",chosen
                key("2"); key("k"); _,state=key(0xff0d)
                assert state["commit"]=="你好shijie2k" and not state["input"],state
            case(f"{schema}_confirmed_prefix_and_literal_suffix",partial)
            def disabled(schema=schema):
                start(schema); r.set_option(sid, b"letter_selection_disabled", 1)
                state = typing("ni"); assert state["candidates"], state
                _, result = key("1"); assert result["commit"] == state["candidates"][0], result
            case(f"{schema}_disabled_keeps_native_numeric_selection", disabled)
        report = {"status": "PASS" if all(v["status"] == "PASS" for v in rows) else "FAIL",
            "kind": "real_librime_C_API_isolated_data", "version": r.get_version().decode(),
            "lua_sha256": hashlib.sha256(args.lua.read_bytes()).hexdigest(), "work": str(work),
            "local_user_directory_read_only": bool(args.local_rime), "macOS_UI_tested": False,
            "microphone_used": False, "cloud_calls": 0, "tests": rows}
        args.report.parent.mkdir(exist_ok=True, parents=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        return int(report["status"] != "PASS")
    finally:
        if sid: r.clear_composition(sid); r.destroy_session(sid)
        r.finalize()

if __name__ == "__main__": raise SystemExit(main())
