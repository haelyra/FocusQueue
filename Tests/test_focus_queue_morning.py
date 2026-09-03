import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "Scripts/focus_queue_morning.py"
SPEC = importlib.util.spec_from_file_location("focus_queue_morning", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FocusQueueMorningTests(unittest.TestCase):
    def test_emlx_reader_extracts_plain_message_body(self):
        with tempfile.TemporaryDirectory() as temporary:
            payload = (
                b"From: Maintainer <maintainer@example.com>\r\n"
                b"To: agent@example.com\r\n"
                b"Subject: Follow up\r\n"
                b"Content-Type: text/plain; charset=utf-8\r\n"
                b"\r\nPlease review the release checklist.\r\n"
            )
            path = Path(temporary) / "42.emlx"
            path.write_bytes(str(len(payload)).encode("ascii") + b"\n" + payload)
            self.assertEqual(
                MODULE.message_text_from_emlx(path),
                "Please review the release checklist.",
            )

    def test_extract_json_accepts_plain_and_fenced_objects(self):
        self.assertEqual(MODULE.extract_json('{"version":1}'), {"version": 1})
        self.assertEqual(MODULE.extract_json('```json\n{"version":1}\n```'), {"version": 1})

    def test_apply_creates_a_valid_task_and_deduplicates_source_urls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dashboard = root / "dashboard.json"
            dashboard.write_text(
                json.dumps(
                    {
                        "meta": {"repository": "affaan-m/ECC"},
                        "tickets": [
                            {
                                "id": "ECC-044",
                                "title": "Existing",
                                "priority": "high",
                                "status": "backlog",
                                "summary": "Existing summary",
                                "updatedAt": "2026-09-01",
                                "resolutionPrs": [],
                                "prs": [],
                                "links": [],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            package = root / "package.json"
            package.write_text(
                json.dumps({"scripts": {"check": "node -e ''"}}),
                encoding="utf-8",
            )
            config = {
                "dashboardPath": str(dashboard),
                "dashboardDirectory": str(root),
                "maxNewTasksPerRun": 20,
            }
            proposal = {
                "newTasks": [
                    {
                        "title": "Investigate reported failure",
                        "category": "Bug",
                        "priority": "high",
                        "summary": "A maintainer reported a reproducible failure.",
                        "next": "Reproduce the failure.",
                        "doneWhen": "The cause is fixed and regression tested.",
                        "sourceLinks": [
                            {
                                "label": "Discord report",
                                "url": "https://discord.com/channels/1/2/3",
                                "type": "discord",
                            }
                        ],
                    },
                    {
                        "title": "Duplicate report",
                        "category": "Bug",
                        "priority": "medium",
                        "summary": "Same source.",
                        "next": "Do the same thing.",
                        "doneWhen": "Done.",
                        "sourceLinks": [
                            {
                                "label": "Same report",
                                "url": "https://discord.com/channels/1/2/3",
                                "type": "discord",
                            }
                        ],
                    },
                ],
                "updates": [],
            }
            result = MODULE.apply_proposals(config, proposal, root / "runtime")
            updated = json.loads(dashboard.read_text(encoding="utf-8"))
            self.assertEqual(result["created"], ["ECC-045"])
            self.assertEqual(updated["tickets"][0]["id"], "ECC-045")
            self.assertEqual(updated["tickets"][0]["status"], "backlog")

    def test_updates_only_fill_missing_next_and_add_new_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dashboard = root / "dashboard.json"
            dashboard.write_text(
                json.dumps(
                    {
                        "tickets": [
                            {
                                "id": "ECC-001",
                                "title": "Existing",
                                "priority": "critical",
                                "status": "in-progress",
                                "summary": "Human summary",
                                "next": "Human next action",
                                "updatedAt": "2026-09-01",
                                "resolutionPrs": [],
                                "prs": [],
                                "links": [],
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            (root / "package.json").write_text(
                json.dumps({"scripts": {"check": "node -e ''"}}),
                encoding="utf-8",
            )
            config = {
                "dashboardPath": str(dashboard),
                "dashboardDirectory": str(root),
                "maxNewTasksPerRun": 20,
            }
            result = MODULE.apply_proposals(
                config,
                {
                    "newTasks": [],
                    "updates": [
                        {
                            "ticketId": "ECC-001",
                            "next": "Model replacement",
                            "sourceLinks": [
                                {
                                    "label": "Issue",
                                    "url": "https://github.com/affaan-m/ECC/issues/1",
                                    "type": "github",
                                }
                            ],
                        }
                    ],
                },
                root / "runtime",
            )
            ticket = json.loads(dashboard.read_text(encoding="utf-8"))["tickets"][0]
            self.assertEqual(result["updated"], ["ECC-001"])
            self.assertEqual(ticket["next"], "Human next action")
            self.assertEqual(ticket["priority"], "critical")
            self.assertEqual(len(ticket["links"]), 1)


if __name__ == "__main__":
    unittest.main()
