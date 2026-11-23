import contextlib
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "Scripts/t3_contract_probe.py"
FIXTURES = Path(__file__).parent / "Fixtures" / "T3"
SPEC = importlib.util.spec_from_file_location("t3_contract_probe", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["t3_contract_probe"] = MODULE
SPEC.loader.exec_module(MODULE)

THREAD = "mcp:launch:" + "ab" * 32
PROJECT = "3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b0c"
ENVIRONMENT = "f95d287c-1111-2222-3333-444455556666"
REQUEST = "req-7c9e6679-7425-40de-944b-e07fc1f90ae7"
HOME_REPO = "/Users/someone/Development/scratch/repo"


class SSEParserTests(unittest.TestCase):
    def test_parses_events_with_names_ids_comments_and_multiline_data(self):
        text = (": keep-alive\n"
                "event: message\nid: 7\ndata: {\"a\":\ndata: 1}\n ignored: x\n\n"
                "data: second\r\n\r\n"
                "data: tail-without-blank-line")
        events = MODULE.parse_sse(text)
        self.assertEqual([e["data"] for e in events], ['{"a":\n1}', "second", "tail-without-blank-line"])
        self.assertEqual(events[0]["id"], "7")
        self.assertEqual(events[0]["event"], "message")

    def test_field_without_space_and_empty_dispatch(self):
        events = MODULE.parse_sse("data:x\n\n\n\nevent: ping\n\n")
        self.assertEqual(events[0]["data"], "x")
        self.assertEqual(events[1]["event"], "ping")
        self.assertEqual(len(events), 2)

    def test_incremental_parser_matches_batch(self):
        parser = MODULE.SSEParser()
        lines = ["data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/events/active\"}\n", "\n"]
        results = [parser.feed_line(line) for line in lines]
        self.assertIsNone(results[0])
        self.assertEqual(json.loads(results[1]["data"])["method"], "notifications/events/active")

    def test_rpc_response_is_last_message_with_matching_id(self):
        text = (
            'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}\n\n'
            'data: {"jsonrpc":"2.0","id":3,"result":{"old":true}}\n\n'
            'data: not json\n\n'
            'data: {"jsonrpc":"2.0","id":4,"result":{"ok":true}}\n\n'
        )
        messages = MODULE.rpc_messages_from_sse(text)
        self.assertEqual(len(messages), 3)
        self.assertEqual(MODULE.select_rpc_response(messages, 4)["result"], {"ok": True})
        self.assertEqual(MODULE.select_rpc_response(messages, 99)["result"], {"ok": True})
        with self.assertRaises(MODULE.ProbeError):
            MODULE.select_rpc_response(messages[:1], 4)


class SanitizerTests(unittest.TestCase):
    def sanitize(self, value, prepare=None):
        sanitizer = MODULE.Sanitizer()
        if prepare:
            prepare(sanitizer)
        sanitizer.observe(value)
        return sanitizer, sanitizer.value(value)

    def test_ids_by_key_become_stable_placeholders_everywhere(self):
        value = {
            "threadId": THREAD, "projectId": PROJECT, "environmentId": ENVIRONMENT,
            "link": f"t3://threads/{THREAD}",
            "rows": [{"threadId": THREAD, "parentThreadId": None}],
            "requestIds": [REQUEST],
        }
        _, clean = self.sanitize(value)
        self.assertEqual(clean["threadId"], "THREAD_1")
        self.assertEqual(clean["projectId"], "PROJECT_1")
        self.assertEqual(clean["environmentId"], "ENVIRONMENT_1")
        self.assertEqual(clean["link"], "t3://threads/THREAD_1")
        self.assertEqual(clean["rows"][0], {"threadId": "THREAD_1", "parentThreadId": None})
        self.assertEqual(clean["requestIds"], ["REQUEST_1"])

    def test_ids_inside_json_text_content_are_found(self):
        payload = {"threadId": THREAD, "status": "running", "worktreePath": HOME_REPO + "/.worktrees/a1"}
        result = {"content": [{"type": "text", "text": json.dumps(payload)}], "isError": False}
        _, clean = self.sanitize(result)
        inner = json.loads(clean["content"][0]["text"])
        self.assertEqual(inner["threadId"], "THREAD_1")
        self.assertEqual(inner["worktreePath"], "/HOME/Development/scratch/repo/.worktrees/a1")

    def test_registered_paths_win_over_home_fallback(self):
        def prepare(sanitizer):
            sanitizer.register_path(HOME_REPO, "/REPO")
        value = {"worktreePath": HOME_REPO + "/.worktrees/foc-1/agents/a1", "other": "/Volumes/HOME/projects/x"}
        _, clean = self.sanitize(value, prepare)
        self.assertEqual(clean["worktreePath"], "/REPO/.worktrees/foc-1/agents/a1")
        self.assertEqual(clean["other"], "/HOME/projects/x")

    def test_temp_folders_tokens_and_project_ids(self):
        value = {
            "project": {"id": "proj-123456", "title": "fq-contract-probe", "workspaceRoot": "/tmp/x"},
            "path": "/private/var/folders/ab/cd123/T/fq-contract-probe-1/repo",
            "auth": "Bearer abc.def-ghi",
            "access_token": "secret-token-value",
            "echo": "token secret-token-value used",
        }
        _, clean = self.sanitize(value)
        self.assertEqual(clean["project"]["id"], "PROJECT_1")
        self.assertEqual(clean["path"], "/TMP/fq-contract-probe-1/repo")
        self.assertEqual(clean["auth"], "Bearer TOKEN")
        self.assertEqual(clean["access_token"], "TOKEN")
        self.assertEqual(clean["echo"], "token TOKEN used")

    def test_uuid_and_launch_id_fallbacks_are_consistent(self):
        sanitizer = MODULE.Sanitizer()
        other = "0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0"
        first = sanitizer.text(f"{other} and {THREAD}")
        second = sanitizer.text(f"{THREAD} again {other}")
        self.assertEqual(first, "UUID_1 and THREAD_1")
        self.assertEqual(second, "THREAD_1 again UUID_1")

    def test_short_values_and_non_strings_are_not_registered(self):
        _, clean = self.sanitize({"runId": "r1", "eventId": None, "ordinal": 1, "note": "r1 stays"})
        self.assertEqual(clean, {"runId": "r1", "eventId": None, "ordinal": 1, "note": "r1 stays"})

    def test_labels_and_keys_are_sanitized(self):
        def prepare(sanitizer):
            sanitizer.register_literal("Someone’s Mac Studio", "Test Mac")
        value = {"label": "Someone’s Mac Studio", "answers": {THREAD: "Option B"}, "threadId": THREAD}
        _, clean = self.sanitize(value, prepare)
        self.assertEqual(clean["label"], "Test Mac")
        self.assertEqual(clean["answers"], {"THREAD_1": "Option B"})

    def test_sse_text_is_observed_and_sanitized(self):
        event = {"jsonrpc": "2.0", "method": "notifications/events/event", "params": {
            "eventId": "evt-0001-abcdef", "name": "thread.run_settled", "cursor": "mwsp6cxs.26",
            "data": {"threadId": THREAD, "runId": "run-abcdef-1", "outcome": "completed"}}}
        text = "data: " + json.dumps(event) + "\n\n"
        sanitizer = MODULE.Sanitizer()
        sanitizer.observe_sse(text)
        clean = sanitizer.text(text)
        self.assertNotIn(THREAD, clean)
        self.assertIn("THREAD_1", clean)
        self.assertIn("RUN_1", clean)
        self.assertIn("EVENT_1", clean)
        self.assertIn("mwsp6cxs.26", clean)
        self.assertEqual(MODULE.find_leaks(clean), [])


class FixtureScannerTests(unittest.TestCase):
    def test_detects_each_leak_kind(self):
        cases = {
            "absolute /Users path": "/Users/someone/x",
            "absolute /Volumes path": "/Volumes/Data/x",
            "temporary folder path": "/var/folders/ab/T/x",
            "UUID": PROJECT,
            "launch thread id": THREAD,
            "bearer token": "Bearer abcdef",
            "token field": '"access_token": "abc"',
            "JWT": "eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0",
        }
        for name, text in cases.items():
            with self.subTest(name=name):
                self.assertIn(name, MODULE.find_leaks(text))

    def test_sanitized_text_is_clean(self):
        text = '{"threadId": "THREAD_1", "path": "/REPO/.worktrees", "auth": "Bearer TOKEN", ' \
               '"access_token": "TOKEN", "cursor": "mwsp6cxs.26"}'
        self.assertEqual(MODULE.find_leaks(text), [])

    def test_captured_fixtures_contain_no_ids_paths_or_tokens(self):
        paths = MODULE.probe_fixture_paths(FIXTURES)
        for path in paths:
            with self.subTest(fixture=path.name):
                self.assertEqual(MODULE.find_leaks(path.read_text(encoding="utf-8")), [])

    def test_write_fixtures_refuses_leaky_files(self):
        with tempfile.TemporaryDirectory() as directory:
            problems = MODULE.write_fixtures({"tool-ok.json": "{}\n", "tool-bad.json": f'"{PROJECT}"'},
                                             Path(directory))
            self.assertEqual(sorted(os.listdir(directory)), ["tool-ok.json"])
            self.assertEqual(len(problems), 1)
            self.assertIn("tool-bad.json", problems[0])


class HelperTests(unittest.TestCase):
    def test_parse_only(self):
        self.assertEqual(MODULE.parse_only(None), list(range(1, 16)))
        self.assertEqual(MODULE.parse_only("1, 3,5-7"), [1, 3, 5, 6, 7])
        with self.assertRaises(ValueError):
            MODULE.parse_only("0,16")

    def test_pkce_matches_rfc7636_example(self):
        verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        self.assertEqual(MODULE.pkce_challenge(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        generated, challenge = MODULE.pkce_pair()
        self.assertEqual(MODULE.pkce_challenge(generated), challenge)
        self.assertGreaterEqual(len(generated), 43)

    def test_token_file_is_private_and_loads(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested" / "token.json"
            MODULE.write_private_json(path, {"access_token": "abc", "scope": "orchestration:read"})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(MODULE.load_token(path)["access_token"], "abc")
            raw = Path(directory) / "raw.txt"
            raw.write_text("bare-token\n")
            self.assertEqual(MODULE.load_token(raw), {"access_token": "bare-token", "scope": ""})

    def test_tool_payload_prefers_structured_content(self):
        self.assertEqual(MODULE.tool_payload({"structuredContent": {"a": 1}, "content": []}), {"a": 1})
        text = {"content": [{"type": "text", "text": '{"_tag":"OrchestratorMcpFailure","code":"x"}'}]}
        self.assertEqual(MODULE.tool_payload(text)["code"], "x")
        self.assertEqual(MODULE.tool_payload({"content": [{"type": "text", "text": "plain"}]}), {"text": "plain"})

    def test_cursor_parsing(self):
        self.assertEqual(MODULE.parse_cursor("mwsp6cxs.26"), ("mwsp6cxs", 26))
        self.assertEqual(MODULE.parse_cursor("a.b.3"), ("a.b", 3))
        for bad in (None, "26", ".26", "abc.", "abc.x"):
            self.assertIsNone(MODULE.parse_cursor(bad))

    def test_request_headers_and_meta(self):
        client = MODULE.McpClient(MODULE.Server("http://127.0.0.1:3773"), "tok")
        headers = client.headers("tools/call", "t3_thread_read")
        self.assertEqual(headers["mcp-protocol-version"], "2026-07-28")
        self.assertEqual(headers["mcp-method"], "tools/call")
        self.assertEqual(headers["mcp-name"], "t3_thread_read")
        self.assertEqual(headers["accept"], "application/json, text/event-stream")
        self.assertNotIn("mcp-name", client.headers("server/discover", None))
        body = json.loads(client.body("tools/call", {"name": "x"}, 5))
        meta = body["params"]["_meta"]
        self.assertEqual(meta["io.modelcontextprotocol/protocolVersion"], "2026-07-28")
        self.assertIn("io.modelcontextprotocol/clientInfo", meta)
        self.assertIn("io.modelcontextprotocol/clientCapabilities", meta)
        self.assertEqual(body["id"], 5)

    def test_help_runs(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as exit_info:
            MODULE.main(["--help"])
        self.assertEqual(exit_info.exception.code, 0)
        self.assertIn("--login", output.getvalue())
        self.assertIn("--keep", output.getvalue())
        self.assertIn("--only", output.getvalue())


if __name__ == "__main__":
    unittest.main()
