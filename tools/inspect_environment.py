#!/usr/bin/env python3
"""Read-only inventory. Does not initialize/deploy/restart Rime or edit user files."""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import platform
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "vendor"))
sys.path.insert(0, str(ROOT / "tests"))
from ruamel.yaml import YAML
from rime_api import Api


def yaml_info(path):
    try:
        reader = YAML(typ="safe")
        return reader.load(path.read_text(encoding="utf-8-sig")) if path.exists() else None
    except Exception as exc:
        return {"read_error": str(exc)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-dir", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--plugin", type=Path, action="append", default=[])
    args = parser.parse_args()
    user = args.user_dir or (Path.home() / "Library" / "Rime" if sys.platform == "darwin" else Path(os.environ.get("APPDATA", "")) / "Rime")
    report = {"platform": platform.platform(), "user_dir": str(user.resolve()), "read_only": True,
              "installation": yaml_info(user / "installation.yaml"),
              "user_state": yaml_info(user / "user.yaml"), "real_Lua_execution_tested": False}
    state = report["user_state"]
    schema = state.get("var", {}).get("previously_selected_schema") if isinstance(state, dict) else None
    if schema:
        effective = yaml_info(user / "build" / f"{schema}.schema.yaml")
        if isinstance(effective, dict):
            report["last_selected_schema_config"] = {key: effective.get(key) for key in ["schema", "engine", "menu"]}
        report["schema_state_is_persisted_not_live_frontend"] = True
    if sys.platform == "darwin" or args.app:
        app = args.app or Path("/Library/Input Methods/Squirrel.app")
        plist = app / "Contents" / "Info.plist"
        if plist.exists():
            info = plistlib.loads(plist.read_bytes())
            report["squirrel"] = {"path": str(app.resolve()), "version": info.get("CFBundleShortVersionString"),
                                  "build": info.get("CFBundleVersion")}
            libraries = list((app / "Contents").rglob("librime*.dylib"))
            report["bundled_libraries"] = [str(p) for p in libraries]
            if not args.library:
                args.library = next((p for p in libraries if p.name == "librime.1.dylib"), None)
            if not args.plugin:
                args.plugin = [p for p in libraries if p.name == "librime-lua.dylib"]
        else:
            report["squirrel"] = {"installed": False, "path_checked": str(app)}
    if args.library:
        cookie = os.add_dll_directory(str(args.library.resolve().parent)) if os.name == "nt" else None
        try:
            dll = C.CDLL(str(args.library.resolve()), mode=C.RTLD_GLOBAL)
            plugins = [C.CDLL(str(p.resolve()), mode=C.RTLD_GLOBAL) for p in args.plugin]
            dll.rime_get_api.restype = C.POINTER(Api)
            api = dll.rime_get_api().contents
            version = C.CFUNCTYPE(C.c_char_p)(api.get_version)().decode()
            lua = C.CFUNCTYPE(C.c_void_p, C.c_char_p)(api.find_module)(b"lua")
            report["runtime_probe"] = {"library": str(args.library.resolve()), "librime": version,
                                       "lua_module_registered": bool(lua), "initialized": False}
        except Exception as exc:
            report["runtime_probe"] = {"load_error": str(exc), "initialized": False}
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
