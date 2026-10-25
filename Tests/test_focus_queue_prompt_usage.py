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


if __name__ == "__main__":
    unittest.main()
