import importlib.util
import contextlib
import io
import json
import os
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


# Apple Mail's measured costs on a 3,210-message INBOX: a property read on the
# whole mailbox is one Apple Event (about 20-70 ms); the same read through a
# range specifier is evaluated per message (about 5 s per 1,000 messages);
# a body read is one Apple Event per message. The mock records whole-mailbox
# column reads and body reads, and rejects range and whose specifiers so a
# test fails the moment the reader reintroduces them.
READER_MAIL_MOCK = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}, unwrap(value) { return value; }};
globalThis.$ = Object.assign((value) => value, {NSHomeDirectory() { return require("os").homedir(); }});
let source = fs.readFileSync(process.argv[1], "utf8");
for (const [from, to] of JSON.parse(process.argv[2] || "[]")) source = source.replace(from, to);
eval(source);
globalThis.mailCalls = {columns: [], bodies: [], ranges: 0, whose: 0};
function mockMailbox(name, values, options) {
  const settings = options || {};
  const recipientsOf = (item) => item.recipients || {to: ["reader@example.com"], cc: [], bcc: []};
  const messages = {};
  const column = (property, read) => () => {
    mailCalls.columns.push(property);
    if (settings.failColumn === property) throw settings.failure;
    return values.map(read);
  };
  messages.id = () => {
    mailCalls.columns.push("id");
    return settings.ids ? settings.ids() : values.map((item) => item.id);
  };
  messages.messageId = column("messageId", (item) => item.messageId || `${item.id}@example.com`);
  messages.dateReceived = column("dateReceived", (item) => item.date);
  messages.sender = column("sender", () => "sender@example.com");
  messages.subject = column("subject", (item) => item.subject || `subject ${item.id}`);
  messages.readStatus = column("readStatus", () => false);
  messages.flaggedStatus = column("flaggedStatus", () => false);
  for (const [property, key] of [["toRecipients", "to"], ["ccRecipients", "cc"], ["bccRecipients", "bcc"]]) {
    messages[property] = {address: column(property, (item) => recipientsOf(item)[key] || [])};
  }
  messages.byId = (id) => ({
    content() {
      mailCalls.bodies.push(String(id));
      const item = values.find((candidate) => candidate.id === id);
      if (item.body instanceof Error) throw item.body;
      return item.body === undefined ? `body ${item.id}` : item.body;
    }
  });
  messages.slice = () => {
    mailCalls.ranges += 1;
    throw new Error("range specifier read: Mail evaluates it message by message");
  };
  messages.whose = () => {
    mailCalls.whose += 1;
    throw new Error("whose specifier read");
  };
  return {name() { return name; }, messages};
}
function accountWith(...mailboxes) {
  return {mailboxes() { return mailboxes; }};
}
const config = {emailAddress: "reader@example.com", emailMailboxes: ["INBOX", "Archive"]};
const now = Date.now();
function recent(count, prefix) {
  return Array.from({length: count}, (_, index) => ({
    id: `${prefix || ""}${count - index}`,
    date: new Date(now - index * 1000)
  }));
}
"""


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

    def test_reader_paths_follow_the_home_folder(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required to exercise the JavaScript mail reader contract")
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}, unwrap(value) { return value; }};
globalThis.$ = Object.assign((value) => value, {NSHomeDirectory() { return require("os").homedir(); }});
eval(fs.readFileSync(process.argv[1], "utf8") + `
process.stdout.write(JSON.stringify([CONFIG_PATH, DEFAULT_REQUEST_PATH, DEFAULT_RESPONSE_PATH, GMAIL_CONNECTOR_PATH]));
`);
"""
        output = subprocess.run(
            [node, "-e", harness, str(SCRIPTS / "focus-queue-mail-reader.js")],
            check=True, capture_output=True, text=True,
            env={**os.environ, "HOME": "/tmp/reader-home"},
        ).stdout
        support = "/tmp/reader-home/Library/Application Support/ECC Focus Queue"
        self.assertEqual(json.loads(output), [
            f"{support}/ingestion.json",
            f"{support}/connector-commands",
            f"{support}/mail-proofs",
            f"{support}/automation/Scripts/focus_queue_gmail.py",
        ])

    def test_reader_uses_same_configured_runtime_as_python_client(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required to exercise the JavaScript mail reader contract")
        reader = SCRIPTS / "focus-queue-mail-reader.js"
        request_runtime = self.root / "connector-commands"
        response_runtime = self.root / "mail-proofs"
        harness = r"""
const fs = require("fs");
globalThis.ObjC = {import() {}, unwrap(value) { return value; }};
globalThis.$ = Object.assign((value) => value, {NSHomeDirectory() { return require("os").homedir(); }});
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

    def run_reader_harness(self, body, replacements=()):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required to exercise the JavaScript mail reader contract")
        completed = subprocess.run(
            [
                node,
                "-e",
                READER_MAIL_MOCK + body,
                str(SCRIPTS / "focus-queue-mail-reader.js"),
                json.dumps(list(replacements)),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(completed.stdout)

    def test_reader_search_honors_offset_across_pages(self):
        result = self.run_reader_harness(r"""
const values = [
  {id: "3", date: new Date("2026-09-09T12:00:00Z")},
  {id: "2", date: new Date("2026-09-09T11:00:00Z")},
  {id: "1", date: new Date("2026-09-09T10:00:00Z")}
];
const result = search(config, {query: "", days: 3650, limit: 1, offset: 1},
  accountWith(mockMailbox("INBOX", values)));
process.stdout.write(JSON.stringify(result));
""")

        self.assertEqual(result["offset"], 1)
        self.assertEqual([item["id"] for item in result["results"]], ["mail:2"])
        self.assertTrue(result["truncated"])

    def test_reader_marks_a_page_ending_at_scan_cap_as_hard_truncated(self):
        result = self.run_reader_harness(
            r"""
const result = search(config, {query: "", days: 30, limit: 1, offset: 2},
  accountWith(mockMailbox("INBOX", recent(4))));
process.stdout.write(JSON.stringify(result));
""",
            [["const MAX_SEARCH_CANDIDATES = 5000;", "const MAX_SEARCH_CANDIDATES = 3;"]],
        )

        self.assertEqual([item["id"] for item in result["results"]], ["mail:2"])
        self.assertFalse(result["truncated"])
        self.assertTrue(result["hardTruncated"])

    def test_reader_daily_report_scans_past_out_of_order_old_messages(self):
        observed = self.run_reader_harness(r"""
const values = [
  {id: "new-2", date: new Date(now - 60000)},
  {id: "old", date: new Date(now - 40 * 24 * 60 * 60 * 1000)},
  {id: "new-1", date: new Date(now - 120000)}
];
const account = accountWith(mockMailbox("INBOX", values));
const first = search(config, {query: "", days: 7, limit: 1, offset: 0, dailyReport: true}, account);
const second = search(config, {query: "", days: 7, limit: 1, offset: 1, dailyReport: true}, account);
process.stdout.write(JSON.stringify({first, second}));
""")

        self.assertEqual(
            [item["id"] for item in observed["first"]["results"]], ["mail:new-2"]
        )
        self.assertTrue(observed["first"]["truncated"])
        self.assertEqual(
            [item["id"] for item in observed["second"]["results"]], ["mail:new-1"]
        )
        self.assertFalse(observed["second"]["truncated"])
        self.assertFalse(observed["second"]["hardTruncated"])

    def test_reader_loads_bodies_only_for_output_page_after_metadata_search(self):
        results = self.run_reader_harness(r"""
const values = recent(20).map((item) => ({...item, subject: "topic"}));
const account = accountWith(mockMailbox("INBOX", values));
const results = [];
for (const query of ["", "topic"]) {
  mailCalls.bodies = [];
  const page = search(config, {query, limit: 2, offset: 5}, account);
  results.push({page, bodyReads: mailCalls.bodies});
}
process.stdout.write(JSON.stringify(results));
""")

        for result in results:
            self.assertEqual(result["bodyReads"], ["15", "14"])
            self.assertEqual(
                [item["snippet"] for item in result["page"]["results"]],
                ["body 15", "body 14"],
            )
            self.assertTrue(result["page"]["truncated"])
            self.assertFalse(result["page"]["hardTruncated"])

    def test_reader_reads_whole_mailbox_columns_never_ranges(self):
        observed = self.run_reader_harness(r"""
const inbox = mockMailbox("INBOX", recent(3063));
const sent = {name() { return "Sent"; }, messages: {
  id() { throw new Error("unconfigured mailbox was searched"); }
}};
const result = search(config, {query: "", days: 7, limit: 1, offset: 1, dailyReport: true},
  accountWith(inbox, sent));
const firstSearchColumns = mailCalls.columns.slice();
const firstSearchBodies = mailCalls.bodies.slice();
const cappedPage = search(config, {query: "", days: 7, limit: 200, offset: 0, dailyReport: true},
  accountWith(inbox));
mailCalls.bodies = [];
const highOffset = search(config, {query: "", days: 7, limit: 10, offset: 150, dailyReport: true},
  accountWith(inbox));
const highOffsetBodies = mailCalls.bodies.slice();
const multiMailbox = search(config, {query: "", days: 7, limit: 3, offset: 0},
  accountWith(mockMailbox("INBOX", [
    {id: "a3", date: new Date(now)},
    {id: "a2", date: new Date(now - 2 * 60000)},
    {id: "a1", date: new Date(now - 4 * 60000)}
  ]), mockMailbox("Archive", [
    {id: "b3", date: new Date(now - 60000)},
    {id: "b2", date: new Date(now - 3 * 60000)},
    {id: "b1", date: new Date(now - 5 * 60000)}
  ])));
const empty = search(config, {query: "", days: 7, limit: 5, offset: 0},
  accountWith(mockMailbox("INBOX", [])));
const withOldMessages = search(config, {query: "", days: 7, limit: 5, offset: 0},
  accountWith(mockMailbox("INBOX", [
    {id: "new", date: new Date(now)},
    {id: "old-2", date: new Date(now - 40 * 24 * 60 * 60 * 1000)},
    {id: "old-1", date: new Date(now - 60 * 24 * 60 * 60 * 1000)}
  ])));
process.stdout.write(JSON.stringify({
  result, cappedPage, highOffset, multiMailbox, empty, withOldMessages,
  firstSearchColumns, firstSearchBodies, highOffsetBodies,
  ranges: mailCalls.ranges, whose: mailCalls.whose
}));
""")

        self.assertEqual(observed["ranges"], 0)
        self.assertEqual(observed["whose"], 0)
        # One consistent snapshot: IDs, six metadata columns, three recipient
        # columns, then IDs again to prove no message moved in between.
        self.assertEqual(
            observed["firstSearchColumns"],
            ["id", "messageId", "dateReceived", "sender", "subject", "readStatus",
             "flaggedStatus", "toRecipients", "ccRecipients", "bccRecipients", "id"],
        )
        self.assertEqual(observed["firstSearchBodies"], ["3062"])
        self.assertEqual(observed["result"]["mailboxes"], ["INBOX"])
        self.assertEqual(observed["result"]["candidateCount"], 3063)
        self.assertEqual(observed["result"]["results"][0]["id"], "mail:3062")
        self.assertEqual(
            observed["result"]["results"][0]["sourceKey"], "email:<3062@example.com>"
        )
        self.assertTrue(observed["result"]["truncated"])
        self.assertFalse(observed["result"]["hardTruncated"])
        self.assertEqual(len(observed["cappedPage"]["results"]), 200)
        self.assertEqual(observed["cappedPage"]["bodyResultCount"], 25)
        self.assertTrue(observed["cappedPage"]["bodyTruncated"])
        self.assertTrue(observed["cappedPage"]["hardTruncated"])
        self.assertEqual(
            sum(bool(item["snippet"]) for item in observed["cappedPage"]["results"]), 25
        )
        self.assertEqual(
            observed["highOffsetBodies"], [str(3063 - offset) for offset in range(150, 160)]
        )
        self.assertFalse(observed["highOffset"]["bodyTruncated"])
        self.assertEqual(
            [item["id"] for item in observed["multiMailbox"]["results"]],
            ["mail:a3", "mail:b3", "mail:a2"],
        )
        self.assertEqual(observed["empty"]["results"], [])
        self.assertFalse(observed["empty"]["hardTruncated"])
        self.assertEqual(
            [item["id"] for item in observed["withOldMessages"]["results"]], ["mail:new"]
        )
        self.assertFalse(observed["withOldMessages"]["hardTruncated"])

    def test_reader_reports_only_mail_addressed_to_configured_recipients(self):
        observed = self.run_reader_harness(r"""
const values = [
  {id: "to", date: new Date(now), recipients: {to: ["Reader@Example.com"], cc: [], bcc: []}},
  {id: "shared", date: new Date(now - 1000), recipients: {to: ["shared@example.com"], cc: [], bcc: []}},
  {id: "cc", date: new Date(now - 2000), recipients: {to: ["team@example.com"], cc: ["alias@example.com"], bcc: []}},
  {id: "bcc", date: new Date(now - 3000), recipients: {to: [], cc: [], bcc: ["reader@example.com"]}}
];
const configured = {...config, emailAddresses: ["reader@example.com", "alias@example.com"]};
const result = search(configured, {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
  accountWith(mockMailbox("INBOX", values)));
process.stdout.write(JSON.stringify({result, bodies: mailCalls.bodies}));
""")

        self.assertEqual(
            [item["id"] for item in observed["result"]["results"]],
            ["mail:to", "mail:cc", "mail:bcc"],
        )
        self.assertEqual(observed["result"]["otherRecipientCount"], 1)
        self.assertEqual(
            observed["result"]["recipientAddresses"],
            ["reader@example.com", "alias@example.com"],
        )
        self.assertNotIn("shared", observed["bodies"])

    def test_reader_reports_one_copy_of_mail_delivered_to_two_aliases(self):
        observed = self.run_reader_harness(r"""
const values = [
  {id: "3", date: new Date(now), messageId: "<shared@example.com>"},
  {id: "2", date: new Date(now - 1000), messageId: "<shared@example.com>"},
  {id: "1", date: new Date(now - 2000)}
];
const result = search(config, {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
  accountWith(mockMailbox("INBOX", values)));
process.stdout.write(JSON.stringify(result));
""")

        self.assertEqual(
            [item["id"] for item in observed["results"]], ["mail:3", "mail:1"]
        )
        self.assertEqual(observed["duplicateCount"], 1)
        self.assertFalse(observed["truncated"])

    def test_reader_surfaces_recipient_read_failure_instead_of_filtering_everything(self):
        observed = self.run_reader_harness(r"""
let failure = null;
try {
  search(config, {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
    accountWith(mockMailbox("INBOX", recent(3), {
      failColumn: "toRecipients",
      failure: new Error("Mail got an error: AppleEvent handler failed.")
    })));
} catch (error) {
  failure = String(error);
}
process.stdout.write(JSON.stringify({failure}));
""")

        self.assertIn("AppleEvent handler failed", observed["failure"])

    def test_reader_retries_a_snapshot_that_new_mail_shifted(self):
        observed = self.run_reader_harness(r"""
const values = recent(3);
const shifted = ["new", ...values.map((item) => item.id)];
let idReads = 0;
const settling = mockMailbox("INBOX", values, {
  ids() { idReads += 1; return idReads === 2 ? shifted : values.map((item) => item.id); }
});
const settled = search(config, {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
  accountWith(settling));
let failure = null;
let flips = 0;
try {
  search(config, {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
    accountWith(mockMailbox("INBOX", values, {
      ids() { flips += 1; return flips % 2 ? values.map((item) => item.id) : shifted; }
    })));
} catch (error) {
  failure = String(error);
}
process.stdout.write(JSON.stringify({settled, idReads, failure, flips}));
""")

        self.assertEqual(
            [item["id"] for item in observed["settled"]["results"]],
            ["mail:3", "mail:2", "mail:1"],
        )
        self.assertEqual(observed["idReads"], 4)
        self.assertIn("kept changing", observed["failure"])
        self.assertEqual(observed["flips"], 6)

    def test_reader_body_failures_keep_message_but_surface_permission_loss(self):
        observed = self.run_reader_harness(r"""
const values = recent(2);
values[0].body = new Error("Message is not downloaded");
const kept = search(config, {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
  accountWith(mockMailbox("INBOX", values)));
const denied = recent(1);
denied[0].body = Object.assign(new Error("Not authorized to send Apple events to Mail."), {number: -1743});
let code = null;
try {
  search(config, {query: "", days: 7, limit: 10, offset: 0, dailyReport: true},
    accountWith(mockMailbox("INBOX", denied)));
} catch (error) {
  code = errorCode(error);
}
process.stdout.write(JSON.stringify({kept, code}));
""")

        self.assertEqual(
            [item["snippet"] for item in observed["kept"]["results"]], ["", "body 1"]
        )
        self.assertEqual(observed["kept"]["bodyResultCount"], 2)
        self.assertEqual(observed["code"], "mail_permission_required")

    def test_reader_skips_writing_a_response_for_a_superseded_request(self):
        observed = self.run_reader_harness(r"""
let requestNonce = "current";
readJSON = function() { return {nonce: requestNonce}; };
const paths = {request: "request.json", response: "response.json"};
const current = requestIsCurrent(paths, "current");
requestNonce = "newer";
const superseded = requestIsCurrent(paths, "current");
readJSON = function() { throw new Error("Could not read request.json"); };
const unreadable = requestIsCurrent(paths, "current");
process.stdout.write(JSON.stringify({current, superseded, unreadable}));
""")

        self.assertEqual(
            observed, {"current": True, "superseded": False, "unreadable": True}
        )

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
globalThis.ObjC = {import() {}, unwrap(value) { return value; }};
globalThis.$ = Object.assign((value) => value, {NSHomeDirectory() { return require("os").homedir(); }});
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
globalThis.ObjC = {import() {}, unwrap(value) { return value; }};
globalThis.$ = Object.assign((value) => value, {NSHomeDirectory() { return require("os").homedir(); }});
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

if __name__ == "__main__":
    unittest.main()
