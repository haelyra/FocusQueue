import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location(
    "focus_queue_placement_eval", ROOT / "Scripts" / "focus_queue_placement_eval.py")
EVAL = importlib.util.module_from_spec(spec)
spec.loader.exec_module(EVAL)


class PlacementEvalTests(unittest.TestCase):
    def test_first_prompt_is_new_work_and_later_prompts_join_the_task(self):
        with tempfile.TemporaryDirectory(prefix="placement eval ") as directory:
            support = Path(directory)
            placements = support / "tracking" / "placements"
            placements.mkdir(parents=True)
            prompts = [
                ("1", "FOC-001", "Codex · 57a656\n\nFix the clipboard so tmux copies reach macOS"),
                ("2", "FOC-001", "pbpaste is still empty after copying from a tmux pane today"),
                ("3", "FOC-002", "Agent 6\n\nCodex agent"),
                ("4", "FOC-003", "Continue FOC-001 and also check the resize handling please"),
            ]
            for generated, task, prompt in prompts:
                (placements / f"{generated}.json").write_text(json.dumps(
                    {"generatedAt": generated, "taskID": task, "promptHint": prompt,
                     "workspacePath": "/repo"}))
            cases = EVAL.build_cases(support)
        self.assertEqual([(case["expected"], case["kind"], case["exclude"]) for case in cases],
                         [("new", "real-new", ["FOC-001"]), ("FOC-001", "real-existing", [])])
        self.assertEqual(cases[0]["prompt"], "Fix the clipboard so tmux copies reach macOS")

    def test_scoring_separates_error_kinds(self):
        new, existing = {"expected": "new"}, {"expected": "FOC-001"}
        self.assertEqual(EVAL.score(new, {"status": "new-task"}), "correct")
        self.assertEqual(EVAL.score(new, {"status": "project-inbox"}), "correct")
        self.assertEqual(EVAL.score(new, {"status": "task", "taskID": "FOC-009"}), "false-match")
        self.assertEqual(EVAL.score(existing, {"status": "task", "taskID": "FOC-001"}), "correct")
        self.assertEqual(EVAL.score(existing, {"status": "task", "taskID": "FOC-009"}), "wrong-task")
        self.assertEqual(EVAL.score(existing, {"status": "new-task"}), "missed-match")
        self.assertEqual(EVAL.score(existing, {"status": "project-inbox", "modelError": "x"}), "fallback")

    def test_case_configuration_hides_and_reopens_tasks(self):
        with tempfile.TemporaryDirectory(prefix="placement eval ") as directory:
            directory = Path(directory)
            dashboard = directory / "source.json"
            dashboard.write_text(json.dumps({"tickets": [
                {"id": "FOC-001", "status": "resolved"}, {"id": "FOC-002", "status": "backlog"}]}))
            configuration = {"focusQueueProjects": [{"id": "focus", "dashboardPath": str(dashboard)}]}
            path = EVAL.case_configuration(configuration, ["foc-002"], ["FOC-001"], directory,
                                           {"placementTimeoutSeconds": 60})
            copied = json.loads(path.read_text())
            tickets = json.loads(Path(copied["focusQueueProjects"][0]["dashboardPath"]).read_text())["tickets"]
            self.assertEqual(tickets, [{"id": "FOC-001", "status": "in-progress"}])
            self.assertEqual(copied["placementTimeoutSeconds"], 60)
            self.assertEqual(json.loads(dashboard.read_text())["tickets"][0]["status"], "resolved")


if __name__ == "__main__":
    unittest.main()
