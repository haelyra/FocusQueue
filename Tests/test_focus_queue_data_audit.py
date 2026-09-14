import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "Scripts"))
from focus_queue_data_audit import audit, render_report


class DataAuditTests(unittest.TestCase):
    def test_audit_counts_metadata_and_omits_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "support"
            task = root / "tasks" / "ECC-001"
            task.mkdir(parents=True)
            (task / "context.json").write_text(json.dumps({"ticketID": "ECC-001", "title": "Example", "summary": "x", "updatedAt": "today"}))
            (task / "plan.md").write_text("secret plan text")
            (task / "conversation.json").write_text(json.dumps([{"role": "user", "content": "secret"}, {"role": "assistant", "content": "reply"}]))
            result = audit(root)
            item = result["tasks"]["items"][0]
            self.assertEqual(result["tasks"]["count"], 1)
            self.assertEqual(item["conversation_message_count"], 2)
            self.assertEqual(item["missing_context_fields"], ["worktreePath", "planPath", "subtasks", "successCriteria"])
            self.assertNotIn("secret", json.dumps(result))

    def test_missing_support_dir_is_truthful(self):
        with tempfile.TemporaryDirectory() as directory:
            result = audit(Path(directory) / "absent")
            self.assertFalse(result["exists"])
            self.assertEqual(result["gap_count"], 1)

    def test_cli_json_and_report_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            support = tmp_path / "support"
            support.mkdir()
            output = tmp_path / "audit.json"
            report = tmp_path / "audit.md"
            script = Path(__file__).parents[1] / "Scripts" / "focus_queue_data_audit.py"
            subprocess.run([sys.executable, str(script), "--support-dir", str(support), "--json-output", str(output), "--report-output", str(report)], check=True)
            parsed = json.loads(output.read_text())
            self.assertEqual(parsed["support_dir"], str(support.resolve()))
            self.assertIn("Files:", report.read_text())
            self.assertTrue(render_report(parsed).startswith("# ECC Focus Queue data audit"))

    def test_symlink_is_not_traversed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "support"
            root.mkdir()
            outside = Path(directory) / "outside"
            outside.mkdir()
            (outside / "secret.json").write_text('{"secret":"body"}')
            (root / "link").symlink_to(outside, target_is_directory=True)
            result = audit(root)
            self.assertEqual(result["files"]["total"], 0)
            self.assertNotIn("secret", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
