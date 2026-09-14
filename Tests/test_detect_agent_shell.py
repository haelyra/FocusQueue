import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Scripts" / "detect_agent_shell.py"
spec = importlib.util.spec_from_file_location("detect_agent_shell", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AgentShellScanTests(unittest.TestCase):
    def test_aliases_and_functions_are_detected_without_executing_or_storing_definitions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sentinel = root / "must-not-exist"
            (root / ".zshrc").write_text(
                f"touch '{sentinel}'\nalias codex='SECRET_ALIAS_VALUE codex --dangerous'\n"
                "function claude() { SECRET_FUNCTION_VALUE; }\n"
            )
            result = module.scan(root, "/bin/zsh")
            self.assertEqual(result["providers"]["codex"]["kinds"], ["alias"])
            self.assertEqual(result["providers"]["claude"]["kinds"], ["function"])
            self.assertNotIn("SECRET", json.dumps(result))
            self.assertFalse(sentinel.exists())

    def test_bash_detection_and_atomic_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".bashrc").write_text("codex () { :; }\nalias claude='claude --verbose'\n")
            destination = root / "support" / "agent-shell.json"
            subprocess.run(["/usr/bin/python3", str(SCRIPT), "--home", str(root),
                            "--shell", "/bin/bash", "--output", str(destination)], check=True)
            result = json.loads(destination.read_text())
            self.assertEqual(result["providers"]["codex"]["kinds"], ["function"])
            self.assertEqual(result["providers"]["claude"]["kinds"], ["alias"])
            self.assertEqual(result["scanMode"], "static")


if __name__ == "__main__":
    unittest.main()
