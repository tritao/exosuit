#!/usr/bin/env python3
"""Standalone importer regression tests: python3 scripts/test-import-sakura.py."""
import fcntl
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("import-sakura.py")
spec = importlib.util.spec_from_file_location("sakura_import", SCRIPT)
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.database = self.root / "catalog.sqlite"
        self.db = sqlite3.connect(self.database)
        self.addCleanup(self.db.close)
        self.db.executescript("""
            PRAGMA user_version=8;
            CREATE TABLE workspace_meta(id INTEGER PRIMARY KEY,workspace TEXT,root TEXT,epoch TEXT,cursor INTEGER);
            CREATE TABLE workspace_groups(id TEXT PRIMARY KEY,revision INTEGER,payload BLOB);
            CREATE TABLE workspace_terminals(id TEXT PRIMARY KEY,payload BLOB);
            CREATE TABLE workspace_events(sequence INTEGER PRIMARY KEY,payload BLOB);
            CREATE TABLE workspace_operations(id TEXT PRIMARY KEY,payload BLOB);
            INSERT INTO workspace_groups VALUES('work',1,X'80');
            INSERT INTO workspace_events VALUES(1,X'80');
            INSERT INTO workspace_operations VALUES('old',X'80');
        """)
        self.db.execute("INSERT INTO workspace_meta VALUES(1,'workspace',?,'old',1)", (str(self.root),))
        self.db.commit()
        self.source = self.root / "session.conf"
        self.source.write_text(r"""[Session]
version=8
group_count=2
terminal_count=1
[Group0]
id=one
parent=root
title=Tools\s% # literal
order=3
directory=/old
[Group1]
id=two
parent=one
title=Tools
[Terminal0]
terminal_id=shell
parent=two
kind=shell
cwd=/old
title=Terminal
""")

    def plan(self):
        return importer.make_plan(self.source, self.db, [f"/old={self.root}"], "work")

    def cli(self, *args, text=None):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.source),
                               "--database", str(self.database), "--map", f"/old={self.root}", *args],
                              input=text, capture_output=True, text=True)

    def test_preview_and_apply_backup(self):
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["groups"][0]["name"], "Tools % # literal")
        self.assertEqual(plan["groups"][1]["parent"], plan["groups"][0]["id"])
        self.assertEqual(plan["terminals"][0]["group"], plan["groups"][1]["id"])
        self.assertEqual(self.db.execute("SELECT count(*) FROM workspace_groups").fetchone()[0], 1)
        self.assertFalse(Path(str(self.database) + ".bak").exists())
        result = self.cli("--apply", "--allow-lossy", text="import\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.db.execute("SELECT count(*) FROM workspace_groups").fetchone()[0], 3)
        self.assertEqual(self.db.execute("SELECT count(*) FROM workspace_terminals").fetchone()[0], 1)
        self.assertEqual(self.db.execute("SELECT cursor FROM workspace_meta").fetchone()[0], 0)
        self.assertNotEqual(self.db.execute("SELECT epoch FROM workspace_meta").fetchone()[0], "old")
        self.assertEqual(self.db.execute("SELECT count(*) FROM workspace_events").fetchone()[0], 0)
        with sqlite3.connect(str(self.database) + ".bak") as backup:
            self.assertEqual(backup.execute("SELECT count(*) FROM workspace_groups").fetchone()[0], 1)
            self.assertEqual(backup.execute("SELECT epoch FROM workspace_meta").fetchone()[0], "old")
        self.assertIn("already imported", self.cli().stderr)

    def test_cycle_unknown_parent_and_duplicate(self):
        original = self.source.read_text()
        for changed in (original.replace("parent=root", "parent=two"),
                        original.replace("parent=root", "parent=missing"),
                        original.replace("id=two", "id=one")):
            self.source.write_text(changed)
            with self.assertRaises(ValueError):
                self.plan()

    def test_outside_root_and_symlink_escape(self):
        self.source.write_text(self.source.read_text().replace("directory=/old", "directory=/"))
        with self.assertRaisesRegex(ValueError, "outside authorized"):
            self.plan()
        self.source.write_text(self.source.read_text().replace("directory=/", "directory=/old/escape"))
        (self.root / "escape").symlink_to("/", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "outside authorized"):
            self.plan()

    def test_running_agent(self):
        with open(self.root / "agent.lock", "w") as lock:
            (self.root / "agent.lock").chmod(0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = self.cli("--apply", "--allow-lossy", text="import\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("agent is running", result.stderr)

    def test_backup_never_overwritten_and_confirmation(self):
        backup = Path(str(self.database) + ".bak")
        backup.write_bytes(b"keep me")
        for text in ("no\n", "import\n"):
            self.assertNotEqual(self.cli("--apply", "--allow-lossy", text=text).returncode, 0)
            self.assertEqual(backup.read_bytes(), b"keep me")
            self.assertEqual(self.db.execute("SELECT count(*) FROM workspace_groups").fetchone()[0], 1)

    def test_unsupported_requires_explicit_acceptance(self):
        result = self.cli("--apply", text="import\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--allow-lossy", result.stderr)

    def test_transaction_rolls_back(self):
        plan = self.plan()
        # Force a failure after group insertion, before commit.
        self.db.execute("CREATE TRIGGER refuse_terminal BEFORE INSERT ON workspace_terminals BEGIN SELECT RAISE(ABORT,'test'); END")
        self.db.commit()
        with self.assertRaises(sqlite3.IntegrityError):
            importer.apply_plan(self.db, plan)
        self.assertEqual(self.db.execute("SELECT count(*) FROM workspace_groups").fetchone()[0], 1)
        self.assertEqual(self.db.execute("SELECT epoch FROM workspace_meta").fetchone()[0], "old")

    def test_schema_and_limits(self):
        self.db.execute("PRAGMA user_version=9")
        with self.assertRaisesRegex(ValueError, "schema 8"):
            self.plan()
        self.db.execute("PRAGMA user_version=8")
        self.db.executemany("INSERT INTO workspace_groups VALUES(?,1,X'80')", [(f"g{i}",) for i in range(30)])
        with self.assertRaisesRegex(ValueError, "32 groups"):
            self.plan()

    def test_tasks_and_agent_terminals_are_reported(self):
        self.source.write_text(self.source.read_text().replace("terminal_count=1", "terminal_count=2\ntask_count=1") + """
[Task0]
id=task
parent=one
title=Task
[Terminal1]
terminal_id=agent
parent=one
kind=codex
cwd=/old
""")
        plan = self.plan()
        self.assertEqual(len(plan["terminals"]), 1)
        self.assertTrue(any(s["section"] == "Task0" for s in plan["skipped"]))
        self.assertTrue(any(s["section"] == "Terminal1" for s in plan["skipped"]))
        self.source.write_text(self.source.read_text().replace("parent=two", "parent=task"))
        self.assertEqual(self.plan()["terminals"], [])

    def test_wire_bytes(self):
        # Standard MessagePack integer-keyed map, including nil and booleans.
        self.assertEqual(importer.pack({1: "id", 2: None, 3: False, 4: 1000}),
                         bytes.fromhex("8401a2696402c003c204ce000003e8"))
        self.assertEqual(importer.unescape(r"a\\b\sc\n"), "a\\b c\n")
        with self.assertRaises(ValueError):
            importer.unescape("trailing\\")


if __name__ == "__main__":
    unittest.main()
