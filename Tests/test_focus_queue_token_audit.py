import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "Scripts"))
from focus_queue_token_audit import (
    audit,
    estimate,
    render_report,
    strip_swift_interpolations,
    swift_func_span,
    swift_let_string,
    swift_static_chars,
)


FIXTURE = '''
public enum Demo {
    static let rule = "Write only durable facts."

    public func detailed(name: String) -> String {
        let prompt = name.isEmpty ? "Wait for instruction." : name
        return """
        Header \\(name) done.
        Rule: \\(Self.rule)
        """ + prompt + "tail \\(name)"
    }

    public func compact() -> String { "small" }
}
'''


class TokenAuditTests(unittest.TestCase):
    def test_estimate_bounds(self):
        result = estimate(400)
        self.assertEqual(result["tokens"], 100)
        self.assertEqual(result["tokens_low"], 80)
        self.assertEqual(result["tokens_high"], 133)

    def test_strip_interpolations(self):
        self.assertEqual(strip_swift_interpolations("a \\(f(x, 1)) b"), "a  b")
        self.assertEqual(strip_swift_interpolations("\\(a + (b))c"), "c")

    def test_func_span_stops_at_matching_brace(self):
        span = swift_func_span(FIXTURE, "func detailed(")
        self.assertIn("Header", span)
        self.assertNotIn("small", span)

    def test_static_chars_count_literals_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Demo.swift"
            path.write_text(FIXTURE)
            detailed = swift_static_chars(path, "func detailed(")
            # Multiline body (dedented): "Header \\(name) done.\nRule: \\(Self.rule)\n"
            # -> "Header  done.\nRule: \n" = 21, plus "Wait for instruction." = 21, plus "tail " = 5
            self.assertEqual(detailed, 21 + 21 + 5)
            self.assertEqual(swift_let_string(path, "rule"), len("Write only durable facts."))

    def test_audit_on_fixture_repo(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Config").mkdir()
            (root / "Config/CLAUDE_GLOBAL_INSTRUCTIONS.md").write_text("x" * 400)
            result = audit(root, session_bin="/nonexistent/focus-queue-session")
            names = [c["component"] for c in result["components"]]
            self.assertIn("Global agent contract (claude)", names)
            self.assertEqual(result["components"][0]["tokens"], 100)
            self.assertTrue(result["scenarios"]["single_agent_launch"]["tokens"] >= 100)
            report = render_report(result)
            self.assertIn("# Focus Queue token audit", report)
            self.assertIn("Global agent contract (claude)", report)

    def test_cli_writes_json_and_report(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            output = tmp_path / "audit.json"
            report = tmp_path / "audit.md"
            script = Path(__file__).parents[1] / "Scripts" / "focus_queue_token_audit.py"
            subprocess.run(
                [sys.executable, str(script), "--repo-root", str(tmp_path),
                 "--session-bin", "/nonexistent/focus-queue-session",
                 "--json-output", str(output), "--report-output", str(report)],
                check=True,
            )
            parsed = json.loads(output.read_text())
            self.assertEqual(parsed["repo_root"], str(tmp_path.resolve()))
            self.assertIn("Scenarios", report.read_text())


if __name__ == "__main__":
    unittest.main()
