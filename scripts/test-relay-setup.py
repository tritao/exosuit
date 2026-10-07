#!/usr/bin/env python3
"""Relay origin validation and private persisted setup used by the desktop panel."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('workspace_manager', Path(__file__).with_name('run-agent.py'))
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class RelaySetupTests(unittest.TestCase):
    def test_origin_validation(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(manager.validate_relay_origin(' https://relay.example:8443/ '), 'https://relay.example:8443')
            for origin in ['', 'http://relay.example', 'http://localhost:8080', 'https://user:password@relay.example',
                           'https://relay.example/path', 'https://relay.example?token=secret', 'https://relay.example#fragment',
                           'https://relay.example:0', 'https://relay.example:65536']:
                with self.subTest(origin=origin), self.assertRaises(RuntimeError):
                    manager.validate_relay_origin(origin)
        with patch.dict(os.environ, {'EXOSUIT_RELAY_ALLOW_LOOPBACK_HTTP': '1'}):
            self.assertEqual(manager.validate_relay_origin('http://127.0.0.1:8080'), 'http://127.0.0.1:8080')

    def test_persisted_setup_reuses_identity(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {}, clear=True):
            directory = Path(temporary)
            self.assertIsNone(manager.make_relay_bootstrap(directory))
            manager.atomic_json(directory / 'relay-settings.json', {'version': 1, 'origin': 'https://relay.example'})
            bootstrap = manager.make_relay_bootstrap(directory)
            first = json.loads(bootstrap.read_text())
            self.assertEqual(first['origin'], 'https://relay.example')
            self.assertEqual(bootstrap.stat().st_mode & 0o777, 0o600)
            bootstrap.unlink()
            second = json.loads(manager.make_relay_bootstrap(directory).read_text())
            self.assertEqual(first['machineId'], second['machineId'])
            self.assertNotEqual(first['bootstrapToken'], second['bootstrapToken'])
            (directory / 'relay-settings.json').chmod(0o644)
            with self.assertRaises(RuntimeError):
                manager.make_relay_bootstrap(directory)


if __name__ == '__main__':
    unittest.main()
