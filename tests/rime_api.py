"""ctypes bindings to librime's versioned C API (Bool=int flavour, not stdbool).

The function order is from the official rime_api.h. Data is copied before free.
No calls are made to the running frontend, and user_data_dir must be isolated.
"""
import ctypes as C
import os
from pathlib import Path

I, S, P, Z = C.c_int, C.c_char_p, C.c_void_p, C.c_size_t
FUNCTIONS = """setup set_notification_handler initialize finalize start_maintenance
is_maintenance_mode join_maintenance_thread deployer_initialize prebuild deploy
deploy_schema deploy_config_file sync_user_data create_session find_session
destroy_session cleanup_stale_sessions cleanup_all_sessions process_key
commit_composition clear_composition get_commit free_commit get_context free_context
get_status free_status set_option get_option set_property get_property get_schema_list
free_schema_list get_current_schema select_schema schema_open config_open config_close
config_get_bool config_get_int config_get_double config_get_string config_get_cstring
config_update_signature config_begin_map config_next config_end simulate_key_sequence
register_module find_module run_task get_shared_data_dir get_user_data_dir get_sync_dir
get_user_id get_user_data_sync_dir config_init config_load_string config_set_bool
config_set_int config_set_double config_set_string config_get_item config_set_item
config_clear config_create_list config_create_map config_list_size config_begin_list
get_input get_caret_pos select_candidate get_version set_caret_pos
select_candidate_on_current_page candidate_list_begin candidate_list_next
candidate_list_end user_config_open candidate_list_from_index get_prebuilt_data_dir
get_staging_dir commit_proto context_proto status_proto get_state_label
delete_candidate delete_candidate_on_current_page get_state_label_abbreviated set_input
get_shared_data_dir_s get_user_data_dir_s get_prebuilt_data_dir_s get_staging_dir_s
get_sync_dir_s highlight_candidate highlight_candidate_on_current_page change_page
get_candidate_preview free_candidate_preview""".split()


class Api(C.Structure):
    _fields_ = [("data_size", I)] + [(name, P) for name in FUNCTIONS]


class Traits(C.Structure):
    _fields_ = [("data_size", I), ("shared_data_dir", S), ("user_data_dir", S),
                ("distribution_name", S), ("distribution_code_name", S),
                ("distribution_version", S), ("app_name", S), ("modules", C.POINTER(S)),
                ("min_log_level", I), ("log_dir", S), ("prebuilt_data_dir", S), ("staging_dir", S)]


class Composition(C.Structure):
    _fields_ = [("length", I), ("cursor_pos", I), ("sel_start", I), ("sel_end", I), ("preedit", S)]


class Candidate(C.Structure):
    _fields_ = [("text", S), ("comment", S), ("reserved", P)]


class Menu(C.Structure):
    _fields_ = [("page_size", I), ("page_no", I), ("is_last_page", I),
                ("highlighted_candidate_index", I), ("num_candidates", I),
                ("candidates", C.POINTER(Candidate)), ("select_keys", S)]


class Context(C.Structure):
    _fields_ = [("data_size", I), ("composition", Composition), ("menu", Menu),
                ("commit_text_preview", S), ("select_labels", C.POINTER(S))]


class Commit(C.Structure):
    _fields_ = [("data_size", I), ("text", S)]

class Config(C.Structure):
    _fields_ = [("ptr", P)]

class ConfigIterator(C.Structure):
    _fields_ = [("list",P),("map",P),("index",I),("key",S),("path",S)]


def new_struct(cls):
    obj = cls()
    obj.data_size = C.sizeof(cls) - C.sizeof(I)
    return obj


def decode(value):
    return value.decode("utf-8") if value else ""


class Rime:
    def __init__(self, library, shared, user, plugins=()):
        self.library = Path(library).resolve()
        self.cookie = os.add_dll_directory(str(self.library.parent)) if os.name == "nt" else None
        self.dll = C.CDLL(str(self.library), mode=C.RTLD_GLOBAL)
        self.plugins = [C.CDLL(str(Path(plugin).resolve()), mode=C.RTLD_GLOBAL) for plugin in plugins]
        self.dll.rime_get_api.restype = C.POINTER(Api)
        self.api = self.dll.rime_get_api().contents
        signatures = {
            "setup": (None, C.POINTER(Traits)), "initialize": (None, C.POINTER(Traits)),
            "finalize": (None,), "get_version": (S,), "find_module": (P, S),
            "deploy_schema": (I, S), "deploy_config_file": (I, S, S),
            "start_maintenance": (I, I), "join_maintenance_thread": (None,),
            "create_session": (Z,), "destroy_session": (I, Z),
            "select_schema": (I, Z, S), "process_key": (I, Z, I, I),
            "clear_composition": (None, Z), "get_input": (S, Z),
            "get_context": (I, Z, C.POINTER(Context)), "free_context": (I, C.POINTER(Context)),
            "get_commit": (I, Z, C.POINTER(Commit)), "free_commit": (I, C.POINTER(Commit)),
            "set_option": (None, Z, S, I), "get_option": (I, Z, S),
            "set_property": (None, Z, S, S), "get_property": (I, Z, S, P, Z),
            "select_candidate_on_current_page": (I, Z, Z), "change_page": (I, Z, I),
            "set_caret_pos": (None, Z, Z), "highlight_candidate_on_current_page": (I, Z, Z),
            "schema_open": (I, S, C.POINTER(Config)), "config_close": (I, C.POINTER(Config)),
            "config_load_string": (I, C.POINTER(Config), S),
            "config_list_size": (Z, C.POINTER(Config), S),
            "config_get_cstring": (S, C.POINTER(Config), S),
            "config_begin_map": (I, C.POINTER(ConfigIterator), C.POINTER(Config), S),
            "config_next": (I, C.POINTER(ConfigIterator)), "config_end": (None, C.POINTER(ConfigIterator)),
        }
        for name, signature in signatures.items():
            field = getattr(Api, name)
            if field.offset + C.sizeof(P) > self.api.data_size + C.sizeof(I) or not getattr(self.api, name):
                raise RuntimeError(f"librime API unavailable: {name}")
            setattr(self, name, C.CFUNCTYPE(*signature)(getattr(self.api, name)))
        self.traits = new_struct(Traits)
        self.paths = [str(Path(p).resolve()).encode("utf-8") for p in (shared, user, Path(user) / "logs")]
        Path(user, "logs").mkdir(parents=True, exist_ok=True)
        self.traits.shared_data_dir, self.traits.user_data_dir, self.traits.log_dir = self.paths
        self.traits.app_name = b"rime.letter_selection_test"
        self.traits.distribution_name = b"Isolated test"
        self.traits.distribution_code_name = b"letter_selection_test"
        self.traits.distribution_version = b"0.1"
        self.traits.min_log_level = 0
        self.modules = (S * 4)(b"default", b"lua", b"deployer", None)
        self.traits.modules = self.modules
        self.setup(C.byref(self.traits))
        self.initialize(C.byref(self.traits))

    def processors(self, schema):
        config = Config()
        assert self.schema_open(schema.encode(),C.byref(config)), "schema_open failed"
        try:
            count = self.config_list_size(C.byref(config),b"engine/processors")
            assert 0 < count <= 256
            return [decode(self.config_get_cstring(C.byref(config),f"engine/processors/@{i}".encode())) for i in range(count)]
        finally:
            self.config_close(C.byref(config))

    def patch_keys(self, yaml):
        config = Config()
        try:
            assert self.config_load_string(C.byref(config),yaml.encode('utf-8')), "real YAML parser rejected document"
            iterator=ConfigIterator()
            if not self.config_begin_map(C.byref(iterator),C.byref(config),b"patch"):
                return None # Real YAML null is distinct from a mapping.
            try:
                keys=[]
                while self.config_next(C.byref(iterator)):
                    assert len(keys)<2048
                    keys.append(decode(iterator.key))
                return keys
            finally: self.config_end(C.byref(iterator))
        finally:
            if config.ptr: self.config_close(C.byref(config))

    def property(self, session, name):
        buf = C.create_string_buffer(2048)
        self.get_property(session, name.encode(), buf, len(buf))
        return decode(buf.value)

    def state(self, session):
        result = {"input": decode(self.get_input(session)),
                  "phase": self.property(session, "_letter_selection_phase"),
                  "keys": self.property(session, "_letter_selection_keys"),
                  "label_backend": self.property(session, "_letter_selection_label_backend"),
                  "lua_version": self.property(session, "_letter_selection_lua_version"),
                  "error": self.property(session, "_letter_selection_error")}
        ctx = new_struct(Context)
        if self.get_context(session, C.byref(ctx)):
            try:
                result.update(preedit=decode(ctx.composition.preedit), caret=ctx.composition.cursor_pos,
                              page=ctx.menu.page_no, size=ctx.menu.page_size,
                              highlighted=ctx.menu.highlighted_candidate_index,
                              last_page=bool(ctx.menu.is_last_page),
                              candidates=[decode(ctx.menu.candidates[i].text) for i in range(ctx.menu.num_candidates)],
                              original_keys=decode(ctx.menu.select_keys),
                              original_labels=[decode(ctx.select_labels[i]) for i in range(ctx.menu.page_size)] if ctx.select_labels else [])
            finally:
                self.free_context(C.byref(ctx))
        commit = new_struct(Commit)
        result["commit"] = ""
        if self.get_commit(session, C.byref(commit)):
            try:
                result["commit"] = decode(commit.text)
            finally:
                self.free_commit(C.byref(commit))
        return result
