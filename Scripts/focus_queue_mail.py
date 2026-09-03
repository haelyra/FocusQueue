#!/usr/bin/env python3
"""Verified read-only Apple Mail access for the ECC Focus Queue agent."""

from __future__ import annotations

import argparse
import datetime as dt
import email
import fcntl
import html
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import uuid
from email import policy
from email.parser import BytesParser
from pathlib import Path
from typing import Any

import focus_queue_morning as morning


DEFAULT_CONFIG = Path("/Users/hira/Library/Application Support/ECC Focus Queue/ingestion.json")
DEFAULT_RUNTIME = Path("/Users/hira/Library/Application Support/ECC Focus Queue/ingestion")
MAX_BODY_CHARACTERS = 100_000
MAX_SEARCH_CANDIDATES = 5_000


class MailAccessError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def clean_identifier(value: str) -> str:
    identifier = urllib.parse.unquote(value.strip())
    if identifier.startswith("email:"):
        identifier = identifier[6:]
    return identifier


def normalized_message_id(value: str) -> str:
    value = clean_identifier(value)
    if value and not value.startswith("<") and not value.startswith("mail:"):
        value = f"<{value}>"
    return value


def selected_mailboxes(
    connection: sqlite3.Connection,
    config: dict[str, Any],
    requested: list[str] | None = None,
) -> dict[int, tuple[str, str]]:
    configured = {
        str(item).casefold()
        for item in config.get(
            "emailMailboxes",
            ["INBOX", "Junk", "Archive", "Deleted Messages"],
        )
    }
    if requested:
        wanted = {item.casefold() for item in requested}
        unknown = wanted - configured
        if unknown:
            raise MailAccessError(f"Mailbox is not configured for read access: {', '.join(sorted(unknown))}")
        configured = wanted

    selected: dict[int, tuple[str, str]] = {}
    for row in connection.execute("SELECT ROWID, url FROM mailboxes"):
        parsed = urllib.parse.urlparse(str(row["url"]))
        name = urllib.parse.unquote(parsed.path.rsplit("/", 1)[-1])
        if parsed.scheme == "imap" and name.casefold() in configured:
            selected[int(row["ROWID"])] = (parsed.netloc, name)
    if not selected:
        raise MailAccessError("None of the configured Apple Mail mailboxes were found")
    return selected


def message_rows(
    connection: sqlite3.Connection,
    config: dict[str, Any],
    mailboxes: dict[int, tuple[str, str]],
    *,
    days: int | None,
    maximum: int,
    local_id: int | None = None,
) -> list[sqlite3.Row]:
    predicates = [
        "lower(recipient.address) = lower(?)",
        f"m.mailbox IN ({','.join('?' for _ in mailboxes)})",
        "m.deleted = 0",
    ]
    parameters: list[Any] = [str(config["emailAddress"]), *mailboxes.keys()]
    if days is not None:
        cutoff = int((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).timestamp())
        predicates.append("m.date_received >= ?")
        parameters.append(cutoff)
    if local_id is not None:
        predicates.append("m.ROWID = ?")
        parameters.append(local_id)
    parameters.append(maximum)
    return connection.execute(
        f"""
        SELECT DISTINCT
            m.ROWID AS local_id,
            m.mailbox,
            m.date_received,
            m.read,
            m.flagged,
            m.subject_prefix,
            COALESCE(subjects.subject, '') AS subject,
            COALESCE(summaries.summary, '') AS summary,
            COALESCE(sender.comment, '') AS sender_name,
            COALESCE(sender.address, '') AS sender_address,
            COALESCE(message_global_data.message_id_header, '') AS message_id_header
        FROM messages AS m
        JOIN recipients ON recipients.message = m.ROWID
        JOIN addresses AS recipient ON recipient.ROWID = recipients.address
        LEFT JOIN addresses AS sender ON sender.ROWID = m.sender
        LEFT JOIN subjects ON subjects.ROWID = m.subject
        LEFT JOIN summaries ON summaries.ROWID = m.summary
        LEFT JOIN message_global_data ON message_global_data.ROWID = m.global_message_id
        WHERE {' AND '.join(predicates)}
        ORDER BY m.date_received DESC
        LIMIT ?
        """,
        parameters,
    ).fetchall()


def emlx_paths(
    mail_root: Path,
    mailboxes: dict[int, tuple[str, str]],
    wanted_ids: set[int],
) -> dict[int, Path]:
    paths: dict[int, Path] = {}
    for account_id, mailbox_name in mailboxes.values():
        mailbox_root = mail_root / account_id / f"{mailbox_name}.mbox"
        if not mailbox_root.exists():
            continue
        for path in mailbox_root.rglob("*.emlx"):
            try:
                local_id = int(path.name.split(".", 1)[0])
            except ValueError:
                continue
            if local_id in wanted_ids:
                paths[local_id] = path
    return paths


def parse_emlx(path: Path) -> tuple[str, list[dict[str, str]]]:
    raw = path.read_bytes()
    first_newline = raw.find(b"\n")
    if first_newline >= 0:
        try:
            byte_count = int(raw[:first_newline].strip())
            raw = raw[first_newline + 1 : first_newline + 1 + byte_count]
        except ValueError:
            pass
    parsed = BytesParser(policy=policy.default).parsebytes(raw)
    body = parsed.get_body(preferencelist=("plain", "html"))
    text = ""
    if body is not None:
        try:
            content = body.get_content()
            text = content.decode(errors="replace") if isinstance(content, bytes) else str(content)
        except (LookupError, UnicodeError):
            text = ""
        if body.get_content_type() == "text/html":
            text = re.sub(r"(?is)<(script|style).*?>.*?</\1>", " ", text)
            text = re.sub(r"(?i)<br\s*/?>|</p\s*>", "\n", text)
            text = re.sub(r"(?s)<[^>]+>", " ", text)
            text = html.unescape(text)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = "\n".join(line.rstrip() for line in text.splitlines()).strip()
    attachments = []
    for part in parsed.iter_attachments():
        filename = part.get_filename()
        if filename:
            attachments.append(
                {"filename": str(filename)[:300], "contentType": str(part.get_content_type())}
            )
    return text[:MAX_BODY_CHARACTERS], attachments


def row_metadata(row: sqlite3.Row, mailboxes: dict[int, tuple[str, str]]) -> dict[str, Any]:
    local_id = int(row["local_id"])
    message_id = normalized_message_id(str(row["message_id_header"] or ""))
    prefix = str(row["subject_prefix"] or "")
    subject = str(row["subject"] or "(no subject)")
    if prefix and not subject.casefold().startswith(prefix.casefold()):
        subject = f"{prefix}{subject}"
    sender_name = str(row["sender_name"] or "").strip()
    sender_address = str(row["sender_address"] or "").strip()
    sender = sender_name or sender_address or "unknown"
    received = dt.datetime.fromtimestamp(int(row["date_received"]), tz=dt.timezone.utc)
    return {
        "id": f"mail:{local_id}",
        "sourceKey": f"email:{message_id or f'local:{local_id}'}",
        "messageId": message_id,
        "mailbox": mailboxes[int(row["mailbox"])][1],
        "sender": sender[:300],
        "senderAddress": sender_address[:320],
        "subject": subject[:500],
        "receivedAt": received.isoformat().replace("+00:00", "Z"),
        "read": bool(row["read"]),
        "flagged": bool(row["flagged"]),
        "url": f"message://{urllib.parse.quote(message_id, safe='')}" if message_id else "",
    }


def snippet(text: str, query: str, limit: int = 700) -> str:
    compact = re.sub(r"\s+", " ", text).strip()
    if len(compact) <= limit:
        return compact
    position = compact.casefold().find(query.casefold()) if query else -1
    start = max(0, position - limit // 3) if position >= 0 else 0
    end = min(len(compact), start + limit)
    prefix = "…" if start else ""
    suffix = "…" if end < len(compact) else ""
    return f"{prefix}{compact[start:end]}{suffix}"


def search_mail(config: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
    query = str(request.get("query", "")).strip()
    days = min(max(int(request.get("days", 30)), 1), 3650)
    limit = min(max(int(request.get("limit", 10)), 1), 50)
    requested_mailboxes = request.get("mailboxes")
    if requested_mailboxes is not None and not isinstance(requested_mailboxes, list):
        raise MailAccessError("mailboxes must be an array")

    mail_root, index_path = morning.apple_mail_store(config)
    connection = sqlite3.connect(f"file:{index_path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        mailboxes = selected_mailboxes(connection, config, requested_mailboxes)
        rows = message_rows(
            connection,
            config,
            mailboxes,
            days=days,
            maximum=MAX_SEARCH_CANDIDATES,
        )
    finally:
        connection.close()
    paths = emlx_paths(mail_root, mailboxes, {int(row["local_id"]) for row in rows})
    terms = [term for term in re.split(r"\s+", query.casefold()) if term]
    results = []
    for row in rows:
        metadata = row_metadata(row, mailboxes)
        body, attachments = parse_emlx(paths[int(row["local_id"])]) if int(row["local_id"]) in paths else ("", [])
        haystack = "\n".join(
            [
                metadata["sender"],
                metadata["senderAddress"],
                metadata["subject"],
                str(row["summary"] or ""),
                body,
            ]
        ).casefold()
        if terms and not all(term in haystack for term in terms):
            continue
        metadata["snippet"] = snippet(body or str(row["summary"] or ""), query)
        metadata["attachments"] = attachments
        results.append(metadata)
        if len(results) >= limit:
            break
    return {
        "status": "ok",
        "verified": True,
        "operation": "search",
        "connector": "ecc-focus-mail-reader",
        "account": config["emailAddress"],
        "mailboxes": [value[1] for value in mailboxes.values()],
        "query": query,
        "days": days,
        "retrievedAt": utc_now(),
        "resultCount": len(results),
        "candidateCount": len(rows),
        "truncated": len(rows) >= MAX_SEARCH_CANDIDATES or len(results) >= limit,
        "results": results,
    }


def read_mail(config: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
    identifier = clean_identifier(str(request.get("identifier", "")))
    if not identifier:
        raise MailAccessError("A message identifier is required")
    requested_mailboxes = request.get("mailboxes")
    local_id: int | None = None
    if identifier.startswith("mail:") and identifier[5:].isdigit():
        local_id = int(identifier[5:])

    mail_root, index_path = morning.apple_mail_store(config)
    connection = sqlite3.connect(f"file:{index_path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        mailboxes = selected_mailboxes(connection, config, requested_mailboxes)
        rows = message_rows(
            connection,
            config,
            mailboxes,
            days=None,
            maximum=1 if local_id is not None else MAX_SEARCH_CANDIDATES,
            local_id=local_id,
        )
    finally:
        connection.close()

    normalized = normalized_message_id(identifier)
    chosen = None
    for row in rows:
        metadata = row_metadata(row, mailboxes)
        if local_id is not None or identifier in {metadata["sourceKey"], metadata["messageId"]}:
            chosen = (row, metadata)
            break
        if normalized and normalized == metadata["messageId"]:
            chosen = (row, metadata)
            break
    if chosen is None:
        return {
            "status": "not-found",
            "verified": True,
            "operation": "read",
            "connector": "ecc-focus-mail-reader",
            "account": config["emailAddress"],
            "identifier": identifier,
            "retrievedAt": utc_now(),
        }

    row, metadata = chosen
    paths = emlx_paths(mail_root, mailboxes, {int(row["local_id"])})
    path = paths.get(int(row["local_id"]))
    if path is None:
        raise MailAccessError("The indexed message body is not synchronized locally")
    body, attachments = parse_emlx(path)
    return {
        "status": "ok",
        "verified": True,
        "operation": "read",
        "connector": "ecc-focus-mail-reader",
        "account": config["emailAddress"],
        "retrievedAt": utc_now(),
        "message": {**metadata, "body": body, "attachments": attachments},
    }


def status(config: dict[str, Any]) -> dict[str, Any]:
    _, index_path = morning.apple_mail_store(config)
    connection = sqlite3.connect(f"file:{index_path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        mailboxes = selected_mailboxes(connection, config)
        counts = {}
        for mailbox_id, (_, name) in mailboxes.items():
            count = connection.execute(
                """
                SELECT COUNT(DISTINCT m.ROWID)
                FROM messages AS m
                JOIN recipients ON recipients.message = m.ROWID
                JOIN addresses AS recipient ON recipient.ROWID = recipients.address
                WHERE lower(recipient.address) = lower(?) AND m.mailbox = ? AND m.deleted = 0
                """,
                [str(config["emailAddress"]), mailbox_id],
            ).fetchone()[0]
            counts[name] = int(count)
    finally:
        connection.close()
    return {
        "status": "ok",
        "verified": True,
        "operation": "status",
        "connector": "ecc-focus-mail-reader",
        "account": config["emailAddress"],
        "retrievedAt": utc_now(),
        "mailboxes": counts,
    }


def request_paths(config: dict[str, Any]) -> tuple[Path, Path, Path]:
    runtime = Path(config.get("mailRuntimeDirectory", DEFAULT_RUNTIME)).expanduser()
    return (
        runtime / "mail-request.json",
        runtime / "mail-response.json",
        runtime / "mail-command.lock",
    )


def serve(config: dict[str, Any]) -> int:
    request_path, response_path, _ = request_paths(config)
    request = morning.load_json(request_path)
    nonce = str(request.get("nonce", ""))
    try:
        operation = str(request.get("operation", ""))
        if operation == "search":
            response = search_mail(config, request)
        elif operation == "read":
            response = read_mail(config, request)
        elif operation == "status":
            response = status(config)
        else:
            raise MailAccessError(f"Unsupported mail operation: {operation}")
    except Exception as error:
        response = {
            "status": "error",
            "verified": False,
            "operation": str(request.get("operation", "unknown")),
            "connector": "ecc-focus-mail-reader",
            "account": config.get("emailAddress", "unknown"),
            "retrievedAt": utc_now(),
            "error": str(error)[:800],
        }
    response["nonce"] = nonce
    morning.write_private_json(response_path, response)
    return 0


def invoke_reader(config: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
    request_path, response_path, lock_path = request_paths(config)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as lock:
        lock_path.chmod(0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        nonce = str(uuid.uuid4())
        payload = {**request, "nonce": nonce, "requestedAt": utc_now()}
        morning.write_private_json(request_path, payload)
        application = Path(config["mailReaderApplication"]).expanduser()
        if not application.exists():
            raise MailAccessError(f"Mail reader app is not installed at {application}")
        service = str(
            config.get(
                "mailReaderService",
                f"gui/{os.getuid()}/tools.ecc.focus-mail-reader",
            )
        )
        launched = subprocess.run(
            ["/bin/launchctl", "kickstart", "-k", service],
            capture_output=True,
            text=True,
            check=False,
        )
        if launched.returncode != 0:
            detail = (launched.stderr or launched.stdout).strip()
            raise MailAccessError(f"Mail reader service could not start: {detail[:500]}")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                response = morning.load_json(response_path)
            except Exception:
                response = {}
            if response.get("nonce") == nonce:
                return response
            time.sleep(0.1)
        raise MailAccessError("Mail reader service timed out")


def emit(payload: dict[str, Any]) -> int:
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if payload.get("status") == "ok" else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("query")
    search_parser.add_argument("--days", type=int, default=30)
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--mailbox", action="append", dest="mailboxes")
    read_parser = subparsers.add_parser("read")
    read_parser.add_argument("identifier")
    read_parser.add_argument("--mailbox", action="append", dest="mailboxes")
    open_parser = subparsers.add_parser("open")
    open_parser.add_argument("identifier")
    open_parser.add_argument("--mailbox", action="append", dest="mailboxes")
    subparsers.add_parser("serve", help=argparse.SUPPRESS)
    arguments = parser.parse_args()

    try:
        config = morning.load_config(arguments.config)
        if arguments.command == "serve":
            return serve(config)
        if arguments.command == "status":
            return emit(invoke_reader(config, {"operation": "status"}))
        if arguments.command == "search":
            return emit(
                invoke_reader(
                    config,
                    {
                        "operation": "search",
                        "query": arguments.query,
                        "days": arguments.days,
                        "limit": arguments.limit,
                        "mailboxes": arguments.mailboxes,
                    },
                )
            )
        response = invoke_reader(
            config,
            {
                "operation": "read",
                "identifier": arguments.identifier,
                "mailboxes": arguments.mailboxes,
            },
        )
        if arguments.command == "open" and response.get("status") == "ok":
            url = str(response.get("message", {}).get("url", ""))
            if not url:
                raise MailAccessError("The verified message has no Mail deep link")
            opened = subprocess.run(
                ["/usr/bin/open", "-b", "com.apple.mail", url],
                capture_output=True,
                text=True,
                check=False,
            )
            if opened.returncode != 0:
                raise MailAccessError(f"Mail could not open the message: {opened.stderr.strip()[:300]}")
            response["operation"] = "open"
            response["opened"] = True
            response["openedAt"] = utc_now()
            _, response_path, _ = request_paths(config)
            morning.write_private_json(response_path, response)
        return emit(response)
    except Exception as error:
        return emit(
            {
                "status": "error",
                "verified": False,
                "operation": arguments.command,
                "connector": "ecc-focus-mail-reader",
                "error": str(error)[:800],
                "retrievedAt": utc_now(),
            }
        )


if __name__ == "__main__":
    raise SystemExit(main())
