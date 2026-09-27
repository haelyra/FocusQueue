#!/usr/bin/env python3
"""Provider-native, read-only Gmail access for ECC Focus Queue."""

from __future__ import annotations

import argparse
import base64
import ctypes
import datetime as dt
import hashlib
import html
import http.server
import json
import re
import secrets
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from email.utils import getaddresses, parseaddr
from pathlib import Path
from typing import Any, Callable

import focus_queue_morning as morning


DEFAULT_CONFIG = Path("/Users/hira/Library/Application Support/ECC Focus Queue/ingestion.json")
DEFAULT_AUTH_STATE = Path(
    "/Users/hira/Library/Application Support/ECC Focus Queue/gmail-auth.json"
)
CONNECTOR = "ecc-focus-mail-reader"
GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
AUTHORIZATION_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
API_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"
KEYCHAIN_SERVICE = "tools.ecc.focus-queue.gmail"
MAX_BODY_CHARACTERS = 100_000
MAX_RESULTS = 50
MAX_DAILY_RESULTS = 500
MAX_OFFSET = 5_000
ERR_SEC_DUPLICATE_ITEM = -25299


class GmailAccessError(RuntimeError):
    def __init__(self, message: str, *, code: str = "gmail_access_failed") -> None:
        super().__init__(message)
        self.code = code


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def oauth_client(config: dict[str, Any]) -> dict[str, str]:
    value = config.get("gmailOAuthClientPath")
    if not isinstance(value, str) or not value.strip():
        raise GmailAccessError(
            "gmailOAuthClientPath is not configured",
            code="gmail_oauth_client_required",
        )
    path = Path(value).expanduser()
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        raise GmailAccessError(
            "The Gmail OAuth client file must be an absolute regular file",
            code="gmail_oauth_client_invalid",
        )
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise GmailAccessError(
            "The Gmail OAuth client file must be private (mode 0600)",
            code="gmail_oauth_client_insecure",
        )
    try:
        with path.open("rb") as handle:
            content = handle.read(1_048_577)
        if len(content) > 1_048_576:
            raise ValueError("oversized OAuth client file")
        payload = json.loads(content)
        client = payload.get("installed")
        if not isinstance(client, dict):
            raise ValueError("not an installed application OAuth client")
        client_id = str(client["client_id"]).strip()
        client_secret = str(client.get("client_secret", "")).strip()
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        raise GmailAccessError(
            "The Gmail OAuth client file is invalid",
            code="gmail_oauth_client_invalid",
        ) from error
    if not client_id:
        raise GmailAccessError(
            "The Gmail OAuth client file has no client_id",
            code="gmail_oauth_client_invalid",
        )
    return {"client_id": client_id, "client_secret": client_secret}


def keychain_service(config: dict[str, Any]) -> str:
    value = str(config.get("gmailKeychainService", KEYCHAIN_SERVICE)).strip()
    if not value or len(value) > 200 or any(character.isspace() for character in value):
        raise GmailAccessError(
            "gmailKeychainService is invalid",
            code="gmail_keychain_invalid",
        )
    return value


def configured_account(config: dict[str, Any]) -> str:
    value = str(config.get("emailAddress", "")).strip().casefold()
    if not value or "@" not in value:
        raise GmailAccessError(
            "emailAddress must identify the Gmail account",
            code="gmail_account_required",
        )
    return value


def security_framework() -> Any:
    framework = ctypes.cdll.LoadLibrary(
        "/System/Library/Frameworks/Security.framework/Security"
    )
    framework.SecKeychainFindGenericPassword.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_char_p,
        ctypes.c_uint32,
        ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    framework.SecKeychainFindGenericPassword.restype = ctypes.c_int32
    framework.SecKeychainAddGenericPassword.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_char_p,
        ctypes.c_uint32,
        ctypes.c_char_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    framework.SecKeychainAddGenericPassword.restype = ctypes.c_int32
    framework.SecKeychainItemModifyAttributesAndData.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_void_p,
    ]
    framework.SecKeychainItemModifyAttributesAndData.restype = ctypes.c_int32
    framework.SecKeychainItemFreeContent.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    framework.SecKeychainItemFreeContent.restype = ctypes.c_int32
    return framework


def keychain_identifiers(config: dict[str, Any]) -> tuple[bytes, bytes]:
    return keychain_service(config).encode("utf-8"), configured_account(config).encode("utf-8")


def release_keychain_item(item: ctypes.c_void_p) -> None:
    if not item.value:
        return
    framework = ctypes.cdll.LoadLibrary(
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
    )
    framework.CFRelease.argtypes = [ctypes.c_void_p]
    framework.CFRelease(item)


def keychain_refresh_token(config: dict[str, Any]) -> str:
    framework = security_framework()
    service, account = keychain_identifiers(config)
    length = ctypes.c_uint32()
    data = ctypes.c_void_p()
    status = framework.SecKeychainFindGenericPassword(
        None,
        len(service),
        service,
        len(account),
        account,
        ctypes.byref(length),
        ctypes.byref(data),
        None,
    )
    if status != 0 or not data.value or not length.value:
        raise GmailAccessError(
            "Gmail authorization is required; run focus-mail authorize",
            code="gmail_authorization_required",
        )
    try:
        return ctypes.string_at(data, length.value).decode("utf-8")
    finally:
        framework.SecKeychainItemFreeContent(None, data)


def store_refresh_token(config: dict[str, Any], refresh_token: str) -> None:
    if not refresh_token:
        raise GmailAccessError(
            "Google did not return a refresh token",
            code="gmail_refresh_token_missing",
        )
    encoded = refresh_token.encode("utf-8")
    if len(encoded) > 65_536:
        raise GmailAccessError(
            "The Gmail refresh token is unexpectedly large",
            code="gmail_keychain_write_failed",
        )
    framework = security_framework()
    service, account = keychain_identifiers(config)
    item = ctypes.c_void_p()
    status = framework.SecKeychainAddGenericPassword(
        None,
        len(service),
        service,
        len(account),
        account,
        len(encoded),
        ctypes.c_char_p(encoded),
        ctypes.byref(item),
    )
    if status == ERR_SEC_DUPLICATE_ITEM:
        status = framework.SecKeychainFindGenericPassword(
            None,
            len(service),
            service,
            len(account),
            account,
            None,
            None,
            ctypes.byref(item),
        )
        if status == 0 and item.value:
            status = framework.SecKeychainItemModifyAttributesAndData(
                item,
                None,
                len(encoded),
                ctypes.c_char_p(encoded),
            )
    try:
        if status != 0:
            raise GmailAccessError(
                "Could not store the Gmail refresh token in macOS Keychain",
                code="gmail_keychain_write_failed",
            )
    finally:
        release_keychain_item(item)


def request_json(
    url: str,
    *,
    method: str = "GET",
    token: str | None = None,
    form: dict[str, str] | None = None,
    timeout: int = 30,
    opener: Callable[..., Any] = urllib.request.urlopen,
) -> dict[str, Any]:
    data = None
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener(request, timeout=timeout) as response:
            content = response.read(2_000_001)
            if len(content) > 2_000_000:
                raise GmailAccessError(
                    "Gmail returned an oversized response",
                    code="gmail_invalid_response",
                )
            payload = json.loads(content)
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read(100_001)).get("error", {})
            if isinstance(detail, dict):
                detail = detail.get("message") or detail.get("status") or ""
        except (json.JSONDecodeError, AttributeError):
            detail = ""
        if error.code == 401:
            code = "gmail_authorization_required"
        elif error.code == 403:
            code = "gmail_permission_denied"
        elif error.code == 429:
            code = "gmail_rate_limited"
        else:
            code = "gmail_api_failed"
        raise GmailAccessError(
            f"Gmail API request failed with HTTP {error.code}: {str(detail)[:300]}",
            code=code,
        ) from error
    except (OSError, urllib.error.URLError, TimeoutError) as error:
        raise GmailAccessError(
            "Could not reach the Gmail API",
            code="gmail_network_failed",
        ) from error
    except json.JSONDecodeError as error:
        raise GmailAccessError(
            "Gmail returned invalid JSON",
            code="gmail_invalid_response",
        ) from error
    if not isinstance(payload, dict):
        raise GmailAccessError(
            "Gmail returned an invalid response",
            code="gmail_invalid_response",
        )
    return payload


def refresh_access_token(
    config: dict[str, Any],
    *,
    opener: Callable[..., Any] = urllib.request.urlopen,
) -> str:
    client = oauth_client(config)
    form = {
        "client_id": client["client_id"],
        "refresh_token": keychain_refresh_token(config),
        "grant_type": "refresh_token",
    }
    if client["client_secret"]:
        form["client_secret"] = client["client_secret"]
    response = request_json(TOKEN_ENDPOINT, method="POST", form=form, opener=opener)
    token = str(response.get("access_token", "")).strip()
    if not token:
        raise GmailAccessError(
            "Google did not return an access token",
            code="gmail_authorization_required",
        )
    return token


def authorization_url(
    client_id: str,
    redirect_uri: str,
    state: str,
    code_challenge: str,
) -> str:
    query = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": GMAIL_SCOPE,
            "access_type": "offline",
            "prompt": "consent",
            "state": state,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
        }
    )
    return f"{AUTHORIZATION_ENDPOINT}?{query}"


class OAuthCallbackHandler(http.server.BaseHTTPRequestHandler):
    result: dict[str, str] = {}

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        parsed = urllib.parse.urlparse(self.path)
        values = urllib.parse.parse_qs(parsed.query)
        type(self).result = {key: str(items[0]) for key, items in values.items() if items}
        body = b"Focus Queue received the Gmail authorization. You can close this window."
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_arguments: Any) -> None:
        return


def authorize(config: dict[str, Any], *, open_browser: bool, timeout: int) -> dict[str, Any]:
    client = oauth_client(config)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode("ascii")).digest()
    ).decode("ascii").rstrip("=")
    state = secrets.token_urlsafe(32)
    OAuthCallbackHandler.result = {}
    server = http.server.HTTPServer(("127.0.0.1", 0), OAuthCallbackHandler)
    server.timeout = max(1, min(timeout, 600))
    redirect_uri = f"http://127.0.0.1:{server.server_port}/oauth/callback"
    url = authorization_url(client["client_id"], redirect_uri, state, challenge)
    print(json.dumps({"status": "authorization_required", "authorizationURL": url}, indent=2))
    sys.stdout.flush()
    if open_browser:
        webbrowser.open(url, new=1, autoraise=True)
    server.handle_request()
    server.server_close()
    result = OAuthCallbackHandler.result
    if not result:
        raise GmailAccessError(
            "Gmail authorization timed out",
            code="gmail_authorization_timeout",
        )
    if result.get("state") != state:
        raise GmailAccessError("The Gmail OAuth state did not match", code="gmail_oauth_state_mismatch")
    if result.get("error"):
        raise GmailAccessError(
            f"Google declined authorization: {result['error'][:200]}",
            code="gmail_authorization_denied",
        )
    code = result.get("code", "")
    if not code:
        raise GmailAccessError(
            "Gmail authorization timed out",
            code="gmail_authorization_timeout",
        )
    form = {
        "client_id": client["client_id"],
        "code": code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }
    if client["client_secret"]:
        form["client_secret"] = client["client_secret"]
    tokens = request_json(TOKEN_ENDPOINT, method="POST", form=form)
    access_token = str(tokens.get("access_token", "")).strip()
    refresh_token = str(tokens.get("refresh_token", "")).strip()
    if not access_token or not refresh_token:
        raise GmailAccessError(
            "Google did not return the required installed-app tokens",
            code="gmail_refresh_token_missing",
        )
    profile = request_json(f"{API_BASE}/profile", token=access_token)
    account = str(profile.get("emailAddress", "")).strip().casefold()
    if account != configured_account(config):
        raise GmailAccessError(
            "The authorized Gmail account does not match emailAddress",
            code="gmail_account_mismatch",
        )
    state_path = Path(config.get("gmailAuthStatePath", DEFAULT_AUTH_STATE)).expanduser()
    if not state_path.is_absolute():
        raise GmailAccessError(
            "gmailAuthStatePath must be absolute",
            code="gmail_auth_state_invalid",
        )
    store_refresh_token(config, refresh_token)
    morning.write_private_json(
        state_path,
        {
            "version": 1,
            "provider": "gmail",
            "account": account,
            "scope": GMAIL_SCOPE,
            "authorizedAt": utc_now(),
            "writesEnabled": False,
        },
    )
    return {
        "status": "ok",
        "verified": True,
        "operation": "authorize",
        "connector": CONNECTOR,
        "provider": "gmail",
        "account": account,
        "scope": GMAIL_SCOPE,
        "writesEnabled": False,
        "retrievedAt": utc_now(),
    }


def api_url(path: str, parameters: dict[str, Any] | None = None) -> str:
    url = f"{API_BASE}/{path.lstrip('/')}"
    if parameters:
        values: list[tuple[str, str]] = []
        for key, value in parameters.items():
            if isinstance(value, list):
                values.extend((key, str(item)) for item in value)
            elif value is not None:
                values.append((key, str(value).lower() if isinstance(value, bool) else str(value)))
        url = f"{url}?{urllib.parse.urlencode(values)}"
    return url


class GmailClient:
    def __init__(
        self,
        config: dict[str, Any],
        *,
        opener: Callable[..., Any] = urllib.request.urlopen,
    ) -> None:
        self.config = config
        self.opener = opener
        self.token = refresh_access_token(config, opener=opener)

    def get(self, path: str, parameters: dict[str, Any] | None = None) -> dict[str, Any]:
        return request_json(api_url(path, parameters), token=self.token, opener=self.opener)


def decoded_body(value: str) -> str:
    if not value:
        return ""
    padded = value + "=" * (-len(value) % 4)
    try:
        return base64.urlsafe_b64decode(padded).decode("utf-8", errors="replace")
    except (ValueError, UnicodeError):
        return ""


def message_body(payload: dict[str, Any]) -> tuple[str, list[dict[str, str]]]:
    plain: list[str] = []
    rich: list[str] = []
    attachments: list[dict[str, str]] = []

    def visit(part: dict[str, Any]) -> None:
        mime_type = str(part.get("mimeType", "")).casefold()
        filename = str(part.get("filename", "")).strip()
        body = part.get("body") or {}
        if filename:
            attachments.append(
                {
                    "filename": filename[:300],
                    "contentType": mime_type,
                    "attachmentId": str(body.get("attachmentId", "")),
                }
            )
        data = decoded_body(str(body.get("data", "")))
        if data and mime_type == "text/plain":
            plain.append(data)
        elif data and mime_type == "text/html":
            rich.append(data)
        for child in part.get("parts") or []:
            if isinstance(child, dict):
                visit(child)

    visit(payload)
    text = "\n".join(plain).strip()
    if not text and rich:
        text = "\n".join(rich)
        text = re.sub(r"(?is)<(script|style).*?>.*?</\1>", " ", text)
        text = re.sub(r"(?i)<br\s*/?>|</p\s*>", "\n", text)
        text = re.sub(r"(?s)<[^>]+>", " ", text)
        text = html.unescape(text)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text.strip()[:MAX_BODY_CHARACTERS], attachments


def header_values(payload: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in payload.get("headers") or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name", "")).casefold()
        if name and name not in result:
            result[name] = str(item.get("value", "")).strip()
    return result


def received_at(message: dict[str, Any]) -> str:
    try:
        milliseconds = int(message.get("internalDate", 0))
        return dt.datetime.fromtimestamp(milliseconds / 1000, tz=dt.timezone.utc).isoformat().replace(
            "+00:00", "Z"
        )
    except (TypeError, ValueError, OSError):
        return ""


def mailbox_name(labels: list[str]) -> str:
    for label, name in (("INBOX", "INBOX"), ("SPAM", "Spam"), ("TRASH", "Trash")):
        if label in labels:
            return name
    return "Archive"


def message_metadata(message: dict[str, Any], *, full: bool) -> dict[str, Any]:
    payload = message.get("payload") or {}
    headers = header_values(payload)
    sender = headers.get("from", "unknown")
    sender_address = parseaddr(sender)[1]
    labels = [str(value) for value in message.get("labelIds") or []]
    gmail_id = str(message.get("id", ""))
    message_id = headers.get("message-id", "") or f"gmail:{gmail_id}"
    result: dict[str, Any] = {
        "id": f"gmail:{gmail_id}",
        "sourceKey": f"email:gmail:{gmail_id}",
        "messageId": message_id,
        "threadId": str(message.get("threadId", "")),
        "mailbox": mailbox_name(labels),
        "labels": labels,
        "sender": sender[:300],
        "senderAddress": sender_address[:320],
        "subject": headers.get("subject", "(no subject)")[:500],
        "receivedAt": received_at(message),
        "read": "UNREAD" not in labels,
        "flagged": "STARRED" in labels,
        "headers": {
            "from": sender_address.lower(),
            "to": [
                address.lower()
                for _, address in getaddresses([headers.get("to", "")])
                if address
            ],
            "cc": [
                address.lower()
                for _, address in getaddresses([headers.get("cc", "")])
                if address
            ],
            "listUnsubscribe": bool(headers.get("list-unsubscribe")),
            "precedence": headers.get("precedence", "").strip().lower(),
            "autoSubmitted": headers.get("auto-submitted", "").strip().lower(),
        },
        "url": f"https://mail.google.com/mail/u/0/#all/{gmail_id}",
    }
    if full:
        body, attachments = message_body(payload)
        result.update({"body": body, "attachments": attachments})
    else:
        result["snippet"] = str(message.get("snippet", ""))[:700]
    return result


def status(config: dict[str, Any], client: GmailClient) -> dict[str, Any]:
    profile = client.get("profile")
    account = str(profile.get("emailAddress", "")).casefold()
    if account != configured_account(config):
        raise GmailAccessError(
            "The authorized Gmail account does not match emailAddress",
            code="gmail_account_mismatch",
        )
    return {
        "status": "ok",
        "verified": True,
        "operation": "status",
        "connector": CONNECTOR,
        "provider": "gmail",
        "account": account,
        "retrievedAt": utc_now(),
        "messagesTotal": int(profile.get("messagesTotal", 0)),
        "threadsTotal": int(profile.get("threadsTotal", 0)),
        "capabilities": ["status", "search", "read"],
        "plannedWriteCapabilities": ["draft", "send", "reply"],
        "writesEnabled": False,
        "scope": GMAIL_SCOPE,
    }


def search(
    config: dict[str, Any],
    client: GmailClient,
    query: str,
    days: int,
    limit: int,
    offset: int = 0,
    *,
    limit_cap: int = MAX_RESULTS,
) -> dict[str, Any]:
    bounded_days = min(max(days, 1), 3650)
    bounded_limit = min(max(limit, 1), limit_cap)
    bounded_offset = min(max(offset, 0), MAX_OFFSET)
    terms = [f"newer_than:{bounded_days}d", "-in:sent", "-in:drafts"]
    if query.strip():
        terms.append(query.strip())
    needed = bounded_offset + bounded_limit
    identifiers: list[dict[str, Any]] = []
    page_token: str | None = None
    while len(identifiers) < needed:
        page = client.get(
            "messages",
            {
                "q": " ".join(terms),
                "includeSpamTrash": True,
                "maxResults": min(500, needed - len(identifiers)),
                "pageToken": page_token,
            },
        )
        identifiers.extend(item for item in page.get("messages") or [] if isinstance(item, dict))
        page_token = str(page.get("nextPageToken", "")) or None
        if not page_token:
            break
    selected = identifiers[bounded_offset:needed]
    results = []
    headers = [
        "From", "To", "Cc", "Subject", "Date", "Message-ID",
        "List-Unsubscribe", "Precedence", "Auto-Submitted",
    ]
    for item in selected:
        identifier = str(item.get("id", ""))
        if not identifier:
            continue
        message = client.get(
            f"messages/{urllib.parse.quote(identifier, safe='')}",
            {"format": "metadata", "metadataHeaders": headers},
        )
        results.append(message_metadata(message, full=False))
    return {
        "status": "ok",
        "verified": True,
        "operation": "search",
        "connector": CONNECTOR,
        "provider": "gmail",
        "account": configured_account(config),
        "retrievedAt": utc_now(),
        "query": query,
        "days": bounded_days,
        "resultCount": len(results),
        "results": results,
        "truncated": bool(page_token) or len(identifiers) > needed,
        "nextOffset": bounded_offset + len(results),
        "writesEnabled": False,
    }


def clean_identifier(value: str) -> str:
    identifier = urllib.parse.unquote(value.strip())
    if identifier.startswith("gmail:"):
        identifier = identifier[6:]
    match = re.search(r"mail\.google\.com/mail/(?:u/\d+/)?#\w+/([A-Za-z0-9_-]+)", identifier)
    if match:
        identifier = match.group(1)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", identifier):
        raise GmailAccessError("Use a Gmail message ID or link", code="gmail_message_id_invalid")
    return identifier


def read(config: dict[str, Any], client: GmailClient, identifier: str) -> dict[str, Any]:
    gmail_id = clean_identifier(identifier)
    message = client.get(
        f"messages/{urllib.parse.quote(gmail_id, safe='')}",
        {"format": "full"},
    )
    return {
        "status": "ok",
        "verified": True,
        "operation": "read",
        "connector": CONNECTOR,
        "provider": "gmail",
        "account": configured_account(config),
        "retrievedAt": utc_now(),
        "message": message_metadata(message, full=True),
        "writesEnabled": False,
    }


def collect_for_daily_report(config: dict[str, Any]) -> dict[str, Any]:
    result = search(
        config,
        GmailClient(config),
        "",
        max(1, (int(config["lookbackHours"]) + 23) // 24),
        min(max(int(config["maxEmailMessages"]), 1), MAX_DAILY_RESULTS),
        limit_cap=MAX_DAILY_RESULTS,
    )
    return {
        "status": "ok",
        "account": result["account"],
        "provider": "gmail",
        "mailboxesScanned": 1,
        "messages": [
            {
                "sourceKey": item["sourceKey"],
                "messageId": item["messageId"],
                "mailbox": item["mailbox"],
                "sender": item["sender"],
                "senderAddress": item.get("senderAddress", ""),
                "subject": item["subject"],
                "receivedAt": item["receivedAt"],
                "read": item["read"],
                "flagged": item["flagged"],
                "labels": item.get("labels", []),
                "headers": item.get("headers", {}),
                "text": item["snippet"],
                "url": item["url"],
            }
            for item in result["results"]
        ],
        "truncated": result["truncated"],
        "errors": [],
        "reader": "gmail-api",
    }


def request_paths(config: dict[str, Any]) -> tuple[Path, Path]:
    request_directory = Path(
        config.get("mailRequestDirectory", morning.MAIL_COMMAND_DIRECTORY)
    ).expanduser()
    response_directory = Path(
        config.get("mailResponseDirectory", morning.MAIL_PROOF_DIRECTORY)
    ).expanduser()
    return request_directory / "mail-request.json", response_directory / "mail-response.json"


def serve(config: dict[str, Any]) -> int:
    request_path, response_path = request_paths(config)
    request: dict[str, Any] = {}
    try:
        request = morning.load_json(request_path)
        client = GmailClient(config)
        operation = str(request.get("operation", ""))
        if operation == "status":
            response = status(config, client)
        elif operation == "search":
            response = search(
                config,
                client,
                str(request.get("query", "")),
                int(request.get("days", 30)),
                int(request.get("limit", 10)),
                int(request.get("offset", 0)),
            )
        elif operation == "read":
            response = read(config, client, str(request.get("identifier", "")))
        else:
            raise GmailAccessError(
                f"Unsupported Gmail operation: {operation}",
                code="gmail_operation_unsupported",
            )
    except Exception as error:
        response = {
            "status": "error",
            "verified": False,
            "operation": str(request.get("operation", "unknown")),
            "connector": CONNECTOR,
            "provider": "gmail",
            "account": str(config.get("emailAddress", "unknown")),
            "retrievedAt": utc_now(),
            "error": str(error)[:800],
            "writesEnabled": False,
        }
        if isinstance(error, GmailAccessError):
            response["errorCode"] = error.code
    response["nonce"] = str(request.get("nonce", ""))
    morning.write_private_json(response_path, response)
    return 0


def emit(payload: dict[str, Any]) -> int:
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if payload.get("status") == "ok" else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    subparsers = parser.add_subparsers(dest="command", required=True)
    authorize_parser = subparsers.add_parser("authorize")
    authorize_parser.add_argument("--open-browser", action="store_true")
    authorize_parser.add_argument("--timeout", type=int, default=300)
    subparsers.add_parser("status")
    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("query")
    search_parser.add_argument("--days", type=int, default=30)
    search_parser.add_argument("--limit", type=int, default=10)
    search_parser.add_argument("--offset", type=int, default=0)
    read_parser = subparsers.add_parser("read")
    read_parser.add_argument("identifier")
    subparsers.add_parser("serve", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    try:
        config = morning.load_config(arguments.config)
        if str(config.get("emailProvider", "apple_mail")) != "gmail":
            raise GmailAccessError(
                "Set emailProvider to gmail before using this connector",
                code="gmail_provider_not_selected",
            )
        if arguments.command == "serve":
            return serve(config)
        if arguments.command == "authorize":
            return emit(
                authorize(
                    config,
                    open_browser=arguments.open_browser,
                    timeout=arguments.timeout,
                )
            )
        client = GmailClient(config)
        if arguments.command == "status":
            return emit(status(config, client))
        if arguments.command == "search":
            return emit(
                search(
                    config,
                    client,
                    arguments.query,
                    arguments.days,
                    arguments.limit,
                    arguments.offset,
                )
            )
        return emit(read(config, client, arguments.identifier))
    except Exception as error:
        payload = {
            "status": "error",
            "verified": False,
            "operation": arguments.command,
            "connector": CONNECTOR,
            "provider": "gmail",
            "error": str(error)[:800],
            "retrievedAt": utc_now(),
            "writesEnabled": False,
        }
        if isinstance(error, GmailAccessError):
            payload["errorCode"] = error.code
        return emit(payload)


if __name__ == "__main__":
    raise SystemExit(main())
