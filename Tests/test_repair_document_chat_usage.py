import importlib.util
from datetime import datetime, timezone
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('repair', Path(__file__).parents[1] / 'Scripts/repair_document_chat_usage.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairTests(unittest.TestCase):
    def test_only_request_turns_count_and_ambiguous_evidence_is_skipped(self):
        event = dict(id='e', actualInputTokens=1100, actualOutputTokens=110,
                     timestamp='2026-10-29T23:45:23Z', actualTotalTokens=1210)
        def row(time, total, last):
            return dict(timestamp=time, payload=dict(type='token_count', info=dict(
                total_token_usage=dict(input_tokens=total, output_tokens=total // 10),
                last_token_usage=dict(input_tokens=last, output_tokens=last // 10))))
        rows = [row('2026-10-29T23:44:00Z', 1000, 1000),
                row('2026-10-29T23:45:23Z', 1100, 100)]
        start = datetime(2026, 10, 29, 23, 44, 24, tzinfo=timezone.utc)
        result = repair.correction(event, start, [rows])
        self.assertEqual(result['actualTotalTokens'], 110)
        self.assertEqual(result['id'], 'e')
        self.assertIsNone(repair.correction(event, start, [rows, rows]))
        self.assertIsNone(repair.correction(event, start, []))
