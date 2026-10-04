import io
import json
from pathlib import Path
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from lupa import LuaRuntime
from manage import install, disable, rollback, rollback_owned, validate_target, yaml_reader


class LuaTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / "tests" / "mock_rime.lua").read_text(encoding="utf-8"))
        self.module = self.lua.execute((ROOT / "lua" / "letter_selection.lua").read_text(encoding="utf-8"))
        self.make()

    def make(self, **kwargs):
        use_default = kwargs.pop("use_default_keys", False)
        if not use_default:
            # Preserve regression coverage for the original configurable asdf keys.
            kwargs["config"] = {"letter_selection/keys": "asdfghjkl", **kwargs.get("config", {})}
        opts = self.lua.table_from(kwargs, recursive=True)
        self.env = self.lua.globals().make_env(opts)
        self.ctx = self.env.engine.context
        self.module.init(self.env)

    def phase(self):
        return self.ctx.properties["_letter_selection_phase"]

    def key(self, key, **mods):
        event = self.lua.globals().KeyEvent(key, self.lua.table_from(mods))
        return self.module.func(event, self.env)

    def test_all_letters_no_selection_before_space(self):
        for letter in "abcdefghijklmnopqrstuvwxyz":
            self.assertEqual(2, self.key(letter))
        self.assertEqual(0, self.ctx.select_calls)
        self.assertEqual(0, self.ctx.push_calls)

    def test_goal_default_asdfghjkl_selects_all_nine_positions(self):
        for index, letter in enumerate("asdfghjkl"):
            self.make(use_default_keys=True)
            self.assertEqual(2,self.key(letter))
            self.assertEqual(0,self.ctx.select_calls)
            self.key("space")
            self.assertEqual("asdfghjkl",self.env.engine.schema.select_keys)
            self.assertEqual(1,self.key(letter))
            self.assertEqual(index,self.ctx.selected[1])

    def test_initial_internal_menu_is_not_armed(self):
        self.assertTrue(self.ctx.has_menu(self.ctx))
        self.assertEqual("editing", self.phase())
        self.assertFalse(self.env.armed)
        self.assertTrue(self.ctx.options["_hide_candidate"])

    def test_optional_visible_editing_menu_is_still_not_armed(self):
        self.make(config={"letter_selection/hide_candidates": False})
        self.assertFalse(self.ctx.options["_hide_candidate"])
        self.assertEqual(2, self.key("a"))
        self.assertEqual(0, self.ctx.select_calls)

    def test_first_space_keeps_input_caret_and_commit_empty(self):
        self.assertEqual(1, self.key("space"))
        self.assertEqual("selecting", self.phase())
        self.assertEqual("ni", self.ctx.input)
        self.assertEqual(2, self.ctx.caret_pos)
        self.assertEqual(0, len(self.ctx.commits))
        self.assertFalse(self.ctx.options["_hide_candidate"])
        self.assertEqual("asdfghjkl", self.env.engine.schema.select_keys)

    def test_all_nine_letters_select_correct_index(self):
        for index, letter in enumerate("asdfghjkl"):
            self.make()
            self.key("space")
            self.assertEqual(1, self.key(letter))
            self.assertEqual(index, self.ctx.selected[1])
            self.assertEqual("off", self.phase())

    def test_space_confirms_highlight(self):
        self.key("space")
        self.ctx.seg.selected_index = 4
        self.assertEqual(1, self.key("space"))
        self.assertEqual(1, self.ctx.confirm_calls)
        self.assertEqual(4, self.ctx.selected[1])

    def test_second_page_positions(self):
        self.key("space")
        self.ctx.seg.selected_index = 11
        self.key("s")
        self.assertEqual(10, self.ctx.selected[1])

    def test_missing_item_consumed_no_selection_no_leak(self):
        self.key("space")
        self.ctx.seg.selected_index = 18
        self.ctx.candidate_count = 20
        for letter in "dfghjkl3456789":
            self.assertEqual(1, self.key(letter))
            self.assertEqual(0, len(self.ctx.selected))
            self.assertEqual("ni", self.ctx.input)
            self.assertEqual("selecting", self.phase())

    def test_partial_native_selection_stays_armed(self):
        self.ctx.edit(self.ctx, "nihao")
        self.key("space")
        self.ctx.partial = True
        self.key("s")
        self.assertEqual("nihao", self.ctx.input)
        self.assertEqual("selecting", self.phase())
        self.assertEqual(0, len(self.ctx.commits))
        self.key("a")
        self.assertEqual("off", self.phase())

    def test_mouse_native_select_continues_partial(self):
        self.ctx.edit(self.ctx, "nihao")
        self.key("space")
        self.ctx.partial = True
        self.ctx.select(self.ctx, 2)
        self.assertEqual("selecting", self.phase())

    def test_digits_select(self):
        self.key("space")
        self.key("3")
        self.assertEqual(2, self.ctx.selected[1])

    def test_escape_consumed_preserves_input(self):
        self.key("space")
        self.assertEqual(1, self.key("Escape"))
        self.assertEqual("editing", self.phase())
        self.assertEqual("ni", self.ctx.input)
        self.assertEqual(2, self.key("Escape"))

    def test_backspace_passes_once_and_disarms(self):
        self.key("space")
        self.assertEqual(2, self.key("BackSpace"))
        self.assertEqual("editing", self.phase())
        self.assertEqual("ni", self.ctx.input)  # original editor performs the deletion

    def test_modified_letters_and_releases_passthrough(self):
        self.key("space")
        for mask in ["ctrl", "alt", "super", "release"]:
            self.assertEqual(2, self.key("a", **{mask: True}))
        self.assertEqual(0, self.ctx.select_calls)

    def test_paging_passes_to_original_selector(self):
        self.key("space")
        self.assertEqual(2, self.key("Page_Down"))
        self.assertEqual("selecting", self.phase())

    def test_ascii_switch_resets(self):
        self.key("space")
        self.ctx.set_option(self.ctx, "ascii_mode", True)
        self.assertEqual("off", self.phase())
        self.assertEqual(2, self.key("a"))
        self.ctx.set_option(self.ctx, "ascii_mode", False)
        self.assertEqual("editing", self.phase())

    def test_runtime_disable_restores_keys_and_visibility(self):
        self.make(select_keys="abcdefghi")
        self.key("space")
        self.ctx.set_option(self.ctx, "letter_selection_disabled", True)
        self.assertEqual("off", self.phase())
        self.assertEqual("abcdefghi", self.env.engine.schema.select_keys)
        self.assertFalse(self.ctx.options["_hide_candidate"])
        self.assertEqual(2, self.key("space"))

    def test_config_disabled_no_interception(self):
        self.make(config={"letter_selection/enabled": False})
        self.assertEqual("off", self.phase())
        self.assertEqual(2, self.key("space"))
        self.assertFalse(self.ctx.options["_hide_candidate"])

    def test_commit_and_clear_clean_state(self):
        self.key("space")
        self.ctx.clear(self.ctx)
        self.assertEqual("off", self.phase())
        self.ctx.edit(self.ctx, "ni")
        self.assertEqual("editing", self.phase())

    def test_external_reset_preserves_input(self):
        self.key("space")
        self.ctx.set_property(self.ctx, "_letter_selection_reset", "next_focus")
        self.assertEqual("editing", self.phase())
        self.assertEqual("ni", self.ctx.input)

    def test_caret_mutation_resets(self):
        self.key("space")
        self.ctx.caret_pos = 1
        self.ctx.update_notifier.emit(self.ctx.update_notifier, self.ctx)
        self.assertEqual("editing", self.phase())

    def test_unmapped_letter_resumes_editing(self):
        self.key("space")
        self.assertEqual(2, self.key("q"))
        self.assertEqual("editing", self.phase())

    def test_special_tags_types_and_punctuation_bypass(self):
        self.ctx.seg.tags.abc = False
        self.assertEqual(2, self.key("space"))
        self.assertEqual("off", self.phase())
        self.make(config={"letter_selection/excluded_candidate_types": ["calc"]})
        self.ctx.seg.candidate_type = "calc"
        self.assertEqual(2, self.key("space"))

    def test_schema_triggers_bypass(self):
        for path, text in [("lunar", "nl"), ("uuid", "uuid"), ("date_translator/date", "rq")]:
            self.make(input=text, caret=len(text), config={path: text})
            self.assertEqual("off", self.phase())
            self.assertEqual(2, self.key("space"))

    def test_passthrough_patterns(self):
        self.make(input="vfh", config={"letter_selection/passthrough_patterns": ["^v"]})
        self.assertEqual("off", self.phase())
        self.assertEqual(2, self.key("space"))

    def test_custom_keys_and_entry_key(self):
        self.make(config={"letter_selection/keys": "qwertyuio", "letter_selection/entry_key": "Tab"})
        self.assertEqual(2, self.key("space"))
        self.assertEqual(1, self.key("Tab"))
        self.key("w")
        self.assertEqual(1, self.ctx.selected[1])

    def test_invalid_keys_patterns_and_chords_fail_safe(self):
        for cfg in [{"letter_selection/keys": "aaaaaaaaa"}, {"letter_selection/keys": "abc"},
                    {"letter_selection/passthrough_patterns": ["["]},
                    {"letter_selection/entry_key": "Control+space"},
                    {"letter_selection/confirm_key": "1"},
                    {"letter_selection/entry_key": "a"},
                    {"letter_selection/entry_key": "NoSuchKey"}]:
            self.make(config=cfg)
            self.assertEqual("off", self.phase())
            self.assertTrue(self.ctx.properties["_letter_selection_error"])
            self.assertEqual(2, self.key("space"))

    def test_original_hidden_option_restored(self):
        self.make(original_hide=True)
        self.key("space")
        self.assertFalse(self.ctx.options["_hide_candidate"])
        self.ctx.set_option(self.ctx, "letter_selection_disabled", True)
        self.assertTrue(self.ctx.options["_hide_candidate"])

    def test_other_hide_owner_wins_and_is_restored(self):
        self.key("space")
        self.ctx.set_option(self.ctx, "letter_selection_external_hide", True)
        self.assertEqual("off", self.phase())
        self.assertTrue(self.ctx.options["_hide_candidate"])
        self.assertEqual(2, self.key("a"))
        self.module.fini(self.env)
        self.assertTrue(self.ctx.options["_hide_candidate"])

    def test_punctuation_shift_and_caps_exit_once(self):
        for name, mods in [(".", {}), ("Tab", {}), ("a", {"shift": True}), ("Caps_Lock", {})]:
            self.make()
            self.key("space")
            self.assertEqual(2, self.key(name, **mods))
            self.assertFalse(self.env.armed)
            self.assertEqual(0, self.ctx.select_calls)

    def test_consumed_marker_only_for_owned_action(self):
        self.key("n")
        self.assertEqual("", self.ctx.properties["_letter_selection_consumed"] or "")
        self.key("space")
        self.assertEqual("1", self.ctx.properties["_letter_selection_consumed"])
        self.key("Escape")
        self.assertEqual("2", self.ctx.properties["_letter_selection_consumed"])

    def test_original_punctuation_navigation_is_not_disarmed(self):
        for config in [
            {"letter_selection/navigation_keys": ["."]},
            {"key_binder/bindings": ["binding"], "key_binder/bindings/@0/accept": ".",
             "key_binder/bindings/@0/send": "Page_Down"},
        ]:
            self.make(config=config); self.key("space")
            self.assertEqual(2, self.key("."))
            self.assertTrue(self.env.armed)
            self.assertEqual("selecting", self.phase())
            self.assertFalse(self.ctx.options["_hide_candidate"])
            self.assertEqual(0, self.ctx.select_calls)

    def test_runtime_keys_are_validated_against_page_size(self):
        self.key("space")
        self.ctx.set_property(self.ctx, "_letter_selection_runtime_keys", "qwertyuio")
        self.ctx.set_property(self.ctx, "_letter_selection_runtime_hide", "false")
        self.ctx.set_property(self.ctx, "_letter_selection_runtime_revision", "1")
        self.assertFalse(self.env.armed)
        self.key("space")
        self.key("w")
        self.assertEqual(1, self.ctx.selected[1])

    def test_fini_disconnects_callbacks_and_restores(self):
        self.make(select_keys="abcdefghi")
        self.key("space")
        self.module.fini(self.env)
        self.assertEqual("abcdefghi", self.env.engine.schema.select_keys)
        self.assertEqual("off", self.phase())
        self.ctx.edit(self.ctx, "hao")
        self.assertEqual("off", self.phase())

    def test_two_instances_share_no_state(self):
        first = self.env
        self.key("space")
        self.make()
        self.assertEqual("editing", self.phase())
        self.assertEqual("asdfghjkl", first.engine.schema.select_keys)
        self.assertEqual("", self.env.engine.schema.select_keys)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex-rime-installer-")
        self.target = Path(self.temp.name)
        self.target.joinpath("fixture.schema.yaml").write_text("engine:\n  processors: [speller, selector, express_editor]\n", encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def test_plan_writes_nothing(self):
        result = install(self.target, "fixture")
        self.assertFalse(result["apply"])
        self.assertFalse((self.target / "lua").exists())

    def test_existing_config_and_learning_preserved_rollback_byte_exact(self):
        original = b"# user comment\npatch:\n  translator/dictionary: mine\n  menu/page_size: 5\n"
        path = self.target / "fixture.custom.yaml"
        path.write_bytes(original)
        (self.target / "my.userdb").mkdir()
        learned = self.target / "my.userdb" / "sentinel"
        learned.write_bytes(b"never touch")
        result = install(self.target, "fixture", True)
        text = path.read_text(encoding="utf-8")
        self.assertIn("# user comment", text)
        self.assertIn("translator/dictionary: mine", text)
        rollback(self.target, result["backup"], True)
        self.assertEqual(original, path.read_bytes())
        self.assertEqual(b"never touch", learned.read_bytes())
        self.assertFalse((self.target / "lua" / "letter_selection.lua").exists())

    def test_disable_restores_original_custom(self):
        path = self.target / "fixture.custom.yaml"
        path.write_bytes(b"patch:\n  menu/page_size: 5\n")
        result = install(self.target, "fixture", True)
        disable(self.target, result["backup"], True)
        self.assertEqual(b"patch:\n  menu/page_size: 5\n", path.read_bytes())
        rollback(self.target, result["backup"], True)

    def test_refuse_active_and_build_targets(self):
        with self.assertRaises(ValueError):
            validate_target(Path.home() / "Library" / "Rime")
        (self.target / "build").mkdir()
        with self.assertRaises(ValueError):
            validate_target(self.target / "build")

    def test_conflicting_processor_insertion_refused(self):
        (self.target / "fixture.custom.yaml").write_text("patch:\n  engine/processors/@before 0: other\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            install(self.target, "fixture", True)

    def test_legacy_gate_requires_explicit_replacement(self):
        (self.target / "fixture.custom.yaml").write_text("patch:\n  engine/processors: [lua_processor@*space_select_gate, speller, selector]\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            install(self.target, "fixture", True)
        result = install(self.target, "fixture", True, legacy=True)
        self.assertNotIn("space_select_gate", (self.target / "fixture.custom.yaml").read_text(encoding="utf-8"))
        rollback(self.target, result["backup"], True)

    def test_later_user_changes_not_silently_discarded(self):
        result = install(self.target, "fixture", True)
        (self.target / "fixture.custom.yaml").write_bytes(b"patch: {}\n# later edit\n")
        with self.assertRaises(ValueError):
            rollback(self.target, result["backup"], True)

    def test_owned_rollback_preserves_later_unrelated_keys(self):
        path = self.target / "fixture.custom.yaml"
        path.write_text("# original\npatch:\n  translator/dictionary: mine\n  menu/page_size: 5\n",encoding="utf-8")
        result = install(self.target,"fixture",True)
        path.write_text(path.read_text(encoding="utf-8")+"  style/font_face: UserLaterFont\n# later comment\n",encoding="utf-8")
        rollback_owned(self.target,result["backup"],True)
        doc = yaml_reader().load(path.read_text(encoding="utf-8"))["patch"]
        self.assertEqual("UserLaterFont",doc["style/font_face"])
        self.assertEqual("mine",doc["translator/dictionary"])
        self.assertEqual(5,doc["menu/page_size"])
        self.assertFalse(any("letter_selection" in str(k) or "@before 0" in str(k) for k in doc))
        self.assertIn("# later comment",path.read_text(encoding="utf-8"))
        previous = path.read_bytes()
        rollback_owned(self.target,result["backup"],True)
        self.assertEqual(previous,path.read_bytes())

    def test_owned_key_conflict_refuses_all_writes(self):
        result = install(self.target,"fixture",True)
        path = self.target / "fixture.custom.yaml"
        text = path.read_text(encoding="utf-8").replace("menu/page_size: 9","menu/page_size: 7")
        path.write_text(text,encoding="utf-8")
        lua = self.target/"lua/letter_selection.lua"
        previous = lua.read_bytes()
        with self.assertRaises(ValueError): rollback_owned(self.target,result["backup"],True)
        self.assertEqual(text,path.read_text(encoding="utf-8")); self.assertEqual(previous,lua.read_bytes())

    def test_owned_rollback_preserves_later_processor_and_restores_legacy(self):
        path = self.target/"fixture.custom.yaml"
        path.write_text("patch:\n  engine/processors: [lua_processor@*space_select_gate, speller, selector]\n",encoding="utf-8")
        result = install(self.target,"fixture",True,legacy=True)
        text = path.read_text(encoding="utf-8").replace("- selector","- selector\n  - later_processor")
        path.write_text(text,encoding="utf-8")
        rollback_owned(self.target,result["backup"],True)
        processors = yaml_reader().load(path.read_text(encoding="utf-8"))["patch"]["engine/processors"]
        self.assertIn("lua_processor@*space_select_gate",processors)
        self.assertIn("later_processor",processors)

    def test_owned_rollback_does_not_resurrect_later_user_deletion(self):
        path = self.target/"fixture.custom.yaml"; path.write_text("patch: {}\n",encoding="utf-8")
        result = install(self.target,"fixture",True); path.unlink()
        with self.assertRaises(ValueError): rollback(self.target,result["backup"],True)
        rollback_owned(self.target,result["backup"],True)
        self.assertFalse(path.exists())

    def test_reinstall_does_not_duplicate_gate(self):
        install(self.target, "fixture", True)
        with self.assertRaises(ValueError):
            install(self.target, "fixture", True)

    def test_do_not_overwrite_another_lua_module(self):
        (self.target / "lua").mkdir()
        path = self.target / "lua" / "letter_selection.lua"
        path.write_bytes(b"-- unrelated user module\n")
        with self.assertRaises(ValueError):
            install(self.target, "fixture", True)
        self.assertEqual(b"-- unrelated user module\n", path.read_bytes())


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output, verbosity=2).run(suite)
    report = {"kind": "unit_test_LuaRuntime_with_Rime_doubles_and_file_installer",
              "tests_run": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
              "real_Rime": False, "macOS_UI": False, "output": output.getvalue()}
    (ROOT / "evidence").mkdir(exist_ok=True)
    (ROOT / "evidence" / "unit-tests.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(output.getvalue())
    sys.exit(not result.wasSuccessful())
