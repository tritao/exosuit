#!/usr/bin/env python3
"""Offline Sakura v8–v14 group/shell importer. Python standard library, POSIX only.

Preview: import-sakura.py session.conf --database /path/to/catalog.sqlite
Apply:   same arguments + --apply (requires typing import)
Example directory remapping (repeat --map as needed):
  python3 scripts/import-sakura.py session.conf --database /state/catalog.sqlite \
    --map /old/projects=/home/me/projects

Imports nested groups, names, order, directories and group-owned shell metadata.
Sakura root children go under --parent (default: work). Every directory must
exist inside the catalog's authorized root after mapping. Initialize the target
workspace in Exosuit first. Stop its managed agent before applying; the script
holds the same agent.lock through backup and commit.

Tasks and their terminals, agent/Codex terminals, pages, layouts, archive flags,
UI state and other unmapped fields are reported and require --allow-lossy.
Archived groups/shells are imported without archive state. Shell processes and
output history cannot transfer; imported shell records are lost/stopped until
explicitly restarted. Existing catalog resources are preserved. The import
changes the group epoch and clears old group event/operation replay records.

--apply prints the plan again and asks you to type import. It creates a private
catalog.sqlite.bak using SQLite backup (including WAL data); an existing backup
is never overwritten. All catalog changes commit together or roll back.
Reimporting matching source identities is refused rather than duplicating them.
Only managed POSIX catalogs with schema 8 and Sakura versions 8–14 are supported.
"""
import argparse
import configparser
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import struct
import sys
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unescape(value):
    """GKeyFile string escapes; configparser alone does not decode these."""
    escapes = {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}
    def replace(match):
        require(match[1] in escapes, f"Invalid GKeyFile escape: {match[0]}")
        return escapes[match[1]]
    require(not re.search(r"(?<!\\)(?:\\\\)*\\$", value), "Trailing string escape")
    return re.sub(r"\\(.)", replace, value)


def pack(value):
    """Encode the small MessagePack subset used by the two persisted @:wire records.

    Field numbers match WorkspaceProtocol.WorkspaceGroup and
    WorkspaceTerminalProtocol.TerminalRecord; no dynamic Haxe serialization.
    """
    if value is None:
        return b"\xc0"
    if isinstance(value, bool):
        return b"\xc3" if value else b"\xc2"
    if isinstance(value, int):
        require(0 <= value <= 0x7fffffff, "Integer outside importer range")
        if value < 128:
            return bytes([value])
        return b"\xce" + struct.pack(">I", value)
    if isinstance(value, str):
        data = value.encode("utf-8")
        require(len(data) <= 65535, "Oversized string")
        return (bytes([0xa0 + len(data)]) if len(data) < 32 else b"\xda" + struct.pack(">H", len(data))) + data
    if isinstance(value, dict):
        require(len(value) < 16, "Oversized record")
        return bytes([0x80 + len(value)]) + b"".join(pack(k) + pack(v) for k, v in value.items())
    raise ValueError(f"Unsupported MessagePack type: {type(value)}")


def read_session(path):
    require(path.stat().st_size <= 8 * 1024 * 1024, "Session exceeds 8 MiB")
    parser = configparser.ConfigParser(interpolation=None, delimiters=("=",),
                                     comment_prefixes=("#",), inline_comment_prefixes=None,
                                     strict=True, empty_lines_in_values=False)
    parser.optionxform = str
    parser.read_string(path.read_text(encoding="utf-8"))
    require(not parser.defaults(), "DEFAULT entries are not supported")
    require("Session" in parser, "Missing Session section")
    data = {s: {k: unescape(v) for k, v in parser[s].items()} for s in parser.sections()}
    version = int(data["Session"].get("version", "0"))
    require(8 <= version <= 14, f"Unsupported Sakura session version {version}; expected 8–14")
    rows = {}
    identities = {"root"}
    for kind in ("Group", "Task", "Page", "Layout", "Terminal"):
        count = int(data["Session"].get(kind.lower() + "_count", "0"))
        require(0 <= count <= 4096, f"Invalid {kind} count")
        names = [f"{kind}{i}" for i in range(count)]
        require({s for s in data if re.fullmatch(kind + r"\d+", s)} == set(names),
                f"{kind} count does not match sections")
        rows[kind] = []
        for name in names:
            row = dict(data[name])
            identity = row.get("terminal_id" if kind == "Terminal" else "id", "")
            require(identity and identity not in identities, f"Duplicate/missing identity in {name}")
            require(len(identity) <= 128, f"Oversized identity in {name}")
            identities.add(identity)
            row["_section"] = name
            rows[kind].append(row)
    groups = {r["id"]: r for r in rows["Group"]}
    tasks = {r["id"]: r for r in rows["Task"]}
    parents = {i: r.get("parent", "root") for i, r in {**groups, **tasks}.items()}
    for identity in parents:
        seen = set()
        current = identity
        while current != "root":
            require(current in parents, f"Unknown parent {current}")
            require(current not in seen, f"Parent cycle at {current}")
            seen.add(current)
            current = parents[current]
    for row in rows["Group"]:
        require(row.get("parent", "root") == "root" or row.get("parent") in groups,
                "A group cannot have a task parent")
    for row in rows["Terminal"]:
        require(row.get("parent", "root") in identities and
                row.get("parent", "root") in {"root", *groups, *tasks}, "Unknown terminal parent")
    return data, rows


def make_plan(source, db, mappings, parent):
    data, rows = read_session(source)
    require(db.execute("PRAGMA user_version").fetchone()[0] == 8,
            "Only Exosuit catalog schema 8 is supported")
    meta = db.execute("SELECT workspace,root FROM workspace_meta WHERE id=1").fetchone()
    require(meta and meta[0] == "workspace" and meta[1], "Invalid workspace identity/root")
    root = Path(meta[1]).resolve(strict=True)
    require(str(root) == meta[1] and root.is_dir(), "Workspace root is not canonical")
    existing = {r[0] for r in db.execute("SELECT id FROM workspace_groups")}
    require(parent in existing, f"Destination group {parent!r} does not exist")
    mapping = []
    for item in mappings:
        old, sep, new = item.partition("=")
        require(sep and Path(old).is_absolute() and Path(new).is_absolute(),
                "Mappings must be absolute OLD=NEW paths")
        mapping.append((Path(old), Path(new)))
    require(len({a for a, _ in mapping}) == len(mapping), "Duplicate directory mapping")
    mapping.sort(key=lambda item: len(item[0].parts), reverse=True)
    def directory(raw):
        if not raw:
            return None
        path = Path(raw)
        require(path.is_absolute(), f"Directory must be absolute: {raw}")
        for old, new in mapping:
            if path.is_relative_to(old):
                path = new / path.relative_to(old)
                break
        path = path.resolve(strict=True)
        require(path.is_dir() and os.access(path, os.R_OK | os.X_OK), f"Inaccessible directory: {path}")
        require(path.is_relative_to(root), f"Directory outside authorized root {root}: {path}; use --map")
        require(len(str(path)) <= 1024, "Directory exceeds protocol limit")
        return str(path)
    # Stable, source-id-based names prevent accidental duplicate imports.
    def target(kind, identity):
        return "sakura-" + hashlib.sha256((kind + ":" + identity).encode()).hexdigest()[:32]
    ids = {r["id"]: target("group", r["id"]) for r in rows["Group"]}
    groups, terminals, skipped = [], [], []
    def skip(section, reason):
        skipped.append({"section": section, "reason": reason})
    def name(value):
        require(value.strip() and len(value) <= 128 and not any(c in value for c in "\t\r\n\0"),
                f"Invalid catalog name: {value!r}")
        return value
    # Every field not consumed is explicitly included in the report.
    consumed = {"Group": {"id", "parent", "order", "title", "directory"},
                "Terminal": {"terminal_id", "parent", "cwd", "kind", "title"}}
    for section, values in data.items():
        kind = next((k for k in consumed if re.fullmatch(k + r"\d+", section)), None)
        fields = {k: v for k, v in values.items() if kind is None or k not in consumed[kind]}
        if fields:
            skip(section, {"fields_not_imported": fields})
    # Tasks have no equivalent in this catalog. Do not flatten their terminals silently.
    task_ids = {r["id"] for r in rows["Task"]}
    for row in rows["Group"]:
        order = int(row.get("order", "0"))
        require(0 <= order <= 1000000, "Invalid sibling order")
        groups.append(dict(id=ids[row["id"]], name=name(row.get("title", "")),
                           cwd=directory(row.get("directory")), revision=1,
                           parent=parent if row.get("parent", "root") == "root" else ids[row["parent"]], order=order))
    for row in rows["Terminal"]:
        if (row.get("kind", "shell") != "shell" or row.get("agent_provider")
                or row.get("parent", "root") in task_ids):
            skip(row["_section"], "Terminal omitted: unsupported kind or task ownership")
            continue
        group = parent if row.get("parent", "root") == "root" else ids[row["parent"]]
        cwd = directory(row.get("cwd"))
        require(cwd is not None, "Shell terminal needs an explicit cwd")
        terminals.append(dict(id=target("terminal", row["terminal_id"]),
                              name=name(row.get("title") or "Sakura shell"), group=group, cwd=cwd))
    require(len(existing) + len(groups) <= 32, "Catalog supports at most 32 groups")
    terminal_ids = {r[0] for r in db.execute("SELECT id FROM workspace_terminals")}
    require(len(terminal_ids) + len(terminals) <= 256, "Catalog supports at most 256 terminals")
    require(not existing.intersection(g["id"] for g in groups), "Groups already imported (identity conflict)")
    require(not terminal_ids.intersection(t["id"] for t in terminals), "Terminals already imported (identity conflict)")
    return dict(root=str(root), groups=groups, terminals=terminals, skipped=skipped,
                note="Shell metadata only; restart imported shells explicitly. No processes or history transferred.")


@contextlib.contextmanager
def agent_lock(database):
    path = database.parent / "agent.lock"
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and
                info.st_mode & 0o077 == 0 and info.st_nlink == 1, "Agent lock must be a private regular file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Workspace agent is running; close its clients and stop it before importing") from None
        yield
    finally:
        os.close(descriptor)


def apply_plan(db, plan):
    # Offline import changes the epoch so old clients cannot replay stale events or operations.
    db.execute("BEGIN IMMEDIATE")
    try:
        for g in plan["groups"]:
            payload = pack({i + 1: g[k] for i, k in enumerate(("id", "name", "cwd", "revision", "parent", "order"))})
            db.execute("INSERT INTO workspace_groups VALUES (?,?,?)", (g["id"], 1, payload))
        for t in plan["terminals"]:
            payload = pack({1: t["id"], 2: t["name"], 3: t["group"], 4: t["cwd"],
                            5: "sakura-import", 6: "lost", 7: 0, 8: False, 9: 1, 10: plan["root"], 11: None})
            db.execute("INSERT INTO workspace_terminals VALUES (?,?)", (t["id"], payload))
        db.execute("DELETE FROM workspace_events")
        db.execute("DELETE FROM workspace_operations")
        db.execute("UPDATE workspace_meta SET epoch=?,cursor=0 WHERE id=1", (uuid.uuid4().hex,))
        db.commit()
    except BaseException:
        db.rollback()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("session", type=Path)
    parser.add_argument("--database", required=True, type=Path, help="Existing managed catalog.sqlite")
    parser.add_argument("--parent", default="work", help="Destination group for Sakura root children")
    parser.add_argument("--map", action="append", default=[], metavar="OLD=NEW", help="Directory prefix mapping (repeatable)")
    parser.add_argument("--apply", action="store_true", help="Back up and import; default is read-only preview")
    parser.add_argument("--allow-lossy", action="store_true", help="Accept all skipped fields/resources shown in the preview")
    args = parser.parse_args()
    database = args.database.resolve(strict=True)
    source = args.session.resolve(strict=True)
    # Preview opens SQLite read-only and takes no manager lock.
    with contextlib.ExitStack() as stack:
        if args.apply:
            stack.enter_context(agent_lock(database))
        db = sqlite3.connect(database.as_uri() + ("?mode=rw" if args.apply else "?mode=ro"), uri=True)
        stack.callback(db.close)
        plan = make_plan(source, db, args.map, args.parent)
        print(json.dumps(plan, indent=2, ensure_ascii=False))
        if not args.apply:
            return
        require(plan["groups"] or plan["terminals"], "Nothing supported to import")
        require(not plan["skipped"] or args.allow_lossy, "Skipped data: review preview, then use --allow-lossy to accept")
        require(input("Type import to apply this plan: ") == "import", "Import cancelled")
        backup = Path(str(database) + ".bak")
        descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        try:
            with sqlite3.connect(backup) as destination:
                db.backup(destination)
        except BaseException:
            backup.unlink()
            raise
        apply_plan(db, plan)
        print(f"Imported {len(plan['groups'])} groups and {len(plan['terminals'])} shell records. Backup: {backup}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, sqlite3.Error, configparser.Error, EOFError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
