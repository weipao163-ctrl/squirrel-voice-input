#!/usr/bin/env python3
"""Plan/install/disable/rollback files in an explicitly named Rime directory.

Never writes build/, dictionaries, userdb, system apps, or starts/redeploys Rime.
Requires ruamel.yaml for round-trip preservation of unrelated YAML/comments.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "vendor"))
from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap


def digest(data):
    return hashlib.sha256(data).hexdigest()


def yaml_reader():
    reader = YAML()
    reader.preserve_quotes = True
    reader.allow_duplicate_keys = False
    reader.width = 120
    return reader


def validate_target(target, live=False):
    target = Path(target).expanduser().resolve()
    protected = [(Path.home() / "Library" / "Rime").resolve()]
    import os
    if os.environ.get("APPDATA"):
        protected.append((Path(os.environ["APPDATA"]) / "Rime").resolve())
    if target in protected and not live:
        raise ValueError("Active user directory refused: use an isolated copy, or explicitly pass --live-user-config")
    if not target.is_dir():
        raise ValueError("Target directory must already exist")
    if target.name.lower() == "build":
        raise ValueError("Never install into Rime build cache")
    return target


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".letter-selection-", delete=False) as stream:
        stream.write(data)
        temporary = Path(stream.name)
    temporary.replace(path)


def make_plan(target, schema, legacy=False, keys=None):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", schema):
        raise ValueError("Invalid schema_id")
    if not (target / f"{schema}.schema.yaml").is_file() and not (target / "build" / f"{schema}.schema.yaml").is_file():
        raise ValueError("Schema not found; copy your own scheme into the isolated directory first")
    reader = yaml_reader()
    custom = target / f"{schema}.custom.yaml"
    doc = reader.load(custom.read_text(encoding="utf-8-sig")) if custom.exists() else CommentedMap()
    if doc is None:
        doc = CommentedMap()
    if not isinstance(doc, dict):
        raise ValueError(".custom.yaml must be a YAML mapping")
    patch = doc.setdefault("patch", CommentedMap())
    if not isinstance(patch, dict):
        raise ValueError("patch must be a mapping; manual integration required")
    insert = "engine/processors/@before 0"
    if insert in patch:
        raise ValueError("Existing @before 0 insertion conflicts; do not overwrite it")
    if any(str(key).startswith("letter_selection") for key in patch):
        raise ValueError("Already configured; disable or roll back the previous installation first")
    deployed = target / "build" / f"{schema}.schema.yaml"
    baseline = deployed if deployed.exists() else target / f"{schema}.schema.yaml"
    if "engine/processors" in patch:
        processors = patch["engine/processors"]
    else:
        baseline_doc = reader.load(baseline.read_text(encoding="utf-8-sig"))
        processors = baseline_doc.get("engine", {}).get("processors", [])
    conflicts = [p for p in processors if "space_select_gate" in str(p) or "letter_selection" in str(p)]
    if conflicts:
        if not legacy or not all("space_select_gate" in str(p) for p in conflicts):
            raise ValueError(f"Competing gate detected: {conflicts}; isolate and review before replacement")
        patch["engine/processors"] = [p for p in processors if "space_select_gate" not in str(p)]
    template = reader.load((ROOT / "config" / "letter_selection.patch.yaml").read_text(encoding="utf-8"))["patch"]
    if keys is not None:
        if not re.fullmatch(r"[a-z]{1,9}", keys) or len(set(keys)) != len(keys):
            raise ValueError("Selection keys must be 1-9 unique lowercase letters")
        template["letter_selection/keys"] = keys
        template["menu/page_size"] = len(keys)
    for key, value in template.items():
        if key == "menu/page_size" and key in patch:
            patch[key] = value  # this one intentional setting is recorded in the byte backup
        elif key in patch:
            raise ValueError(f"Refusing to overwrite existing patch key: {key}")
        else:
            patch[key] = value
    output = io.StringIO()
    reader.dump(doc, output)
    lua_file = target / "lua" / "letter_selection.lua"
    if lua_file.exists() and lua_file.read_bytes() != (ROOT / "lua" / "letter_selection.lua").read_bytes():
        raise ValueError("Existing lua/letter_selection.lua differs; do not overwrite another module")
    return {
        f"{schema}.custom.yaml": output.getvalue().encode("utf-8"),
        "lua/letter_selection.lua": (ROOT / "lua" / "letter_selection.lua").read_bytes(),
    }


def install(target, schema, apply=False, legacy=False, keys=None):
    target = Path(target).resolve()
    plan = make_plan(target, schema, legacy, keys)
    for rel in plan:
        if not (target / rel).resolve().is_relative_to(target):
            raise ValueError(f"Symlink/reparse-point path escapes target: {rel}")
    summary = {"target": str(target), "schema": schema, "files": list(plan),
               "apply": apply, "redeploy": False, "restart": False}
    if not apply:
        return summary
    backup = target / ".letter-selection-backups" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backup.mkdir(parents=True, exist_ok=False)
    manifest = {"target": str(target), "schema": schema, "files": {}, "complete": False}
    for rel, new in plan.items():
        path = target / rel
        old = path.read_bytes() if path.exists() else None
        if old is not None:
            saved = backup / rel
            saved.parent.mkdir(parents=True, exist_ok=True)
            saved.write_bytes(old)
        manifest["files"][rel] = {"existed": old is not None, "before": digest(old) if old is not None else None,
                                 "after": digest(new)}
        saved_after = backup / ".installed" / rel
        saved_after.parent.mkdir(parents=True, exist_ok=True)
        saved_after.write_bytes(new)
    manifest_path = backup / "manifest.json"
    atomic_write(manifest_path, (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    for rel, new in plan.items():
        atomic_write(target / rel, new)
    manifest["complete"] = True
    atomic_write(manifest_path, (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    return {**summary, "backup": str(backup)}


def rollback(target, backup, apply=False):
    target, backup = Path(target).resolve(), Path(backup).resolve()
    if not backup.is_relative_to(target / ".letter-selection-backups"):
        raise ValueError("Backup must belong to this target")
    manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    if Path(manifest["target"]).resolve() != target:
        raise ValueError("Backup target mismatch")
    restorations = []
    for rel, entry in manifest["files"].items():
        path = (target / rel).resolve()
        if not path.is_relative_to(target) or Path(rel).parts[0] == "build":
            raise ValueError("Unsafe backup entry")
        current = path.read_bytes() if path.exists() else None
        # A later Lua/config edit is not discarded silently. Disable adds an approved hash.
        allowed = [entry["after"], entry["before"]]
        if "disabled_after" in entry: allowed.append(entry["disabled_after"])
        if (digest(current) if current is not None else None) not in allowed:
            raise ValueError(f"File changed since installation; manual merge required: {rel}")
        if entry["existed"]:
            old = (backup / rel).read_bytes()
            if digest(old) != entry["before"]:
                raise ValueError("Backup integrity check failed")
            restorations.append((path, old))
        else:
            restorations.append((path, None))
    if apply:
        for path, old in restorations:
            if old is None:
                if path.exists():
                    path.unlink()  # a single manifest-bound file, never recursive data deletion
            else:
                atomic_write(path, old)
    return {"target": str(target), "backup": str(backup), "apply": apply,
            "restored_files": list(manifest["files"]), "redeploy": False}


def disable(target, backup, apply=False):
    target, backup = Path(target).resolve(), Path(backup).resolve()
    # Restoring the original custom bytes also restores page size, labels and processor order.
    manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    rollback(target, backup, apply=False)  # validate all paths and changes before writing
    rel = f"{manifest['schema']}.custom.yaml"
    entry = manifest["files"][rel]
    if apply:
        if entry["existed"]:
            old = (backup / rel).read_bytes()
            atomic_write(target / rel, old)
            entry["disabled_after"] = digest(old)
        else:
            (target / rel).unlink(missing_ok=True)
            entry["disabled_after"] = None
        atomic_write(backup / "manifest.json", (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode())
    return {"target": str(target), "apply": apply, "disabled": rel, "redeploy": False}


def rollback_owned(target, backup, apply=False):
    """Three-way remove only owned YAML leaves; preserve unrelated subsequent edits.

    Exact owned-key conflicts and changed Lua cause a preflight refusal, not loss.
    Original rollback remains byte-exact/strict; this is an explicit separate mode.
    """
    target, backup = Path(target).resolve(), Path(backup).resolve()
    if not backup.is_relative_to(target / ".letter-selection-backups"):
        raise ValueError("Backup must belong to this target")
    manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    if Path(manifest["target"]).resolve() != target:
        raise ValueError("Backup target mismatch")
    pending, owned = [], []
    missing = object()
    reader = yaml_reader()
    def leaves(before, after, path=()):
        if isinstance(after, dict) and (before is missing or isinstance(before, dict)):
            original = {} if before is missing else before
            for k in set(original) | set(after):
                yield from leaves(original.get(k, missing), after.get(k, missing), path + (k,))
        elif before != after:
            yield path, before, after
    for rel, entry in manifest["files"].items():
        path = (target / rel).resolve()
        if not path.is_relative_to(target) or Path(rel).parts[0] == "build":
            raise ValueError("Unsafe backup entry")
        current = path.read_bytes() if path.exists() else None
        before = (backup / rel).read_bytes() if entry["existed"] else None
        if before is not None and digest(before) != entry["before"]:
            raise ValueError("Backup integrity check failed")
        current_hash = digest(current) if current is not None else None
        allowed = [entry["after"], entry["before"]]
        if "disabled_after" in entry: allowed.append(entry["disabled_after"])
        if current is None:
            pending.append((path, None)); continue # Respect a subsequent user deletion.
        if current_hash in allowed:
            pending.append((path, before)); continue
        if not rel.endswith(".custom.yaml") or current is None:
            raise ValueError(f"Owned file changed; preserve and review: {rel}")
        snapshot = backup / ".installed" / rel
        if not snapshot.exists() or digest(snapshot.read_bytes()) != entry["after"]:
            raise ValueError("Installed snapshot missing/invalid; cannot prove YAML ownership")
        original = reader.load(before.decode("utf-8-sig")) if before else {}
        installed = reader.load(snapshot.read_text(encoding="utf-8-sig"))
        document = reader.load(current.decode("utf-8-sig"))
        if not isinstance(document, dict): raise ValueError("Current custom is not a mapping")
        for parts, old, new in leaves(original or {}, installed or {}):
            node = document
            for part in parts[:-1]:
                if not isinstance(node, dict): raise ValueError("Owned YAML parent changed")
                node = node.get(part, {})
            if not isinstance(node, dict): raise ValueError("Owned YAML parent changed")
            value = node.get(parts[-1], missing)
            if value is missing and old is missing: continue
            if value == old: continue
            if value != new:
                # The explicit legacy replacement owns only removal of that gate.
                if parts == ("patch", "engine/processors") and isinstance(old, list) and isinstance(new, list) and isinstance(value, list):
                    removed = [p for p in old if p not in new]
                    if removed and all("space_select_gate" in str(p) for p in removed) and new == [p for p in old if p not in removed]:
                        for p in removed:
                            if p not in value: value.insert(min(old.index(p), len(value)), p)
                        owned.append("/".join(parts)); continue
                raise ValueError(f"Owned YAML key changed; no writes made: {'/'.join(parts)}")
            if old is missing: node.pop(parts[-1], None)
            else: node[parts[-1]] = old
            owned.append("/".join(parts))
        output = io.StringIO(); reader.dump(document, output)
        pending.append((path, output.getvalue().encode("utf-8")))
    if apply:
        for path, content in pending:
            if content is None: path.unlink(missing_ok=True)
            else: atomic_write(path, content)
    return {"target": str(target), "apply": apply, "owned_keys": owned,
            "preserves_unrelated_later_edits": True, "redeploy": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install", "disable", "rollback", "rollback-owned"])
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--schema")
    parser.add_argument("--keys", help="1-9 unique lowercase selection letters; default asdfghjkl")
    parser.add_argument("--backup", type=Path)
    parser.add_argument("--apply", action="store_true", help="Without this flag, print a plan only")
    parser.add_argument("--live-user-config", action="store_true", help="Explicitly opt into the active user directory")
    parser.add_argument("--replace-legacy-gate", action="store_true", help="Remove only an existing space_select_gate processor")
    args = parser.parse_args()
    try:
        target = validate_target(args.target, args.live_user_config)
        if args.command == "install":
            if not args.schema:
                parser.error("install requires --schema")
            result = install(target, args.schema, args.apply, args.replace_legacy_gate, args.keys)
        else:
            if not args.backup:
                parser.error("disable/rollback requires --backup")
            result = globals()[args.command.replace("-", "_")](target, args.backup, args.apply)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, OSError) as exc:
        parser.exit(1, f"Not applied: {exc}\n")


if __name__ == "__main__":
    main()
