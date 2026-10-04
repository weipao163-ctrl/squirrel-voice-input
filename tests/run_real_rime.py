#!/usr/bin/env python3
"""Execute against a real librime DLL/dylib in a fresh ASCII temporary directory.

--local-rime snapshots the scheme/dictionaries/Lua ONLY (not learning databases)
and tests rime_ice; never points librime at the original user directory.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import traceback

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from manage import install, disable, rollback
from rime_api import Rime

KEYS = {"space": 32, "Escape": 0xFF1B, "BackSpace": 0xFF08, "Return": 0xFF0D,
        "Tab": 0xFF09,
        "Page_Down": 0xFF56, "Page_Up": 0xFF55, "Down": 0xFF54, "Left": 0xFF51}


def snapshot_hashes(path):
    # Dictionaries/learning records can be huge; only hash the files this task might edit.
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(path.glob("*.custom.yaml"))}


class Harness:
    def __init__(self, rime):
        self.r = rime
        self.sid = 0
        self.steps = []

    def start(self, schema="letter_fixture"):
        if self.sid:
            self.r.destroy_session(self.sid)
        self.sid = self.r.create_session()
        assert self.sid and self.r.select_schema(self.sid, schema.encode())
        self.r.set_option(self.sid, b"ascii_mode", 0)
        self.steps = []

    def state(self):
        state = self.r.state(self.sid)
        self.steps.append({"read": state})
        assert state["error"] == "", state
        return state

    def key(self, key, mask=0):
        code = KEYS.get(key, ord(key) if len(key) == 1 else 0)
        assert code, key
        handled = bool(self.r.process_key(self.sid, code, mask))
        state = self.r.state(self.sid)
        self.steps.append({"key": key, "mask": mask, "handled": handled, "state": state})
        assert state["error"] == "", state
        return handled, state

    def type(self, text):
        for char in text:
            handled, state = self.key(char)
            assert handled and not state["commit"], state
        return state


def fixture_files(shared):
    shared.mkdir()
    for src in (ROOT / "tests" / "fixtures").glob("*"):
        shutil.copy2(src, shared / src.name)
    (shared / "default.yaml").write_text("config_version: '1'\nschema_list:\n  - schema: letter_fixture\n  - schema: letter_other\n", encoding="utf-8")
    original = (shared / "letter_fixture.schema.yaml").read_text(encoding="utf-8")
    for schema in ["letter_other", "letter_disabled", "letter_keys", "letter_enter", "letter_default"]:
        (shared / f"{schema}.schema.yaml").write_text(original.replace("schema_id: letter_fixture", f"schema_id: {schema}"), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--plugin", type=Path, action="append", default=[], help="Load an external librime plugin before initialization (macOS Lua)")
    parser.add_argument("--local-rime", type=Path)
    parser.add_argument("--shared", type=Path, help="Shared data for the local-rime snapshot")
    parser.add_argument("--report", type=Path, default=ROOT / "evidence" / "real-rime.json")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="codex-rime-letter-"))
    shared, user = work / "shared", work / "user"
    user.mkdir()
    fixture_files(shared)
    # Install requires the scheme source in its target, as on real Rime user directories.
    for src in shared.glob("*.schema.yaml"):
        shutil.copy2(src, user / src.name)
    backup = install(user, "letter_fixture", True, keys="asdfghjkl")["backup"]
    install(user, "letter_disabled", True, keys="asdfghjkl")
    install(user, "letter_default", True)
    custom = user / "letter_disabled.custom.yaml"
    custom.write_text(custom.read_text(encoding="utf-8").replace("letter_selection/enabled: true", "letter_selection/enabled: false"), encoding="utf-8")
    install(user, "letter_keys", True, keys="asdfghjkl")
    custom = user / "letter_keys.custom.yaml"
    custom.write_text(custom.read_text(encoding="utf-8").replace("asdfghjkl", "qwertyuio"), encoding="utf-8")
    install(user, "letter_enter", True, keys="asdfghjkl")
    custom = user / "letter_enter.custom.yaml"
    custom.write_text(custom.read_text(encoding="utf-8").replace("letter_selection/entry_key: space", "letter_selection/entry_key: Tab"), encoding="utf-8")
    before = snapshot_hashes(args.local_rime) if args.local_rime else {}
    local_user = work / "local-user"
    if args.local_rime:
        shutil.copytree(args.local_rime, local_user,
                        ignore=shutil.ignore_patterns("build", "*.userdb", "*.userdb.*", "*.log", "sync", ".letter-selection-backups"))
        local_install = install(local_user, "rime_ice", True, legacy=True, keys="asdfghjkl")
    report = {"utc": datetime.now(timezone.utc).isoformat(), "work": str(work),
              "library": str(args.library.resolve()), "kind": "real_librime_C_API_not_macOS_UI",
              "tests": [], "macOS_UI_tested": False}
    r = None
    h = None

    def case(name, func):
        try:
            func()
            report["tests"].append({"name": name, "status": "PASS", "steps": list(h.steps)})
            print(f"PASS {name}")
        except Exception as exc:
            report["tests"].append({"name": name, "status": "FAIL", "error": str(exc),
                                    "traceback": traceback.format_exc(), "steps": list(h.steps)})
            print(f"FAIL {name}: {exc}")

    try:
        r = Rime(args.library, shared, user, args.plugin)
        report["version"] = r.get_version().decode()
        report["lua_module"] = bool(r.find_module(b"lua"))
        assert report["lua_module"], "lua module absent"
        assert r.deploy_config_file(b"default.yaml", b"config_version")
        for schema in ["letter_fixture", "letter_other", "letter_disabled", "letter_keys", "letter_enter", "letter_default"]:
            assert r.deploy_schema(str(user / f"{schema}.schema.yaml").encode("utf-8")), schema
        h = Harness(r)

        def normal():
            h.start()
            state = h.type("nihao")
            assert state["input"] == "nihao" and state["phase"] == "editing", state
            assert not state["candidates"] and state["preedit"], state
            handled, opened = h.key("space")
            assert handled and opened["phase"] == "selecting" and opened["input"] == state["input"], opened
            assert opened["candidates"] and not opened["commit"] and opened["keys"] == "asdfghjkl", opened
            assert opened["original_keys"] == "asdfghjkl", opened
        case("normal_pinyin_and_first_space_no_commit", normal)

        def alphabet():
            h.start()
            text = "abcdefghijklmnopqrstuvwxyz"
            state = h.type(text)
            assert state["input"] == text and not state["commit"] and state["phase"] != "selecting", state
        case("all_26_letters_are_pinyin_input_before_arming", alphabet)

        def letters():
            for i, key in enumerate("asdfghjkl"):
                h.start()
                h.type("ni")
                _, opened = h.key("space")
                expected = opened["candidates"][i]
                handled, state = h.key(key)
                assert handled and state["commit"] == expected and not state["input"] and state["phase"] == "off", state
        case("all_nine_selection_letters", letters)

        def new_defaults():
            for index, key in enumerate("asdfghjkl"):
                h.start("letter_default"); state = h.type("ni")
                assert state["phase"] == "editing" and not state["commit"], state
                _, opened = h.key("space")
                assert opened["original_keys"] == "asdfghjkl" and not opened["commit"], opened
                expected = opened["candidates"][index]
                handled, state = h.key(key)
                assert handled and state["commit"] == expected and not state["input"], state
            h.start("letter_default"); h.type("ni"); h.key("space")
            _, second = h.key("Page_Down"); expected = second["candidates"][1]
            _, selected = h.key("s"); assert selected["commit"] == expected, selected
        case("goal_default_asdfghjkl_all_nine_labels_and_second_page",new_defaults)

        def confirm():
            h.start()
            h.type("ni")
            h.key("space")
            assert r.highlight_candidate_on_current_page(h.sid, 2)
            selected = h.state()
            handled, state = h.key("space")
            assert handled and state["commit"] == selected["candidates"][2], state
        case("second_space_confirms_highlight_not_first", confirm)

        def page():
            h.start()
            h.type("ni")
            h.key("space")
            handled, second = h.key("Page_Down")
            assert handled and second["page"] == 1 and second["phase"] == "selecting", second
            expected = second["candidates"][1]
            _, state = h.key("s")
            assert state["commit"] == expected, state
        case("second_page_letter_selects_second_page", page)

        def original_navigation():
            for previous, following in [("-", "="), (",", ".")]:
                h.start(); h.type("ni"); h.key("space")
                handled, second = h.key(following)
                assert handled and second["page"] == 1 and second["phase"] == "selecting", second
                assert not second["commit"] and second["original_keys"] == "asdfghjkl", second
                handled, first = h.key(previous)
                assert handled and first["page"] == 0 and first["phase"] == "selecting", first
                for _ in range(12):
                    handled, boundary = h.key("Page_Down")
                    assert handled and not boundary["commit"] and boundary["phase"] == "selecting", boundary
                assert boundary["last_page"], boundary
                expected = boundary["candidates"][0]
                _, selected = h.key("a"); assert selected["commit"] == expected, selected
        case("original_punctuation_navigation_and_last_page_boundary", original_navigation)

        def last_page():
            h.start()
            h.type("ni")
            h.key("space")
            for _ in range(10):
                _, last = h.key("Page_Down")
                if last["last_page"]:
                    break
            assert 0 < len(last["candidates"]) < 9, last
            handled, absent = h.key("l")
            assert handled and not absent["commit"] and absent["input"] == "ni", absent
            assert absent["candidates"] == last["candidates"] and absent["highlighted"] == last["highlighted"], absent
            handled, absent = h.key("9")
            assert handled and not absent["commit"] and absent["input"] == "ni", absent
            _, state = h.key("a")
            assert state["commit"] == last["candidates"][0], state
        case("last_page_missing_letters_and_numbers_consumed", last_page)

        def cancel_backspace():
            h.start()
            h.type("nihao")
            h.key("space")
            handled, state = h.key("Escape")
            assert handled and state["input"] == "nihao" and state["phase"] == "editing" and not state["commit"], state
            h.key("space")
            _, state = h.key("BackSpace")
            assert state["input"] == "niha" and state["phase"] == "editing", state
            # Editing Escape retains the scheme's original composition cancellation.
            _, state = h.key("Escape")
            assert not state["input"] and state["phase"] == "off", state
        case("escape_retains_input_and_backspace_exactly_once", cancel_backspace)

        def segmented():
            h.start()
            h.type("nihaoshijie")
            _, opened = h.key("space")
            found = None
            for _ in range(20):
                for index, text in enumerate(opened["candidates"]):
                    if text == "你":
                        found = index
                        break
                if found is not None:
                    break
                _, opened = h.key("Page_Down")
            assert found is not None, opened
            _, remainder = h.key("asdfghjkl"[found])
            assert remainder["input"] == "nihaoshijie" and not remainder["commit"] and remainder["phase"] == "selecting", remainder
            assert "你" in remainder["preedit"] and remainder["candidates"], remainder
            commits = ""
            for _ in range(10):
                _, state = h.key("space")
                commits += state["commit"]
                if not state["input"]:
                    break
            assert commits.startswith("你") and not state["input"] and state["phase"] == "off", state
        case("sentence_partial_selection_retains_and_finishes_remainder", segmented)

        def digits_mouse():
            for method in ["number", "mouse_API"]:
                h.start()
                h.type("ni")
                h.key("space")
                r.change_page(h.sid, 0)
                opened = h.state()
                expected = opened["candidates"][2]
                if method == "number":
                    _, selected = h.key("3")
                else:
                    assert r.select_candidate_on_current_page(h.sid, 2)
                    selected = h.state()
                assert selected["commit"] == expected and not selected["input"], selected
        case("numbers_and_Squirrel_mouse_selection_API", digits_mouse)

        def all_digits():
            for index in range(9):
                h.start()
                h.type("ni")
                _, opened = h.key("space")
                _, state = h.key(str(index + 1))
                assert state["commit"] == opened["candidates"][index] and not state["input"], state
        case("all_nine_number_keys_preserved", all_digits)

        def ascii_shortcut():
            h.start()
            h.type("ni")
            h.key("space")
            for mask in [4, 8, 1 << 26]:
                _, state = h.key("a", mask)
                assert not state["commit"] and state["input"] == "ni", state
            r.clear_composition(h.sid)
            r.set_option(h.sid, b"ascii_mode", 1)
            handled, state = h.key("a")
            assert not handled and not state["input"] and state["phase"] == "off", state
            r.set_option(h.sid, b"ascii_mode", 0)
            state = h.type("ni")
            assert state["phase"] == "editing", state
        case("ascii_and_ctrl_alt_super_do_not_select", ascii_shortcut)

        def state_cleanup():
            h.start()
            h.type("ni")
            h.key("space")
            r.set_property(h.sid, b"_letter_selection_reset", b"1")
            assert h.state()["phase"] != "selecting"
            h.key("space")
            r.set_caret_pos(h.sid, 1)
            assert h.state()["phase"] != "selecting"
            r.clear_composition(h.sid)
            assert h.state()["phase"] == "off"
            h.type("ni")
            h.key("space")
            assert r.select_schema(h.sid, b"letter_other")
            assert h.state()["phase"] == "off"
            h.start()
            assert h.type("ni")["phase"] == "editing"
        case("reset_property_caret_clear_schema_session_cleanup", state_cleanup)

        def disabled_keys():
            h.start("letter_disabled")
            state = h.type("ni")
            assert state["phase"] == "off" and state["original_labels"][0] == "①", state
            _, state = h.key("space")
            assert state["commit"], state
            h.start("letter_keys")
            h.type("ni")
            _, opened = h.key("space")
            assert opened["keys"] == "qwertyuio", opened
            _, state = h.key("w")
            assert state["commit"] == opened["candidates"][1], state
        case("config_disable_original_labels_and_custom_keys", disabled_keys)

        def custom_entry():
            h.start("letter_enter")
            h.type("ni")
            handled, opened = h.key("Tab")
            assert handled and opened["phase"] == "selecting" and not opened["commit"], opened
            _, state = h.key("a")
            assert state["commit"] == opened["candidates"][0], state
        case("configurable_Tab_entry_key", custom_entry)

        def runtime_off():
            h.start()
            h.type("ni")
            h.key("space")
            r.set_option(h.sid, b"letter_selection_disabled", 1)
            off = h.state()
            assert off["phase"] == "off" and off["original_keys"] == "" and off["original_labels"][0] == "①", off
            assert off["candidates"] and not r.get_option(h.sid, b"_hide_candidate"), off
            _, state = h.key("space")
            assert state["commit"], state
            r.set_option(h.sid, b"letter_selection_disabled", 0)
            assert h.type("ni")["phase"] == "editing"
        case("runtime_off_restores_original_labels_and_visibility", runtime_off)

        def independent_sessions():
            h.start()
            h.type("ni")
            _, opened = h.key("space")
            other = Harness(r)
            other.start()
            try:
                other.type("ni")
                second = other.state()
                assert second["phase"] == "editing" and not second["candidates"] and second["original_keys"] == "", second
                first = h.state()
                assert first["phase"] == "selecting" and first["original_keys"] == "asdfghjkl", first
                other.key("space")
                r.set_option(other.sid, b"letter_selection_disabled", 1)
                second = other.state()
                assert second["original_labels"][0] == "①" and second["original_keys"] == "", second
                assert h.state()["original_keys"] == "asdfghjkl"
                _, state = h.key("a")
                assert state["commit"] == opened["candidates"][0], state
            finally:
                r.destroy_session(other.sid)
        case("two_same_schema_sessions_have_independent_states_and_labels", independent_sessions)

        def mouse_partial():
            h.start()
            h.type("nihao")
            _, opened = h.key("space")
            index = opened["candidates"].index("你")
            assert r.select_candidate_on_current_page(h.sid, index)
            remainder = h.state()
            assert not remainder["commit"] and remainder["input"] == "nihao" and remainder["phase"] == "selecting", remainder
            assert remainder["original_keys"] == "asdfghjkl", remainder
            _, state = h.key("space")
            assert state["commit"].startswith("你") and not state["input"], state
        case("mouse_selection_API_preserves_sentence_remainder", mouse_partial)

        def learning():
            h.start()
            h.type("ni")
            _, opened = h.key("space")
            target, original_rank = opened["candidates"][8], 8
            _, state = h.key("l")
            assert state["commit"] == target, state
            for _ in range(4):
                h.type("ni")
                _, opened = h.key("space")
                for _ in range(4):
                    if target in opened["candidates"]:
                        break
                    _, opened = h.key("Page_Down")
                index = opened["candidates"].index(target)
                _, state = h.key("asdfghjkl"[index])
                assert state["commit"] == target, state
            h.type("ni")
            _, opened = h.key("space")
            new_rank = opened["candidates"].index(target) if target in opened["candidates"] else 99
            report["learning_observation"] = {"selected_word": target, "original_rank": original_rank,
                                              "new_rank": new_rank, "commits": 5,
                                              "userdb_created": (user / "letter_fixture.userdb").exists()}
            assert new_rank < original_rank and report["learning_observation"]["userdb_created"], opened
        case("native_selection_learns_word_frequency", learning)

        def rollback_test():
            disable(user, backup, True)
            assert not (user / "letter_fixture.custom.yaml").exists()
            assert r.deploy_schema(str(user / "letter_fixture.schema.yaml").encode("utf-8"))
            h.start()
            state = h.type("ni")
            assert state["phase"] in ["", "off"] and state["size"] == 5, state
            _, state = h.key("space")
            assert state["commit"], state
            rollback(user, backup, True)
            # The Lua file is shared with the two test schemas, but byte hashes are identical.
            assert not (user / "lua" / "letter_selection.lua").exists()
        case("disable_restore_page_size_and_uninstall", rollback_test)

        if h.sid:
            r.destroy_session(h.sid)
        r.finalize()
        r = None

        if "learning_observation" in report:
            r = Rime(args.library, shared, user, args.plugin)
            h = Harness(r)
            def learning_reload():
                h.start()
                state = h.type("ni")
                assert state["candidates"][0] == report["learning_observation"]["selected_word"], state
                report["learning_observation"]["verified_after_Rime_finalize_and_initialize"] = True
            case("word_frequency_survives_Rime_finalize_and_reload", learning_reload)
            r.destroy_session(h.sid)
            r.finalize()
            r = None

        if args.local_rime:
            r = Rime(args.library, args.shared or shared, local_user, args.plugin)
            assert r.deploy_config_file(b"default.yaml", b"config_version")
            for dependency in ["melt_eng", "radical_pinyin", "quick_single_char", "rime_ice_quick_completion"]:
                assert r.deploy_schema(str(local_user / f"{dependency}.schema.yaml").encode("utf-8")), dependency
            assert r.deploy_schema(str(local_user / "rime_ice.schema.yaml").encode("utf-8"))
            h = Harness(r)

            def local_normal():
                h.start("rime_ice")
                state = h.type("nihao")
                assert state["phase"] == "editing", state
                _, state = h.key("space")
                assert state["phase"] == "selecting" and not state["commit"] and state["input"] == "nihao", state
                _, state = h.key("a")
                assert state["commit"] and not state["input"], state
            case("rime_ice_snapshot_end_to_end", local_normal)

            def local_restore():
                h.start("rime_ice")
                h.type("ni")
                _, opened = h.key("space")
                assert opened["original_keys"] == "asdfghjkl" and opened["label_backend"] == "schema_select_keys", opened
                h.key("Escape")
                r.set_option(h.sid, b"letter_selection_disabled", 1)
                restored = h.state()
                assert restored["original_keys"] == "abcdefghi" and restored["original_labels"][:3] == ["a", "b", "c"], restored
                assert restored["candidates"] and restored["phase"] == "off", restored
            case("rime_ice_original_alternative_keys_and_labels_restored", local_restore)

            def local_special():
                for text in ["rq", "nl", "uuid", "vfh", "uUmu"]:
                    h.start("rime_ice")
                    state = h.type(text)
                    assert state["phase"] == "off", state
                    _, state = h.key("space")
                    assert state["phase"] != "selecting", state
            case("rime_ice_date_lunar_uuid_symbols_reverse_lookup_passthrough", local_special)

            report["local_configuration_unchanged"] = before == snapshot_hashes(args.local_rime)
            assert report["local_configuration_unchanged"]
            report["local_backup"] = local_install["backup"]
    except Exception:
        report["fatal"] = traceback.format_exc()
        print(report["fatal"])
    finally:
        if r:
            if h and h.sid:
                r.destroy_session(h.sid)
            r.finalize()
        report["passed"] = sum(t["status"] == "PASS" for t in report["tests"])
        report["failed"] = sum(t["status"] == "FAIL" for t in report["tests"]) + int("fatal" in report)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        if (user / "logs").exists():
            shutil.copytree(user / "logs", args.report.parent / "rime-logs", dirs_exist_ok=True)
        print(f"Report {args.report.resolve()}: {report['passed']} passed, {report['failed']} failed")
    return int(report["failed"] != 0)


if __name__ == "__main__":
    sys.exit(main())
