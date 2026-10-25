import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import focus_queue_prompt_usage as usage


class PromptUsageTests(unittest.TestCase):
    def test_records_counts_without_prompt_text(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict("os.environ", {"FOCUS_QUEUE_SUPPORT_DIR": directory}):
                usage.record("placement", "app_context", prompt="private prompt body")
                usage.record_provider_usage("codex", "test-model", {"inputTokens": 21, "outputTokens": 5})
            path = Path(directory) / "analytics/prompt-usage.jsonl"
            raw = path.read_text()
            rows = [json.loads(line) for line in raw.splitlines()]
            self.assertEqual(rows[0]["characters"], len("private prompt body"))
            self.assertEqual(rows[1]["actualInputTokens"], 21)
            self.assertNotIn("private prompt body", raw)

    def test_instruction_files_split_contract_and_share_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            documents = root / "Documents"
            task = documents / "project" / "task"
            task.mkdir(parents=True)
            (documents / "AGENTS.md").write_text(
                "global\n<!-- BEGIN AGENT OUTPUT CONTRACT v1 -->contract"
                "<!-- END AGENT OUTPUT CONTRACT v1 -->\n")
            (task.parent / "AGENTS.md").write_text("project rules")
            (documents / "CLAUDE.md").write_text("claude rules")
            with patch.object(usage.Path, "home", return_value=root):
                usage.record_instruction_files(task, "codex", run_id="run-1", support=root)
            rows = [json.loads(line) for line in
                    (root / "analytics/prompt-usage.jsonl").read_text().splitlines()]
            self.assertEqual({row["runID"] for row in rows}, {"run-1"})
            self.assertEqual({row["component"] for row in rows},
                             {"AGENTS.md · output_contract", "AGENTS.md · other_instructions",
                              "project/AGENTS.md · other_instructions"})
            self.assertEqual(sum(row["characters"] for row in rows),
                             len((documents / "AGENTS.md").read_text()) + len("project rules"))


if __name__ == "__main__":
    unittest.main()
