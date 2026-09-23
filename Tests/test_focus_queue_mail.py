import importlib.util
import contextlib
import io
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).parents[1] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "focus_queue_mail.py"
SPEC = importlib.util.spec_from_file_location("focus_queue_mail", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FocusQueueMailTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.mail_root = self.root / "V10"
        data = self.mail_root / "MailData"
        data.mkdir(parents=True)
        self.index = data / "Envelope Index"
        connection = sqlite3.connect(self.index)
        connection.executescript(
            """
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE messages (
              ROWID INTEGER PRIMARY KEY, global_message_id INTEGER, sender INTEGER,
              subject_prefix TEXT, subject INTEGER, summary INTEGER, date_received INTEGER,
              mailbox INTEGER, read INTEGER, flagged INTEGER, deleted INTEGER
            );
            CREATE TABLE recipients (message INTEGER, address INTEGER);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
            CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT);
            INSERT INTO mailboxes VALUES (1, 'imap://ACCOUNT/INBOX');
            INSERT INTO addresses VALUES (1, 'haley@ecc.tools', 'Haley');
            INSERT INTO addresses VALUES (2, 'customer@example.com', 'Example Customer');
            INSERT INTO subjects VALUES (1, 'Private repository access');
            INSERT INTO summaries VALUES (1, 'Customer reports an activation outage.');
            INSERT INTO message_global_data VALUES (1, 'customer-message@example.com');
            """
        )
        connection.execute(
            "INSERT INTO messages VALUES (1, 1, 2, '', 1, 1, ?, 1, 0, 1, 0)",
            [int(time.time())],
        )
        connection.execute("INSERT INTO recipients VALUES (1, 1)")
        connection.commit()
        connection.close()

        payload = (
            b"From: Example Customer <customer@example.com>\r\n"
            b"To: haley@ecc.tools\r\n"
            b"Subject: Private repository access\r\n"
            b"Content-Type: text/plain; charset=utf-8\r\n\r\n"
            b"The customer outage still blocks private repository activation.\r\n"
        )
        message_directory = self.mail_root / "ACCOUNT/INBOX.mbox/Data/Messages"
        message_directory.mkdir(parents=True)
        (message_directory / "1.emlx").write_bytes(
            str(len(payload)).encode("ascii") + b"\n" + payload
        )
        self.config = {
            "emailAddress": "haley@ecc.tools",
            "emailMailboxes": ["INBOX"],
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_unified_mail_command_dispatches_to_gmail_provider(self):
        expected = {
            "status": "ok",
            "verified": True,
            "operation": "status",
            "connector": "ecc-focus-mail-reader",
            "provider": "gmail",
        }
        with mock.patch.object(
            MODULE.morning,
            "load_config",
            return_value={"emailProvider": "gmail"},
        ), mock.patch.object(
            MODULE,
            "invoke_reader",
            return_value=expected,
        ), mock.patch.object(
            sys,
            "argv",
            ["focus-mail", "status"],
        ), contextlib.redirect_stdout(io.StringIO()) as output:
            result = MODULE.main()

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue()), expected)

    def test_unified_mail_service_dispatches_to_gmail_provider(self):
        with mock.patch.object(
            MODULE.morning,
            "load_config",
            return_value={"emailProvider": "gmail"},
        ), mock.patch(
            "focus_queue_gmail.serve",
            return_value=0,
        ) as serve, mock.patch.object(
            sys,
            "argv",
            ["focus-mail", "serve"],
        ):
            result = MODULE.main()

        self.assertEqual(result, 0)
        serve.assert_called_once_with({"emailProvider": "gmail"})

    def test_daily_report_search_marks_the_trusted_batch_request(self):
        response = {
            "status": "ok",
            "verified": True,
            "operation": "search",
            "results": [],
            "truncated": False,
        }
        with mock.patch.object(
            MODULE.morning,
            "load_config",
            return_value={"emailProvider": "apple_mail"},
        ), mock.patch.object(
            MODULE,
            "invoke_reader",
            return_value=response,
        ) as invoke, mock.patch.object(
            sys,
            "argv",
            ["focus-mail", "search", "", "--limit", "200", "--daily-report"],
        ), contextlib.redirect_stdout(io.StringIO()):
            result = MODULE.main()

        self.assertEqual(result, 0)
        self.assertEqual(invoke.call_args.args[1]["limit"], 200)
        self.assertTrue(invoke.call_args.args[1]["dailyReport"])

    def test_search_returns_current_verified_evidence_without_full_body(self):
        with mock.patch.object(
            MODULE.morning,
            "apple_mail_store",
            return_value=(self.mail_root, self.index),
        ):
            result = MODULE.search_mail(
                self.config,
                {"query": "customer outage", "days": 30, "limit": 10},
            )

        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["verified"])
        self.assertEqual(result["connector"], "ecc-focus-mail-reader")
        self.assertEqual(result["resultCount"], 1)
        self.assertEqual(result["results"][0]["id"], "mail:1")
        self.assertIn("customer outage", result["results"][0]["snippet"].lower())
        self.assertNotIn("body", result["results"][0])

    def test_read_returns_complete_body_and_stable_message_proof(self):
        with mock.patch.object(
            MODULE.morning,
            "apple_mail_store",
            return_value=(self.mail_root, self.index),
        ):
            result = MODULE.read_mail(self.config, {"identifier": "mail:1"})

        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["verified"])
        self.assertEqual(result["message"]["mailbox"], "INBOX")
        self.assertEqual(result["message"]["messageId"], "<customer-message@example.com>")
        self.assertEqual(
            result["message"]["body"],
            "The customer outage still blocks private repository activation.",
        )
        self.assertTrue(result["message"]["url"].startswith("message://"))

    def test_reader_falls_back_to_launch_services_when_launchctl_is_denied(self):
        application = self.root / "ECC Focus Mail Reader.app"
        application.mkdir()
        nonce = "11111111-2222-3333-4444-555555555555"
        response = {
            "status": "ok",
            "verified": True,
            "operation": "status",
            "nonce": nonce,
        }
        (self.root / "mail-response.json").write_text(json.dumps(response))
        config = {
            "mailRequestDirectory": str(self.root),
            "mailResponseDirectory": str(self.root),
            "mailReaderApplication": str(application),
            "mailReaderService": "gui/503/tools.ecc.focus-mail-reader",
        }
        denied = subprocess.CompletedProcess([], 1, "", "Operation not permitted")
        opened = subprocess.CompletedProcess([], 0, "", "")

        with mock.patch.object(MODULE.uuid, "uuid4", return_value=nonce), mock.patch.object(
            MODULE.subprocess, "run", side_effect=[denied, opened]
        ) as run:
            result = MODULE.invoke_reader(config, {"operation": "status"})

        self.assertEqual(result["nonce"], nonce)
        self.assertEqual(
            run.call_args_list[0].args[0],
            ["/bin/launchctl", "kickstart", "-k", "gui/503/tools.ecc.focus-mail-reader"],
        )
        self.assertEqual(
            run.call_args_list[1].args[0],
            ["/usr/bin/open", "-g", "-n", str(application)],
        )

    def test_reader_uses_same_configured_runtime_as_python_client(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required to exercise the JavaScript mail reader contract")
        reader = SCRIPTS / "focus-queue-mail-reader.js"
        request_runtime = self.root / "connector-commands"
        response_runtime = self.root / "mail-proofs"
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
globalThis.$ = (value) => value;
const source = fs.readFileSync(process.argv[1], "utf8");
const configuredRequestRuntime = process.argv[2];
const configuredResponseRuntime = process.argv[3];
eval(source + `
const capturedReads = [];
const capturedWrites = [];
readJSON = function(path) {
  const resolved = String(path);
  capturedReads.push(resolved);
  if (resolved === CONFIG_PATH) {
    return {
      emailAddress: "haley@ecc.tools",
      emailMailboxes: ["INBOX"],
      mailRequestDirectory: configuredRequestRuntime,
      mailResponseDirectory: configuredResponseRuntime
    };
  }
  return {operation: "status", nonce: "path-contract-nonce"};
};
writePrivateJSON = function(path, payload) {
  capturedWrites.push({path: String(path), payload});
};
globalThis.Application = function() {
  const mailbox = {name() { return "INBOX"; }, messages: {id() { return []; }}};
  const account = {
    emailAddresses() { return ["haley@ecc.tools"]; },
    enabled() { return true; },
    mailboxes() { return [mailbox]; }
  };
  return {accounts() { return [account]; }};
};
run();
process.stdout.write(JSON.stringify({reads: capturedReads, writes: capturedWrites}));
`);
"""

        completed = subprocess.run(
            [node, "-e", harness, str(reader), str(request_runtime), str(response_runtime)],
            capture_output=True,
            text=True,
            check=True,
        )
        observed = json.loads(completed.stdout)
        expected_request, expected_response, _ = MODULE.request_paths(
            {
                "mailRequestDirectory": str(request_runtime),
                "mailResponseDirectory": str(response_runtime),
            }
        )

        self.assertEqual(observed["reads"][0], str(MODULE.DEFAULT_CONFIG))
        self.assertEqual(observed["reads"][1], str(expected_request))
        self.assertEqual(observed["writes"][0]["path"], str(expected_response))
        self.assertEqual(observed["writes"][0]["payload"]["nonce"], "path-contract-nonce")

    def test_legacy_environment_override_cannot_split_mail_ipc_paths(self):
        config = {
            "mailRequestDirectory": str(self.root / "commands"),
            "mailResponseDirectory": str(self.root / "proofs"),
        }
        with mock.patch.dict(
            MODULE.os.environ,
            {"FOCUS_QUEUE_CONNECTOR_PROOF_DIR": str(self.root / "legacy")},
        ):
            request, response, lock = MODULE.request_paths(config)

        self.assertEqual(request.parent, self.root / "commands")
        self.assertEqual(lock.parent, self.root / "commands")
        self.assertEqual(response.parent, self.root / "proofs")

    def test_reader_search_honors_offset_across_pages(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required to exercise the JavaScript mail reader contract")
        reader = SCRIPTS / "focus-queue-mail-reader.js"
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
globalThis.$ = (value) => value;
eval(fs.readFileSync(process.argv[1], "utf8"));
const values = [
  {id: "3", messageId: "three@example.com", date: new Date("2026-09-09T12:00:00Z")},
  {id: "2", messageId: "two@example.com", date: new Date("2026-09-09T11:00:00Z")},
  {id: "1", messageId: "one@example.com", date: new Date("2026-09-09T10:00:00Z")}
];
const messages = values.map((item) => ({
  id() { return item.id; }, messageId() { return item.messageId; }, dateReceived() { return item.date; },
  sender() { return "sender@example.com"; }, subject() { return `subject ${item.id}`; },
  readStatus() { return false; }, flaggedStatus() { return false; },
  content() { return `body ${item.id}`; }
}));
messages.id = () => values.map((item) => item.id);
messages.messageId = () => values.map((item) => item.messageId);
messages.dateReceived = () => values.map((item) => item.date);
messages.sender = () => values.map(() => "sender@example.com");
messages.subject = () => values.map((item) => `subject ${item.id}`);
messages.readStatus = () => values.map(() => false);
messages.flaggedStatus = () => values.map(() => false);
messages.slice = (start, end) => {
  const bounded = Array.prototype.slice.call(messages, start, end + 1);
  for (const property of ["id", "messageId", "dateReceived", "sender", "subject", "readStatus", "flaggedStatus"]) {
    bounded[property] = () => bounded.map((message) => message[property]());
  }
  bounded.content = () => bounded.map((message) => message.content());
  return bounded;
};
const mailbox = {name() { return "INBOX"; }, messages};
const account = {mailboxes() { return [mailbox]; }};
const result = search(
  {emailAddress: "haley@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 30, limit: 1, offset: 1},
  account
);
process.stdout.write(JSON.stringify(result));
"""

        completed = subprocess.run(
            [node, "-e", harness, str(reader)],
            capture_output=True,
            text=True,
            check=True,
        )
        result = json.loads(completed.stdout)

        self.assertEqual(result["offset"], 1)
        self.assertEqual([item["id"] for item in result["results"]], ["mail:2"])
        self.assertTrue(result["truncated"])

    def test_reader_marks_a_page_ending_at_scan_cap_as_hard_truncated(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required to exercise the JavaScript mail reader contract")
        reader = SCRIPTS / "focus-queue-mail-reader.js"
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
globalThis.$ = (value) => value;
const source = fs.readFileSync(process.argv[1], "utf8")
  .replace("const MAX_SEARCH_CANDIDATES = 5000;", "const MAX_SEARCH_CANDIDATES = 3;");
eval(source);
const values = [4, 3, 2, 1].map((id) => ({
  id: String(id),
  messageId: `${id}@example.com`,
  date: new Date(`2026-09-09T0${id}:00:00Z`)
}));
const messages = values.map((item) => ({
  id() { return item.id; }, messageId() { return item.messageId; }, dateReceived() { return item.date; },
  sender() { return "sender@example.com"; }, subject() { return `subject ${item.id}`; },
  readStatus() { return false; }, flaggedStatus() { return false; },
  content() { return `body ${item.id}`; }
}));
messages.id = () => values.map((item) => item.id);
messages.messageId = () => values.map((item) => item.messageId);
messages.dateReceived = () => values.map((item) => item.date);
messages.sender = () => values.map(() => "sender@example.com");
messages.subject = () => values.map((item) => `subject ${item.id}`);
messages.readStatus = () => values.map(() => false);
messages.flaggedStatus = () => values.map(() => false);
messages.slice = (start, end) => {
  const bounded = Array.prototype.slice.call(messages, start, end + 1);
  for (const property of ["id", "messageId", "dateReceived", "sender", "subject", "readStatus", "flaggedStatus"]) {
    bounded[property] = () => bounded.map((message) => message[property]());
  }
  bounded.content = () => bounded.map((message) => message.content());
  return bounded;
};
const mailbox = {name() { return "INBOX"; }, messages};
const account = {mailboxes() { return [mailbox]; }};
const result = search(
  {emailAddress: "haley@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 30, limit: 1, offset: 2},
  account
);
process.stdout.write(JSON.stringify(result));
"""

        completed = subprocess.run(
            [node, "-e", harness, str(reader)],
            capture_output=True,
            text=True,
            check=True,
        )
        result = json.loads(completed.stdout)

        self.assertEqual([item["id"] for item in result["results"]], ["mail:2"])
        self.assertFalse(result["truncated"])
        self.assertTrue(result["hardTruncated"])

    def test_main_install_keeps_mail_reader_separate(self):
        install_script = (SCRIPTS / "install.sh").read_text()
        install_calls = [
            line
            for line in install_script.splitlines()
            if "install-mail-reader.sh" in line
        ]

        self.assertEqual(
            install_calls,
            [],
            "Base installation must leave optional Mail services and their account configuration under user control",
        )
        helper_install = (SCRIPTS / "install-mail-reader.sh").read_text()
        self.assertIn("for attempt in 1 2 3 4 5", helper_install)
        self.assertIn('if [[ "$bootstrapped" -ne 1 ]]', helper_install)
        self.assertIn("WatchPaths", helper_install)
        self.assertIn("connector-commands/mail-request.json", helper_install)

    def test_reader_timeout_has_actionable_error_code_and_runtime_path(self):
        application = self.root / "ECC Focus Mail Reader.app"
        application.mkdir()
        config = {
            "mailRequestDirectory": str(self.root),
            "mailResponseDirectory": str(self.root),
            "mailReaderApplication": str(application),
            "mailReaderService": "gui/503/tools.ecc.focus-mail-reader",
        }
        launched = subprocess.CompletedProcess([], 0, "", "")

        with mock.patch.object(MODULE.subprocess, "run", return_value=launched) as run, mock.patch.object(
            MODULE.time, "monotonic", side_effect=[100, 191]
        ), self.assertRaises(MODULE.MailAccessError) as captured:
            MODULE.invoke_reader(config, {"operation": "status"})

        self.assertEqual(captured.exception.code, "mail_reader_timeout")
        self.assertIn(str(self.root), str(captured.exception))
        self.assertIn("reinstall", str(captured.exception).casefold())
        self.assertIn(
            mock.call(
                ["/bin/launchctl", "kill", "SIGKILL", "gui/503/tools.ecc.focus-mail-reader"],
                capture_output=True,
                text=True,
                check=False,
            ),
            run.call_args_list,
        )

    def test_reader_timeout_kills_the_exact_launchservices_fallback_process(self):
        application = self.root / "ECC Focus Mail Reader.app"
        executable = application / "Contents" / "MacOS" / "applet"
        executable.parent.mkdir(parents=True)
        executable.touch()
        config = {
            "mailRequestDirectory": str(self.root),
            "mailResponseDirectory": str(self.root),
            "mailReaderApplication": str(application),
            "mailReaderService": "gui/503/tools.ecc.focus-mail-reader",
        }
        launch_denied = subprocess.CompletedProcess([], 1, "", "Operation not permitted")
        opened = subprocess.CompletedProcess([], 0, "", "")
        launch_kill_denied = subprocess.CompletedProcess([], 1, "", "Operation not permitted")
        process_list = subprocess.CompletedProcess([], 0, f" 4242 {executable}\n", "")

        with mock.patch.object(
            MODULE.subprocess,
            "run",
            side_effect=[launch_denied, opened, launch_kill_denied, process_list],
        ), mock.patch.object(
            MODULE.time, "monotonic", side_effect=[100, 191]
        ), mock.patch.object(MODULE.os, "kill") as kill, self.assertRaises(
            MODULE.MailAccessError
        ) as captured:
            MODULE.invoke_reader(config, {"operation": "status"})

        self.assertEqual(captured.exception.code, "mail_reader_timeout")
        kill.assert_called_once_with(4242, MODULE.signal.SIGKILL)

    def test_cli_error_payload_preserves_specific_mail_error_code(self):
        error = MODULE.MailAccessError("The Mail helper did not respond")
        error.code = "mail_reader_timeout"

        with mock.patch.object(
            sys,
            "argv",
            [str(SCRIPT), "--config", str(self.root / "ingestion.json"), "status"],
        ), mock.patch.object(MODULE.morning, "load_config", return_value=self.config), mock.patch.object(
            MODULE, "invoke_reader", side_effect=error
        ), mock.patch.object(MODULE, "emit", return_value=2) as emit:
            result = MODULE.main()

        self.assertEqual(result, 2)
        self.assertEqual(emit.call_args.args[0]["errorCode"], "mail_reader_timeout")

    def test_sandbox_denied_cleanup_preserves_mail_timeout(self):
        application = self.root / "ECC Focus Mail Reader.app"
        application.mkdir()
        config = {
            "mailRequestDirectory": str(self.root),
            "mailResponseDirectory": str(self.root),
            "mailReaderApplication": str(application),
        }
        for blocked_command in ("launchctl", "ps"):
            with self.subTest(blocked_command=blocked_command):
                calls = [subprocess.CompletedProcess([], 0, "", "")]
                calls.append(
                    PermissionError(1, "Operation not permitted", "/bin/launchctl")
                    if blocked_command == "launchctl"
                    else subprocess.CompletedProcess([], 0, "", "")
                )
                calls.append(PermissionError(1, "Operation not permitted", "/bin/ps"))
                with mock.patch.object(MODULE.subprocess, "run", side_effect=calls), mock.patch.object(
                    MODULE.time, "monotonic", side_effect=[100, 191]
                ), self.assertRaises(MODULE.MailAccessError) as captured:
                    MODULE.invoke_reader(config, {"operation": "status"})
                self.assertEqual(captured.exception.code, "mail_reader_timeout")
                self.assertNotIn("Operation not permitted", str(captured.exception))

    def test_sandbox_denied_launch_uses_fallback_and_keeps_launch_failure_category(self):
        application = self.root / "ECC Focus Mail Reader.app"
        application.mkdir()
        nonce = "launch-denied-nonce"
        config = {
            "mailRequestDirectory": str(self.root),
            "mailResponseDirectory": str(self.root),
            "mailReaderApplication": str(application),
        }
        (self.root / "mail-response.json").write_text(json.dumps({"status": "ok", "nonce": nonce}))
        denied = PermissionError(1, "Operation not permitted", "/bin/launchctl")
        with mock.patch.object(MODULE.uuid, "uuid4", return_value=nonce), mock.patch.object(
            MODULE.subprocess, "run", side_effect=[denied, subprocess.CompletedProcess([], 0, "", "")]
        ) as run:
            response = MODULE.invoke_reader(config, {"operation": "status"})
        self.assertEqual(response["status"], "ok")
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", "-g", "-n", str(application)])
        with mock.patch.object(MODULE.uuid, "uuid4", return_value=nonce), mock.patch.object(
            MODULE.subprocess,
            "run",
            side_effect=[denied, PermissionError(1, "Operation not permitted", "/usr/bin/open")],
        ):
            response = MODULE.invoke_reader(config, {"operation": "status"})
        self.assertEqual(response["status"], "ok")

    def test_javascript_helper_brokers_gmail_without_opening_apple_mail(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the JavaScript reader contract")
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
globalThis.$ = (value) => value;
eval(fs.readFileSync(process.argv[1], "utf8") + `
const commands = [];
readJSON = function(path) {
  if (String(path) === CONFIG_PATH) return {
    emailProvider: "gmail",
    emailAddress: "reader@example.com"
  };
  if (String(path).endsWith("mail-request.json")) return {
    operation: "status", nonce: "gmail-nonce"
  };
  return {
    status: "ok", operation: "status", nonce: "gmail-nonce",
    connector: "ecc-focus-mail-reader", provider: "gmail"
  };
};
writePrivateJSON = function() { throw new Error("JXA must not forge the Gmail response"); };
globalThis.Application = function(name) {
  if (name === "Mail") throw new Error("Apple Mail must not be opened for Gmail");
  return {doShellScript(command) { commands.push(command); }};
};
Application.currentApplication = function() {
  return {doShellScript(command) { commands.push(command); }};
};
const result = JSON.parse(run());
process.stdout.write(JSON.stringify({result, commands}));
`);
"""
        completed = subprocess.run(
            [node, "-e", harness, str(SCRIPTS / "focus-queue-mail-reader.js")],
            capture_output=True,
            text=True,
            check=True,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(result["result"]["status"], "ok")
        self.assertEqual(len(result["commands"]), 1)
        self.assertIn("focus_queue_gmail.py", result["commands"][0])
        self.assertIn(" serve", result["commands"][0])

    def test_unconfigured_mailbox_explains_scope_without_permission_error(self):
        connection = sqlite3.connect(self.index)
        connection.row_factory = sqlite3.Row
        try:
            with self.assertRaises(MODULE.MailAccessError) as captured:
                MODULE.selected_mailboxes(connection, self.config, ["Sent"])
        finally:
            connection.close()
        self.assertEqual(captured.exception.code, "mailbox_not_configured")
        self.assertIn("Configured mailboxes: inbox", str(captured.exception))

    def test_reader_distinguishes_automation_denial_from_local_resource_denial(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the JavaScript reader contract")
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
eval(fs.readFileSync(process.argv[1], "utf8"));
const automation = Object.assign(new Error("localized message"), {number: -1743});
const timedOut = Object.assign(new Error("localized message"), {number: -1712});
const local = new Error("Operation not permitted: /bin/ps");
const scope = new Error("Mailbox is not configured for read access: sent");
let propagated = [];
for (const error of [automation, timedOut]) {
  try { safeValue(() => { throw error; }, []); }
  catch (caught) { propagated.push(errorCode(caught)); }
}
process.stdout.write(JSON.stringify({
  codes: [automation, timedOut, local, scope].map(errorCode),
  propagated,
  missing: safeValue(() => { throw new Error("Missing optional field"); }, "fallback"),
  recovery: recoveryHint(errorCode(automation))
}));
"""
        completed = subprocess.run(
            [node, "-e", harness, str(SCRIPTS / "focus-queue-mail-reader.js")],
            capture_output=True, text=True, check=True,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(result["codes"], [
            "mail_permission_required", "mail_reader_timeout",
            "mail_runtime_permission_required", "mailbox_not_configured",
        ])
        self.assertEqual(result["propagated"], ["mail_permission_required", "mail_reader_timeout"])
        self.assertEqual(result["missing"], "fallback")
        self.assertIn("older applet and python", result["recovery"])

    @unittest.skipIf(sys.platform == "win32", "Tests the macOS/POSIX advisory lock")
    def test_busy_reader_has_bounded_wait_and_leaves_active_request_untouched(self):
        import fcntl

        config = {"mailRequestDirectory": str(self.root), "mailResponseDirectory": str(self.root)}
        request_path, _, lock_path = MODULE.request_paths(config)
        active_request = {"operation": "search", "nonce": "active-report-request"}
        request_path.write_text(json.dumps(active_request))
        with lock_path.open("a+") as active_lock:
            fcntl.flock(active_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with mock.patch.object(MODULE.time, "monotonic", side_effect=[100, 100, 116]), mock.patch.object(
                MODULE.subprocess, "run"
            ) as run, self.assertRaises(MODULE.MailAccessError) as captured:
                MODULE.invoke_reader(config, {"operation": "status"})
        self.assertEqual(captured.exception.code, "mail_reader_busy")
        self.assertIn("Retry after it finishes", str(captured.exception))
        self.assertEqual(json.loads(request_path.read_text()), active_request)
        run.assert_not_called()

    def test_reader_loads_bodies_only_for_output_page_after_metadata_search(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the JavaScript reader contract")
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
eval(fs.readFileSync(process.argv[1], "utf8"));
const values = Array.from({length: 20}, (_, id) => ({id: String(id + 1), date: new Date(Date.now() - id * 60000)}));
let bodyReads = [];
const messages = values.map((item) => ({
  id() { return item.id; }, messageId() { return `${item.id}@example.com`; }, dateReceived() { return item.date; },
  sender() { return "sender@example.com"; }, subject() { return "topic"; },
  readStatus() { return false; }, flaggedStatus() { return false; },
  content() { bodyReads.push(item.id); return `body ${item.id}`; }
}));
messages.id = () => values.map((item) => item.id);
messages.messageId = () => values.map((item) => `${item.id}@example.com`);
messages.dateReceived = () => values.map((item) => item.date);
messages.sender = () => values.map(() => "sender@example.com");
messages.subject = () => values.map(() => "topic");
messages.readStatus = () => values.map(() => false);
messages.flaggedStatus = () => values.map(() => false);
messages.slice = (start, end) => {
  const bounded = Array.prototype.slice.call(messages, start, end + 1);
  for (const property of ["id", "messageId", "dateReceived", "sender", "subject", "readStatus", "flaggedStatus"]) {
    bounded[property] = () => bounded.map((message) => message[property]());
  }
  bounded.content = () => bounded.map((message) => message.content());
  return bounded;
};
const account = {mailboxes() { return [{name() { return "INBOX"; }, messages}]; }};
const results = [];
for (const query of ["", "topic"]) {
  bodyReads = [];
  const page = search({emailAddress: "haley@example.com", emailMailboxes: ["INBOX"]},
    {query, limit: 2, offset: 5}, account);
  results.push({page, bodyReads});
}
process.stdout.write(JSON.stringify(results));
"""
        completed = subprocess.run(
            [node, "-e", harness, str(SCRIPTS / "focus-queue-mail-reader.js")],
            capture_output=True, text=True, check=True,
        )
        expected = [
            (["6", "7"], True),
            (["6", "7"], False),
        ]
        for result, (expected_body_reads, expected_hard_truncation) in zip(
            json.loads(completed.stdout), expected
        ):
            self.assertEqual(result["bodyReads"], expected_body_reads)
            self.assertEqual([item["snippet"] for item in result["page"]["results"]], ["body 6", "body 7"])
            self.assertTrue(result["page"]["truncated"])
            self.assertEqual(result["page"]["hardTruncated"], expected_hard_truncation)

    def test_reader_filters_large_mailbox_before_bulk_metadata_reads(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the JavaScript reader contract")
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
eval(fs.readFileSync(process.argv[1], "utf8"));

const now = Date.now();
const recent = Array.from({length: 3063}, (_, index) => {
  const id = 3063 - index;
  return {id: String(id), messageId: `${id}@example.com`, date: new Date(now - index * 1000)};
});
let unfilteredMetadataReads = 0;
let individualMetadataReads = 0;
let boundedBulkMetadataReads = 0;
let fullIdWidths = [];
let bulkWidths = [];
let bulkContentWidths = [];
let bulkContentRanges = [];
let resolutionWidths = [];
let rangeCalls = [];
let bodyReads = [];

function collection(values) {
  const result = values.map((item) => ({
    id() { individualMetadataReads += 1; return item.id; },
    messageId() { individualMetadataReads += 1; return item.messageId; },
    dateReceived() { individualMetadataReads += 1; return item.date; },
    sender() { individualMetadataReads += 1; return "sender@example.com"; },
    subject() { individualMetadataReads += 1; return `subject ${item.id}`; },
    readStatus() { individualMetadataReads += 1; return false; },
    flaggedStatus() { individualMetadataReads += 1; return false; },
    content() { bodyReads.push(item.id); return `body ${item.id}`; }
  }));
  return result;
}

function boundedSpecifier(values, rangeStart = 0) {
  const resolved = collection(values);
  const read = (result) => {
    boundedBulkMetadataReads += 1;
    bulkWidths.push(values.length);
    return result;
  };
  const specifier = () => { resolutionWidths.push(values.length); return resolved; };
  specifier.id = () => read(values.map((item) => item.id));
  specifier.messageId = () => read(values.map((item) => item.messageId));
  specifier.dateReceived = () => read(values.map((item) => item.date));
  specifier.sender = () => read(values.map(() => "sender@example.com"));
  specifier.subject = () => read(values.map((item) => `subject ${item.id}`));
  specifier.readStatus = () => read(values.map(() => false));
  specifier.flaggedStatus = () => read(values.map(() => false));
  specifier.content = () => {
    bulkContentWidths.push(values.length);
    bulkContentRanges.push([rangeStart, rangeStart + values.length - 1]);
    return values.map((item) => `body ${item.id}`);
  };
  return specifier;
}

function rawSpecifier(values) {
  const allMessages = collection(values);
  allMessages.id = () => {
    fullIdWidths.push(values.length);
    return values.map((item) => item.id);
  };
  for (const property of ["messageId", "dateReceived", "sender", "subject", "readStatus", "flaggedStatus"]) {
    allMessages[property] = () => {
      unfilteredMetadataReads += 1;
      throw new Error("unbounded expensive mailbox metadata was read");
    };
  }
  allMessages.slice = (start, end) => {
    rangeCalls.push([start, end]);
    return boundedSpecifier(values.slice(start, end + 1), start);
  };
  allMessages.whose = () => {
    unfilteredMetadataReads += 1;
    throw new Error("unsafe whose/range composition was used");
  };
  return allMessages;
}

const inbox = {name() { return "INBOX"; }, messages: rawSpecifier(recent)};
const sent = {name() { return "Sent"; }, messages: {
  id() { throw new Error("unconfigured mailbox was searched"); }
}};
const result = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 7, limit: 1, offset: 1},
  {mailboxes() { return [inbox, sent]; }}
);
const queried = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
  {query: "subject", days: 7, limit: 1, offset: 1},
  {mailboxes() { return [inbox, sent]; }}
);
const empty = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 7, limit: 5, offset: 0},
  {mailboxes() { return [{name() { return "INBOX"; }, messages: rawSpecifier([])}]; }}
);
const underfilled = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 7, limit: 5, offset: 0},
  {mailboxes() { return [{name() { return "INBOX"; }, messages: rawSpecifier(recent.slice(0, 2))}]; }}
);
const withOldMessages = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 7, limit: 5, offset: 0},
  {mailboxes() { return [{name() { return "INBOX"; }, messages: rawSpecifier([
    recent[0],
    {id: "old-2", messageId: "old-2@example.com", date: new Date(now - 40 * 24 * 60 * 60 * 1000)},
    {id: "old-1", messageId: "old-1@example.com", date: new Date(now - 60 * 24 * 60 * 60 * 1000)}
  ])}]; }}
);
const mailboxA = [
  {id: "a3", messageId: "a3@example.com", date: new Date(now)},
  {id: "a2", messageId: "a2@example.com", date: new Date(now - 2 * 60000)},
  {id: "a1", messageId: "a1@example.com", date: new Date(now - 4 * 60000)}
];
const mailboxB = [
  {id: "b3", messageId: "b3@example.com", date: new Date(now - 60000)},
  {id: "b2", messageId: "b2@example.com", date: new Date(now - 3 * 60000)},
  {id: "b1", messageId: "b1@example.com", date: new Date(now - 5 * 60000)}
];
const multiMailbox = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX", "Archive"]},
  {query: "", days: 7, limit: 3, offset: 0},
  {mailboxes() { return [
    {name() { return "INBOX"; }, messages: rawSpecifier(mailboxA)},
    {name() { return "Archive"; }, messages: rawSpecifier(mailboxB)}
  ]; }}
);
const cappedPage = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 7, limit: 200, offset: 0, dailyReport: true},
  {mailboxes() { return [{name() { return "INBOX"; }, messages: rawSpecifier(recent)}]; }}
);
const largeMailboxA = Array.from({length: 20}, (_, index) => ({
  id: `ca-${index}`,
  messageId: `ca-${index}@example.com`,
  date: new Date(now - index * 2000)
}));
const largeMailboxB = Array.from({length: 20}, (_, index) => ({
  id: `cb-${index}`,
  messageId: `cb-${index}@example.com`,
  date: new Date(now - (index * 2000 + 1000))
}));
const cappedMultiMailbox = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX", "Archive"]},
  {query: "", days: 7, limit: 20, offset: 0, dailyReport: true},
  {mailboxes() { return [
    {name() { return "INBOX"; }, messages: rawSpecifier(largeMailboxA)},
    {name() { return "Archive"; }, messages: rawSpecifier(largeMailboxB)}
  ]; }}
);
const highOffset = search(
  {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
  {query: "", days: 7, limit: 10, offset: 150, dailyReport: true},
  {mailboxes() { return [{name() { return "INBOX"; }, messages: rawSpecifier(recent)}]; }}
);
process.stdout.write(JSON.stringify({
  result, queried, empty, underfilled, withOldMessages, multiMailbox,
  cappedPage, cappedMultiMailbox, highOffset,
  unfilteredMetadataReads, individualMetadataReads, boundedBulkMetadataReads,
  fullIdWidths, bulkWidths, bulkContentWidths, bulkContentRanges,
  resolutionWidths, rangeCalls, bodyReads
}));
"""
        completed = subprocess.run(
            [node, "-e", harness, str(SCRIPTS / "focus-queue-mail-reader.js")],
            capture_output=True,
            text=True,
            check=True,
        )
        observed = json.loads(completed.stdout)

        self.assertEqual(observed["unfilteredMetadataReads"], 0)
        self.assertEqual(observed["individualMetadataReads"], 0)
        self.assertEqual(
            observed["fullIdWidths"],
            [3063, 3063, 0, 2, 3, 3, 3, 3063, 20, 20, 3063],
        )
        self.assertEqual(observed["boundedBulkMetadataReads"], 60)
        self.assertEqual(observed["bulkWidths"][:6], [3] * 6)
        self.assertEqual(observed["bulkWidths"][6:12], [3063] * 6)
        self.assertEqual(observed["bulkWidths"][12:18], [2] * 6)
        self.assertEqual(observed["bulkWidths"][18:36], [3] * 18)
        self.assertEqual(observed["bulkWidths"][36:42], [201] * 6)
        self.assertEqual(observed["bulkWidths"][42:54], [20] * 12)
        self.assertEqual(observed["bulkWidths"][54:], [161] * 6)
        self.assertEqual(observed["resolutionWidths"], [3063])
        self.assertEqual(observed["bulkContentWidths"], [1, 2, 1, 2, 1, 10, 5, 5, 10])
        self.assertEqual(observed["bulkContentRanges"][-1], [150, 159])
        self.assertEqual(sum(observed["bulkContentWidths"][3:5]), 3)
        self.assertEqual(sum(observed["bulkContentWidths"][-3:-1]), 10)
        self.assertEqual(observed["result"]["mailboxes"], ["INBOX"])
        self.assertEqual(observed["result"]["candidateCount"], 3)
        self.assertEqual(observed["result"]["results"][0]["id"], "mail:3062")
        self.assertEqual(observed["result"]["results"][0]["sourceKey"], "email:<3062@example.com>")
        self.assertEqual(observed["queried"]["candidateCount"], 3063)
        self.assertEqual(observed["empty"]["results"], [])
        self.assertEqual(len(observed["underfilled"]["results"]), 2)
        self.assertEqual(
            [item["id"] for item in observed["withOldMessages"]["results"]],
            ["mail:3063"],
        )
        self.assertEqual(
            [item["id"] for item in observed["multiMailbox"]["results"]],
            ["mail:a3", "mail:b3", "mail:a2"],
        )
        self.assertEqual(len(observed["cappedPage"]["results"]), 200)
        self.assertEqual(observed["cappedPage"]["bodyResultCount"], 10)
        self.assertTrue(observed["cappedPage"]["bodyTruncated"])
        self.assertTrue(observed["cappedPage"]["hardTruncated"])
        self.assertEqual(
            sum(bool(item["snippet"]) for item in observed["cappedPage"]["results"]),
            10,
        )
        self.assertEqual(len(observed["cappedMultiMailbox"]["results"]), 20)
        self.assertEqual(observed["cappedMultiMailbox"]["bodyResultCount"], 10)
        self.assertTrue(observed["cappedMultiMailbox"]["bodyTruncated"])
        self.assertEqual(
            sum(bool(item["snippet"]) for item in observed["cappedMultiMailbox"]["results"]),
            10,
        )
        self.assertEqual(len(observed["highOffset"]["results"]), 10)
        self.assertEqual(observed["highOffset"]["bodyResultCount"], 10)
        self.assertFalse(observed["highOffset"]["bodyTruncated"])
        self.assertEqual(observed["bodyReads"], ["3062"])
        self.assertTrue(observed["result"]["truncated"])
        self.assertTrue(observed["result"]["hardTruncated"])
        self.assertFalse(observed["empty"]["hardTruncated"])
        self.assertFalse(observed["underfilled"]["hardTruncated"])
        self.assertFalse(observed["withOldMessages"]["hardTruncated"])

    def test_reader_rejects_failed_or_short_bulk_body_batches(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required for the JavaScript reader contract")
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}};
eval(fs.readFileSync(process.argv[1], "utf8"));

const values = Array.from({length: 12}, (_, index) => ({
  id: String(12 - index),
  date: new Date(Date.now() - index * 1000)
}));

function mailbox(mode) {
  const messages = [];
  messages.id = () => values.map((item) => item.id);
  messages.slice = (start, end) => {
    const selected = values.slice(start, end + 1);
    return {
      messageId() { return selected.map((item) => `${item.id}@example.com`); },
      dateReceived() { return selected.map((item) => item.date); },
      sender() { return selected.map(() => "sender@example.com"); },
      subject() { return selected.map((item) => `subject ${item.id}`); },
      readStatus() { return selected.map(() => false); },
      flaggedStatus() { return selected.map(() => false); },
      content() {
        if (mode === "throw") throw new Error("Mail content batch failed");
        return selected.slice(0, Math.max(0, selected.length - 1)).map((item) => `body ${item.id}`);
      }
    };
  };
  return {name() { return "INBOX"; }, messages};
}

const errors = [];
for (const mode of ["throw", "short"]) {
  try {
    search(
      {emailAddress: "reader@example.com", emailMailboxes: ["INBOX"]},
      {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
      {mailboxes() { return [mailbox(mode)]; }}
    );
    errors.push(null);
  } catch (error) {
    errors.push(String(error));
  }
}
process.stdout.write(JSON.stringify(errors));
"""
        completed = subprocess.run(
            [node, "-e", harness, str(SCRIPTS / "focus-queue-mail-reader.js")],
            capture_output=True,
            text=True,
            check=True,
        )
        errors = json.loads(completed.stdout)

        self.assertIn("Mail content batch failed", errors[0])
        self.assertIn("body batch", errors[1].lower())
        self.assertIn("expected 10", errors[1].lower())


if __name__ == "__main__":
    unittest.main()
