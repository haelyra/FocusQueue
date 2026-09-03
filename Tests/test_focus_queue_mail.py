import importlib.util
import json
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
            "mailRuntimeDirectory": str(self.root),
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
            ["/bin/launchctl", "kickstart", "gui/503/tools.ecc.focus-mail-reader"],
        )
        self.assertEqual(
            run.call_args_list[1].args[0],
            ["/usr/bin/open", "-g", "-n", str(application)],
        )


if __name__ == "__main__":
    unittest.main()
