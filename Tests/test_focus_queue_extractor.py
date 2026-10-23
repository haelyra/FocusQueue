import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EXTRACTOR = load("focus_queue_extractor", "focus_queue_extractor.py")

CATALOG = {"id": "focus-queue", "name": "Focus Queue", "description": "",
           "tasks": [{"id": "FOC-010", "title": "Extractor", "summary": "Data extractor."},
                     {"id": "FOC-013", "title": "Embeddings", "summary": "Embedding search."}]}
PROMPT = ("Fix the grader. Going forward on this project, always log errors to stderr. "
          "The embedding index needs incremental rebuilds, leave that for the embedding task. "
          "For all of my projects, keep commits under 72 characters.")


def atom(**overrides):
    value = {"quote": "Going forward on this project, always log errors to stderr.",
             "text": "Always log errors to stderr.", "kind": "preference",
             "destination": "project", "target_id": "focus-queue", "confidence": 0.95,
             "title": "Stderr Error Logging", "rationale": "Project-wide practice."}
    value.update(overrides)
    return value


class ValidateAtomTests(unittest.TestCase):
    def check(self, value, prompt=PROMPT, threshold=0.85):
        return EXTRACTOR.validate_atom(value, CATALOG, prompt, threshold)

    def test_valid_project_preference_passes(self):
        clean, reason = self.check(atom())
        self.assertIsNone(reason)
        self.assertEqual(clean["destination"], "project")
        self.assertEqual(clean["target_id"], "focus-queue")

    def test_user_scope_requires_explicit_cross_project_wording(self):
        clean, reason = self.check(atom(destination="user", target_id="user"))
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("scope evidence", reason)

    def test_user_scope_with_explicit_wording_passes(self):
        value = atom(destination="user", target_id="user",
                     quote="For all of my projects, keep commits under 72 characters.",
                     text="Keep commits under 72 characters.")
        clean, reason = self.check(value)
        self.assertIsNone(reason)
        self.assertEqual(clean["target_id"], "user")

    def test_only_preferences_are_user_or_project_scoped(self):
        clean, reason = self.check(atom(kind="deferred"))
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("preferences", reason)

    def test_task_target_must_be_listed(self):
        value = atom(destination="task", target_id="FOC-999",
                     quote="The embedding index needs incremental rebuilds, leave that for the embedding task.",
                     text="Add incremental rebuilds.", kind="deferred")
        clean, reason = self.check(value)
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("unknown or closed task", reason)

    def test_listed_task_target_passes_and_normalizes_case(self):
        value = atom(destination="task", target_id="foc-013",
                     quote="The embedding index needs incremental rebuilds, leave that for the embedding task.",
                     text="Add incremental rebuilds.", kind="deferred")
        clean, reason = self.check(value)
        self.assertIsNone(reason)
        self.assertEqual(clean["target_id"], "FOC-013")

    def test_new_task_must_be_deferred_or_decision(self):
        value = atom(destination="new_task", kind="reference")
        clean, reason = self.check(value)
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("deferred work or decisions", reason)

    def test_low_confidence_goes_to_inbox(self):
        clean, reason = self.check(atom(confidence=0.5))
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("below threshold", reason)

    def test_quote_must_appear_verbatim(self):
        clean, reason = self.check(atom(quote="This sentence is not in the prompt."))
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("verbatim", reason)

    def test_inbox_records_proposed_destination(self):
        clean, _ = self.check(atom(confidence=0.1))
        self.assertEqual(clean["proposed_destination"], "project")

    def test_non_numeric_confidence_rejected(self):
        clean, reason = self.check(atom(confidence="high"))
        self.assertIsNone(clean)
        self.assertIn("confidence", reason)

    def test_unknown_kind_rejected(self):
        clean, reason = self.check(atom(kind="wish"))
        self.assertIsNone(clean)

    def test_verbose_memory_is_inboxed(self):
        clean, reason = self.check(atom(text="First fact. Second fact. Third fact."))
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("two sentences", reason)
        clean, reason = self.check(atom(text="A" * 201))
        self.assertEqual(clean["destination"], "inbox")
        self.assertIn("200 characters", reason)

    def test_short_deferred_memory_is_accepted(self):
        clean, reason = self.check(atom(destination="task", target_id="FOC-013",
            quote="The embedding index needs incremental rebuilds, leave that for the embedding task.",
            text="Add incremental rebuilds to the embedding index.", kind="deferred"))
        self.assertIsNone(reason)
        self.assertEqual(clean["destination"], "task")


class GradeTests(unittest.TestCase):
    def record(self, atoms):
        return {"projectID": "focus-queue", "atoms": atoms, "inboxed": 0}

    def test_perfect_run(self):
        record = self.record([atom(destination="task", target_id="FOC-013")])
        expected = {"placements": [{"text": "x", "destination": "task", "target_id": "FOC-013"}]}
        result = EXTRACTOR.grade(record, expected)
        self.assertEqual(result["recall"], 1.0)
        self.assertEqual(result["precision"], 1.0)

    def test_missed_gold_hurts_recall(self):
        record = self.record([])
        expected = {"placements": [{"text": "x", "destination": "project", "target_id": "focus-queue"}]}
        result = EXTRACTOR.grade(record, expected)
        self.assertEqual(result["recall"], 0.0)
        self.assertEqual(result["precision"], 1.0)

    def test_extra_atom_hurts_precision(self):
        record = self.record([atom(destination="project", target_id="focus-queue"),
                              atom(destination="task", target_id="FOC-010", text="extra")])
        expected = {"placements": [{"text": "x", "destination": "project", "target_id": "focus-queue"}]}
        result = EXTRACTOR.grade(record, expected)
        self.assertEqual(result["precision"], 0.5)
        self.assertEqual(result["extra"], ["extra"])

    def test_inbox_atoms_are_abstentions_not_false_positives(self):
        record = self.record([dict(atom(), destination="inbox")])
        expected = {"placements": [{"text": "x", "destination": "project", "target_id": "focus-queue"}]}
        result = EXTRACTOR.grade(record, expected)
        self.assertEqual(result["produced"], 0)
        self.assertEqual(result["precision"], 1.0)
        self.assertEqual(result["recall"], 0.0)

    def test_empty_expectation_with_no_atoms_scores_perfect(self):
        result = EXTRACTOR.grade(self.record([]), {"placements": []})
        self.assertEqual(result["recall"], 1.0)
        self.assertEqual(result["precision"], 1.0)

    def test_empty_expectation_with_atoms_scores_zero_recall(self):
        result = EXTRACTOR.grade(self.record([atom()]), {"placements": []})
        self.assertEqual(result["recall"], 0.0)
        self.assertEqual(result["precision"], 0.0)


class ExtractFlowTests(unittest.TestCase):
    def test_extract_with_fake_runner_and_ledger(self):
        import tempfile
        reply = ({"atoms": [atom()]}, {"input": 100, "output": 50})

        def runner(command, stdin, cwd, environment, timeout):
            if command[1] == "-p":  # claude
                import json
                return json.dumps({"structured_output": reply[0],
                                   "usage": {"input_tokens": 100, "output_tokens": 50}}), ""
            raise AssertionError("unexpected provider command")

        with tempfile.TemporaryDirectory() as directory:
            environment = {"FOCUS_QUEUE_SUPPORT_DIR": directory,
                           "FOCUS_QUEUE_EXTRACTION_LEDGER": str(Path(directory) / "ledger.sqlite"),
                           "FOCUS_QUEUE_PLACEMENT_CLAUDE_EXECUTABLE": "/bin/echo",
                           "PATH": ""}
            settings = {"provider": "claude", "model": "haiku", "effort": "low",
                        "threshold": 0.85, "timeout": 5}
            record = EXTRACTOR.extract(PROMPT, CATALOG, current_task_id="FOC-010",
                                       settings=settings, environment=environment,
                                       runner=lambda *args: runner(*args))
            self.assertNotIn("error", record)
            self.assertEqual(record["accepted"], 1)
            self.assertEqual(record["usage"], {"input": 100, "output": 50,
                                               "cache_read": 0, "cache_created": 0})
            import sqlite3
            rows = sqlite3.connect(str(Path(directory) / "ledger.sqlite")).execute(
                "SELECT accepted, input_tokens, output_tokens FROM extractions").fetchall()
            self.assertEqual(rows, [(1, 100, 50)])


class ApplyTests(unittest.TestCase):
    def test_accepted_facts_fill_only_their_scoped_files_and_are_idempotent(self):
        import json
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            environment = {"FOCUS_QUEUE_SUPPORT_DIR": directory,
                           "FOCUS_QUEUE_SESSION_EXECUTABLE": "/bin/echo", "PATH": ""}
            record = {"projectID": "space-site", "atoms": [
                {"destination": "project", "target_id": "space-site",
                 "text": "Use an all-gray theme with blue accents. Never use beige."},
                {"destination": "task", "target_id": "WEB-002",
                 "text": "Provide a demo video version shorter than 10 seconds."},
                {"destination": "new_task", "target_id": "space-site",
                 "title": "Company Instagram account", "text": "Create a company Instagram account."},
                {"destination": "new_task", "target_id": "space-site",
                 "title": "Decide contacts page", "text": "Decide whether to create a contacts page."},
                {"destination": "inbox", "target_id": "space-site", "text": "Ignore this."},
            ]}
            catalog = {"id": "space-site", "tasks": [{"id": "WEB-001"}, {"id": "WEB-002"}]}
            calls = []
            for relative in ("projects/space-site/data.md", "tasks/WEB-002/data.md"):
                path = Path(directory) / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("")

            def runner(command, **kwargs):
                calls.append(command)
                return subprocess.CompletedProcess(command, 0,
                    json.dumps({"taskID": f"WEB-{len(calls) + 2:03d}", "created": "true"}), "")

            receipts = EXTRACTOR.apply_record(record, catalog, environment=environment,
                                              command_runner=runner)
            root = Path(directory)
            self.assertEqual((root / "projects/space-site/data.md").read_text(),
                             "- Use an all-gray theme with blue accents. Never use beige.\n")
            self.assertEqual((root / "tasks/WEB-002/data.md").read_text(),
                             "- Provide a demo video version shorter than 10 seconds.\n")
            self.assertFalse((root / "tasks/WEB-001/data.md").exists())
            self.assertEqual(len(calls), 2)
            self.assertEqual([x["target_id"] for x in receipts if x["destination"] == "new_task"],
                             ["WEB-003", "WEB-004"])
            EXTRACTOR.apply_record(record, catalog, environment=environment,
                                   command_runner=runner)
            self.assertEqual((root / "projects/space-site/data.md").read_text().count("Never use beige."), 1)

    def test_verbose_or_wrong_target_cannot_be_applied(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            environment = {"FOCUS_QUEUE_SUPPORT_DIR": directory}
            catalog = {"id": "space-site", "tasks": [{"id": "WEB-002"}]}
            with self.assertRaises(EXTRACTOR.ExtractorError):
                EXTRACTOR.apply_record({"projectID": "space-site", "atoms": [
                    {"destination": "task", "target_id": "WEB-999", "text": "Do this."}]},
                    catalog, environment=environment)
            self.assertFalse((Path(directory) / "tasks/WEB-999/data.md").exists())


if __name__ == "__main__":
    unittest.main()
