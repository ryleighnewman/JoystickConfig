import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


TOOL = Path(__file__).parents[1] / "inputconfigctl"
loader = importlib.machinery.SourceFileLoader("inputconfigctl", str(TOOL))
spec = importlib.util.spec_from_loader(loader.name, loader)
ctl = importlib.util.module_from_spec(spec)
loader.exec_module(ctl)


class InputConfigCTLTests(unittest.TestCase):
    def test_json_pointer_objects_arrays_and_escapes(self):
        value = {"a/b": {"~key": [1, 2]}}
        self.assertEqual(ctl.json_pointer_set(value, "/a~1b/~0key/1", 9)["a/b"]["~key"], [1, 9])

    def test_json_pointer_rejects_non_pointer(self):
        with self.assertRaises(ctl.CLIError):
            ctl.json_pointer_set({}, "relative", 1)

    def test_atomic_write_replaces_complete_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "value.json"
            ctl.atomic_write_json(path, {"v": 1})
            ctl.atomic_write_json(path, {"v": 2})
            self.assertEqual(json.loads(path.read_text()), {"v": 2})
            self.assertEqual(list(Path(tmp).glob(".*")), [])

    def test_selector_uuid_or_name(self):
        raw = "00000000-0000-0000-0000-000000000001"
        self.assertEqual(ctl.selector(raw), {"id": raw})
        self.assertEqual(ctl.selector("Desktop"), {"name": "Desktop"})

    def test_accessibility_request_dispatch(self):
        args = ctl.parser().parse_args(["accessibility", "request"])
        self.assertEqual(ctl.dispatch(args), ("accessibility.request", {}, None))

    def test_selftest_dispatch(self):
        for action in ("run", "status"):
            args = ctl.parser().parse_args(["selftest", action])
            self.assertEqual(ctl.dispatch(args), (f"selftest.{action}", {}, None))

    def test_default_protocol_root_is_shared_application_support(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("INPUTCONFIG_CLI_ROOT", None)
            self.assertEqual(
                ctl.protocol_root().relative_to(Path.home()),
                Path("Library/Application Support/InputConfig/CLI/v1"),
            )

    def test_dangerous_command_requires_yes(self):
        args = ctl.parser().parse_args(["trash", "empty"])
        with self.assertRaises(ctl.CLIError):
            ctl.dispatch(args)
        args = ctl.parser().parse_args(["--dry-run", "trash", "empty"])
        self.assertEqual(ctl.dispatch(args)[0], "trash.empty")

    def test_request_id_is_uuid_and_paths_stay_under_protocol_root(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"INPUTCONFIG_CLI_ROOT": tmp}):
            captured = {}
            def write(path, value):
                captured["path"] = path; captured["value"] = value
            with mock.patch.object(ctl, "atomic_write_json", side_effect=write), \
                 mock.patch.object(ctl.subprocess, "run"), \
                 mock.patch.object(ctl.time, "monotonic", side_effect=[0.0, 0.0, 2.0]):
                with self.assertRaises(ctl.CLIError) as cm:
                    ctl.invoke("status", {}, dry_run=False, timeout=1)
            self.assertEqual(cm.exception.exit_code, 5)
            request_id = captured["value"]["requestID"]
            self.assertEqual(str(__import__("uuid").UUID(request_id)), request_id)
            self.assertTrue(captured["path"].is_relative_to(Path(tmp).resolve()))

    def test_invalid_preset_file_rejected_client_side(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"
            path.write_text("{bad", encoding="utf-8")
            with self.assertRaises(ctl.CLIError):
                ctl.load_json_argument(str(path))


if __name__ == "__main__":
    unittest.main()
