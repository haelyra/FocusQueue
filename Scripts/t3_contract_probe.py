#!/usr/bin/env python3
"""External-client contract probe for the T3 Code MCP server.

Verifies, as an outside OAuth client, the T3 Code behaviour Focus Queue's T3
runtime depends on, prints a PASS/FAIL table, and writes sanitized response
fixtures to Tests/Fixtures/T3/ for the Swift unit tests.

    python3 Scripts/t3_contract_probe.py --login --token-file ~/.fq-t3-token.json
    python3 Scripts/t3_contract_probe.py --token-file ~/.fq-t3-token.json [--only 1,2,5-7] [--keep]

Standard library only. It creates a scratch git repo and a T3 project titled
"fq-contract-probe", starts small agent turns with claude-haiku-5-5, and deletes
the project and every temporary directory afterwards (unless --keep).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import http.server
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

PROTOCOL_VERSION = "2026-07-28"
DEFAULT_SERVER = "http://127.0.0.1:3773"
EVENTS_EXTENSION = "io.modelcontextprotocol/events"
SCOPE = "orchestration:read orchestration:operate"
PROJECT_TITLE = "fq-contract-probe"
TEMP_PREFIX = "fq-contract-probe-"
MODEL = "claude-haiku-5-5"
PROVIDER_DRIVER = "claudeAgent"
DISABLED_CONSTRAINT = "Provider instance is disabled."
CLIENT_INFO = {"name": "focus-queue-contract-probe", "version": "1"}
EVENT_RUN_SETTLED = "thread.run_settled"
EVENT_NEEDS_INPUT = "thread.needs_input"
EVENT_INPUT_RESOLVED = "thread.input_resolved"
WATCHED_EVENTS = (EVENT_RUN_SETTLED, EVENT_NEEDS_INPUT, EVENT_INPUT_RESOLVED)
ACTIVE_THREAD_STATUSES = {"preparing", "starting", "running"}
DEFAULT_FIXTURES = Path(__file__).resolve().parents[1] / "Tests" / "Fixtures" / "T3"


# --------------------------------------------------------------------------- SSE


class SSEParser:
    """Incremental text/event-stream parser (WHATWG rules, minus `retry`)."""

    def __init__(self) -> None:
        self._data: list[str] = []
        self._event = ""
        self._id: Optional[str] = None
        self._has_field = False

    def feed_line(self, line: str) -> Optional[dict]:
        line = line.rstrip("\r\n")
        if line == "":
            return self._dispatch()
        if line.startswith(":"):
            return None
        field, _, value = line.partition(":")
        if value.startswith(" "):
            value = value[1:]
        if field == "data":
            self._data.append(value)
            self._has_field = True
        elif field == "event":
            self._event = value
            self._has_field = True
        elif field == "id":
            self._id = value
            self._has_field = True
        return None

    def finish(self) -> Optional[dict]:
        return self._dispatch()

    def _dispatch(self) -> Optional[dict]:
        if not self._has_field:
            return None
        event = {"event": self._event or "message", "data": "\n".join(self._data), "id": self._id}
        self._data, self._event, self._has_field = [], "", False
        return event if event["data"] or event["event"] != "message" else None


def parse_sse(text: str) -> list[dict]:
    parser = SSEParser()
    events = []
    for line in re.split(r"\r\n|\r|\n", text):
        event = parser.feed_line(line)
        if event:
            events.append(event)
    tail = parser.finish()
    if tail:
        events.append(tail)
    return events


def rpc_messages_from_sse(text: str) -> list[dict]:
    messages = []
    for event in parse_sse(text):
        try:
            value = json.loads(event["data"])
        except (ValueError, TypeError):
            continue
        if isinstance(value, dict):
            messages.append(value)
    return messages


def select_rpc_response(messages: list[dict], request_id: Any) -> dict:
    """The last message carrying `id` (preferring our request id) is the response."""
    with_id = [m for m in messages if "id" in m and ("result" in m or "error" in m)]
    matching = [m for m in with_id if m.get("id") == request_id]
    chosen = (matching or with_id)
    if not chosen:
        raise ProbeError("SSE response contained no JSON-RPC result")
    return chosen[-1]


# --------------------------------------------------------------------------- sanitizer

UUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
LAUNCH_ID_RE = re.compile(r"mcp:launch:[0-9a-f]{64}")
HOME_PATH_RE = re.compile(r"/(?:Users|Volumes)/[^/\s\"'\\]+")
TEMP_PATH_RE = re.compile(r"(?:/private)?/var/folders/[^\s\"'\\]*?/T(?=/|\b)")
BEARER_RE = re.compile(r"(?i)\bbearer\s+(?!TOKEN\b)[A-Za-z0-9._~+/=-]+")

ID_KEYS = {
    "threadId": "THREAD", "parentThreadId": "THREAD", "projectId": "PROJECT",
    "environmentId": "ENVIRONMENT", "requestId": "REQUEST", "runId": "RUN",
    "latestRunId": "RUN", "activeRunId": "RUN", "eventId": "EVENT",
    "clientRequestId": "CLIENT_REQUEST", "clientId": "CLIENT", "client_id": "CLIENT",
}
ID_LIST_KEYS = {"requestIds": "REQUEST", "projectIds": "PROJECT", "threadIds": "THREAD"}
TOKEN_KEYS = {"access_token", "refresh_token", "id_token", "token"}
MIN_ID_LENGTH = 6


class Sanitizer:
    """Replaces ids, absolute paths and tokens with stable placeholders.

    Call `observe` on every captured object first (so ids found anywhere are
    known everywhere), then `value` / `text` to produce the sanitized copy.
    """

    def __init__(self) -> None:
        self._literals: dict[str, str] = {}
        self._counters: dict[str, int] = {}
        self._compiled: Optional[re.Pattern] = None

    def register(self, value: Any, kind: str) -> Optional[str]:
        if not isinstance(value, str) or len(value) < MIN_ID_LENGTH:
            return None
        if value in self._literals:
            return self._literals[value]
        self._counters[kind] = self._counters.get(kind, 0) + 1
        placeholder = f"{kind}_{self._counters[kind]}"
        self._literals[value] = placeholder
        self._compiled = None
        return placeholder

    def register_literal(self, value: Optional[str], replacement: str) -> None:
        if value and len(value) >= 2 and value != replacement:
            self._literals.setdefault(value, replacement)
            self._compiled = None

    def register_path(self, path: Optional[str], replacement: str) -> None:
        if not path:
            return
        for variant in {path.rstrip("/"), os.path.realpath(path).rstrip("/")}:
            if variant and variant != "/":
                self._literals[variant] = replacement
        self._compiled = None

    def observe(self, value: Any) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ID_KEYS:
                    self.register(item, ID_KEYS[key])
                elif key in ID_LIST_KEYS and isinstance(item, list):
                    for entry in item:
                        self.register(entry, ID_LIST_KEYS[key])
                elif key in TOKEN_KEYS and isinstance(item, str):
                    self.register_literal(item, "TOKEN")
            if "id" in value:
                if "workspaceRoot" in value:
                    self.register(value["id"], "PROJECT")
                elif "worktreePath" in value or "pendingRequestCount" in value:
                    self.register(value["id"], "THREAD")
            for item in value.values():
                self.observe(item)
        elif isinstance(value, list):
            for item in value:
                self.observe(item)
        elif isinstance(value, str):
            stripped = value.strip()
            if stripped[:1] in "{[":
                try:
                    self.observe(json.loads(stripped))
                except ValueError:
                    pass

    def observe_sse(self, text: str) -> None:
        for message in rpc_messages_from_sse(text):
            self.observe(message)

    def text(self, value: str) -> str:
        if self._literals:
            if self._compiled is None:
                ordered = sorted(self._literals, key=len, reverse=True)
                self._compiled = re.compile("|".join(re.escape(item) for item in ordered))
            value = self._compiled.sub(lambda match: self._literals[match.group(0)], value)
        value = LAUNCH_ID_RE.sub(lambda match: self.register(match.group(0), "THREAD") or "THREAD", value)
        value = UUID_RE.sub(lambda match: self.register(match.group(0), "UUID") or "UUID", value)
        value = TEMP_PATH_RE.sub("/TMP", value)
        value = HOME_PATH_RE.sub("/HOME", value)
        value = BEARER_RE.sub("Bearer TOKEN", value)
        return value

    def value(self, value: Any) -> Any:
        if isinstance(value, dict):
            return {self.text(key): self.value(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.value(item) for item in value]
        if isinstance(value, str):
            return self.text(value)
        return value


LEAK_PATTERNS = [
    ("absolute /Users path", re.compile(r"/Users/")),
    ("absolute /Volumes path", re.compile(r"/Volumes/")),
    ("temporary folder path", re.compile(r"/var/folders/")),
    ("UUID", UUID_RE),
    ("launch thread id", LAUNCH_ID_RE),
    ("bearer token", BEARER_RE),
    ("token field", re.compile(r"\"(?:access_token|refresh_token|id_token)\"\s*:\s*\"(?!TOKEN\")")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("long hex secret", re.compile(r"\b[0-9a-f]{40,}\b")),
]


def find_leaks(text: str) -> list[str]:
    """Names of sensitive patterns present in a fixture's text."""
    return [name for name, pattern in LEAK_PATTERNS if pattern.search(text)]


def probe_fixture_paths(directory: Path) -> list[Path]:
    if not directory.is_dir():
        return []
    names = sorted(directory.iterdir())
    return [path for path in names if path.is_file() and (
        path.name.startswith("tool-") or path.name in {"stream.sse", "capabilities.json", "discover.json"})]


# --------------------------------------------------------------------------- helpers


class ProbeError(Exception):
    pass


class HttpError(ProbeError):
    def __init__(self, status: int, body: str):
        super().__init__(f"HTTP {status}: {body[:300]}")
        self.status = status
        self.body = body


class RpcError(ProbeError):
    def __init__(self, error: dict):
        super().__init__(f"JSON-RPC {error.get('code')}: {error.get('message')}")
        self.code = error.get("code")
        self.error = error


class ToolFailure(ProbeError):
    def __init__(self, tool: str, payload: Any, result: dict):
        code = payload.get("code") if isinstance(payload, dict) else None
        message = payload.get("message") if isinstance(payload, dict) else str(payload)
        super().__init__(f"{tool} failed: {code}: {message}")
        self.code = code
        self.message = message or ""
        self.result = result


def parse_only(spec: Optional[str], total: int = 15) -> list[int]:
    if not spec:
        return list(range(1, total + 1))
    chosen: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            low, high = (int(item) for item in part.split("-", 1))
            chosen.update(range(low, high + 1))
        else:
            chosen.add(int(part))
    bad = [n for n in chosen if n < 1 or n > total]
    if bad:
        raise ValueError(f"no such check: {sorted(bad)}")
    return sorted(chosen)


def pkce_pair() -> tuple[str, str]:
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    return verifier, pkce_challenge(verifier)


def pkce_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def write_private_json(path: Path, value: Any) -> None:
    path = Path(path).expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            json.dump(value, handle, indent=2)
            handle.write("\n")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def load_token(path: Path) -> dict:
    text = Path(path).expanduser().read_text(encoding="utf-8").strip()
    if text.startswith("{"):
        data = json.loads(text)
        if not data.get("access_token"):
            raise ProbeError(f"{path} has no access_token")
        return data
    return {"access_token": text, "scope": ""}


def tool_payload(result: dict) -> Any:
    structured = result.get("structuredContent")
    if structured is not None:
        return structured
    texts = [item.get("text", "") for item in result.get("content") or [] if isinstance(item, dict)]
    for text in texts:
        try:
            return json.loads(text)
        except (ValueError, TypeError):
            continue
    return {"text": "\n".join(texts)}


def first_list(payload: Any, *keys: str) -> list:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in keys:
            if isinstance(payload.get(key), list):
                return payload[key]
    return []


def parse_cursor(raw: Any) -> Optional[tuple[str, int]]:
    if not isinstance(raw, str) or "." not in raw:
        return None
    epoch, _, number = raw.rpartition(".")
    if not epoch or not number.isdigit():
        return None
    return epoch, int(number)


def git(*args: str, cwd: Path) -> str:
    completed = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    if completed.returncode != 0:
        raise ProbeError(f"git {' '.join(args)}: {completed.stderr.strip()}")
    return completed.stdout.strip()


def same_path(left: Optional[str], right: Optional[str]) -> bool:
    return bool(left and right) and os.path.realpath(left) == os.path.realpath(right)


# --------------------------------------------------------------------------- HTTP / MCP


class Server:
    def __init__(self, base_url: str):
        parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise ProbeError(f"bad server URL: {base_url}")
        self.base_url = base_url.rstrip("/")
        self.scheme = parsed.scheme
        self.host = parsed.hostname
        self.port = parsed.port or (443 if parsed.scheme == "https" else 80)

    def connection(self, timeout: float) -> http.client.HTTPConnection:
        if self.scheme == "https":
            return http.client.HTTPSConnection(self.host, self.port, timeout=timeout)
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def request(self, method: str, path: str, body: Optional[bytes] = None,
                headers: Optional[dict] = None, timeout: float = 30) -> tuple[int, dict, bytes]:
        connection = self.connection(timeout)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            data = response.read()
            return response.status, {k.lower(): v for k, v in response.getheaders()}, data
        finally:
            connection.close()

    def json(self, method: str, path: str, value: Any = None, form: Optional[dict] = None,
             timeout: float = 30) -> Any:
        headers = {"accept": "application/json"}
        body = None
        if form is not None:
            body = urllib.parse.urlencode(form).encode()
            headers["content-type"] = "application/x-www-form-urlencoded"
        elif value is not None:
            body = json.dumps(value).encode()
            headers["content-type"] = "application/json"
        status, _, data = self.request(method, path, body, headers, timeout)
        if status >= 400:
            raise HttpError(status, data.decode("utf-8", "replace"))
        return json.loads(data or b"null")


class McpClient:
    def __init__(self, server: Server, token: str, request_timeout: float = 60):
        self.server = server
        self.token = token
        self.request_timeout = request_timeout
        self._ids = iter(range(1, 1 << 30))
        self._lock = threading.Lock()
        self.captures: dict[str, Any] = {}

    def _next_id(self) -> int:
        with self._lock:
            return next(self._ids)

    def headers(self, method: str, name: Optional[str]) -> dict:
        headers = {
            "authorization": f"Bearer {self.token}",
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
            "mcp-protocol-version": PROTOCOL_VERSION,
            "mcp-method": method,
        }
        if name:
            headers["mcp-name"] = name
        return headers

    def body(self, method: str, params: dict, request_id: int) -> bytes:
        params = dict(params)
        meta = dict(params.get("_meta") or {})
        meta.update({
            "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
            "io.modelcontextprotocol/clientInfo": CLIENT_INFO,
            "io.modelcontextprotocol/clientCapabilities": {},
        })
        params["_meta"] = meta
        return json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}).encode()

    def call(self, method: str, params: Optional[dict] = None, name: Optional[str] = None,
             timeout: Optional[float] = None) -> Any:
        request_id = self._next_id()
        status, headers, data = self.server.request(
            "POST", "/mcp", self.body(method, params or {}, request_id), self.headers(method, name),
            timeout or self.request_timeout)
        text = data.decode("utf-8", "replace")
        if status >= 400:
            raise HttpError(status, text)
        if "text/event-stream" in headers.get("content-type", ""):
            message = select_rpc_response(rpc_messages_from_sse(text), request_id)
        else:
            message = json.loads(text)
        if "error" in message:
            raise RpcError(message["error"])
        return message.get("result")

    def tool(self, name: str, arguments: Optional[dict] = None, fixture: Optional[str] = None,
             timeout: Optional[float] = None) -> Any:
        result = self.call("tools/call", {"name": name, "arguments": arguments or {}}, name=name, timeout=timeout)
        result = result or {}
        failed = bool(result.get("isError"))
        key = fixture or (f"tool-{name}-error" if failed else f"tool-{name}")
        if fixture or key not in self.captures:
            self.captures[key] = result
        payload = tool_payload(result)
        if failed:
            raise ToolFailure(name, payload, result)
        return payload

    def open_stream(self, name: str, arguments: dict, heartbeat_ms: int):
        request_id = self._next_id()
        params = {"name": name, "arguments": arguments, "heartbeatMs": heartbeat_ms}
        connection = self.server.connection(timeout=max(30.0, heartbeat_ms / 1000 * 3))
        connection.request("POST", "/mcp", body=self.body("events/stream", params, request_id),
                           headers=self.headers("events/stream", name))
        response = connection.getresponse()
        if response.status >= 400:
            body = response.read().decode("utf-8", "replace")
            connection.close()
            raise HttpError(response.status, body)
        return connection, response


class EventStreams:
    """One events/stream subscription per event name, collected on background threads."""

    def __init__(self, client: McpClient, names: Iterable[str], arguments: dict, heartbeat_ms: int = 15000,
                 raw_limit: int = 256 * 1024):
        self.client = client
        self.names = list(names)
        self.arguments = arguments
        self.heartbeat_ms = heartbeat_ms
        self.raw_limit = raw_limit
        self.messages: list[dict] = []
        self.raw: dict[str, list[str]] = {name: [] for name in self.names}
        self.errors: dict[str, str] = {}
        self._condition = threading.Condition()
        self._connections: list[http.client.HTTPConnection] = []
        self._closed = False

    def start(self, timeout: float = 20) -> None:
        for name in self.names:
            threading.Thread(target=self._run, args=(name,), daemon=True, name=f"stream-{name}").start()
        deadline = time.time() + timeout
        for name in self.names:
            found = self.wait_for(lambda m, n=name: m["stream"] == n and m["kind"] in ("active", "error", "closed"),
                                  max(0.1, deadline - time.time()), from_index=0)
            if not found or found["kind"] != "active":
                raise ProbeError(f"stream {name} did not become active: {found or 'timeout'}")

    def _record(self, name: str, kind: str, params: Any) -> None:
        with self._condition:
            self.messages.append({"stream": name, "kind": kind, "params": params, "t": time.time()})
            self._condition.notify_all()

    def _run(self, name: str) -> None:
        size = 0
        try:
            connection, response = self.client.open_stream(name, self.arguments, self.heartbeat_ms)
            self._connections.append(connection)
            if "text/event-stream" not in (response.getheader("content-type") or ""):
                body = response.read().decode("utf-8", "replace")
                self._record(name, "error", body[:500])
                return
            parser = SSEParser()
            while not self._closed:
                raw_line = response.readline()
                if not raw_line:
                    break
                line = raw_line.decode("utf-8", "replace")
                if size < self.raw_limit:
                    self.raw[name].append(line)
                    size += len(line)
                event = parser.feed_line(line)
                if not event:
                    continue
                try:
                    message = json.loads(event["data"])
                except ValueError:
                    continue
                method = str(message.get("method", ""))
                kind = method.rsplit("/", 1)[-1] if method.startswith("notifications/events/") else "other"
                if "error" in message:
                    kind = "error"
                self._record(name, kind, message.get("params", message.get("error")))
                if kind == "terminated":
                    break
        except Exception as error:  # noqa: BLE001 - recorded for the report
            if not self._closed:
                self.errors[name] = str(error)
                self._record(name, "error", str(error))
        self._record(name, "closed", None)

    def wait_for(self, predicate: Callable[[dict], bool], timeout: float, from_index: int = 0) -> Optional[dict]:
        deadline = time.time() + timeout
        with self._condition:
            index = from_index
            while True:
                while index < len(self.messages):
                    message = self.messages[index]
                    index += 1
                    if predicate(message):
                        return message
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                self._condition.wait(min(remaining, 1.0))

    def mark(self) -> int:
        with self._condition:
            return len(self.messages)

    def events(self, since: int = 0, thread_id: Optional[str] = None) -> list[dict]:
        with self._condition:
            found = [m for m in self.messages[since:] if m["kind"] == "event"]
        if thread_id:
            found = [m for m in found if (m["params"] or {}).get("data", {}).get("threadId") == thread_id]
        return found

    def wait_event(self, name: str, thread_id: str, timeout: float, since: int = 0,
                   extra: Optional[Callable[[dict], bool]] = None) -> Optional[dict]:
        def matches(message: dict) -> bool:
            if message["kind"] != "event":
                return False
            params = message["params"] or {}
            data = params.get("data") or {}
            return (params.get("name") == name and data.get("threadId") == thread_id
                    and (extra is None or extra(data)))
        return self.wait_for(matches, timeout, from_index=since)

    def close(self) -> None:
        self._closed = True
        for connection in self._connections:
            try:
                if connection.sock:
                    connection.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()


# --------------------------------------------------------------------------- OAuth


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib name
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if urllib.parse.urlsplit(self.path).path != "/callback":
            self.send_response(404)
            self.end_headers()
            return
        self.server.result = {key: values[0] for key, values in query.items()}  # type: ignore[attr-defined]
        self.send_response(200)
        self.send_header("content-type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"Focus Queue contract probe: you can close this tab.\n")

    def log_message(self, *args: Any) -> None:
        pass


def open_in_browser(url: str) -> None:
    if sys.platform == "darwin" and shutil.which("open"):
        subprocess.run(["open", url], check=False)
    else:
        import webbrowser
        webbrowser.open(url)


def login(server: Server, token_file: Path, timeout: float = 600,
          opener: Callable[[str], None] = open_in_browser) -> dict:
    metadata: dict = {}
    try:
        metadata = server.json("GET", "/.well-known/oauth-authorization-server") or {}
    except (ProbeError, OSError, ValueError):
        pass

    def endpoint(key: str, default: str) -> str:
        value = metadata.get(key) or default
        parsed = urllib.parse.urlsplit(value)
        return (parsed.path + ("?" + parsed.query if parsed.query else "")) if parsed.scheme else value

    callback = http.server.HTTPServer(("127.0.0.1", 0), _CallbackHandler)
    callback.result = None  # type: ignore[attr-defined]
    callback.timeout = 1
    redirect_uri = f"http://127.0.0.1:{callback.server_address[1]}/callback"
    try:
        registration = server.json("POST", endpoint("registration_endpoint", "/oauth/mcp/register"), {
            "client_name": "Focus Queue contract probe",
            "redirect_uris": [redirect_uri],
            "grant_types": ["authorization_code"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": SCOPE,
        })
        client_id = registration["client_id"]
        verifier, challenge = pkce_pair()
        state = secrets.token_urlsafe(24)
        resource = f"{server.base_url}/mcp"
        query = urllib.parse.urlencode({
            "response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri,
            "scope": SCOPE, "state": state, "code_challenge": challenge,
            "code_challenge_method": "S256", "resource": resource,
        })
        authorize = server.base_url + endpoint("authorization_endpoint", "/oauth/mcp/authorize") + "?" + query
        print("Opening T3 Code's approval page. Choose Full access, then approve.")
        print(f"If no browser opens, visit:\n  {authorize}")
        opener(authorize)
        deadline = time.time() + timeout
        while callback.result is None and time.time() < deadline:  # type: ignore[attr-defined]
            callback.handle_request()
        result = callback.result  # type: ignore[attr-defined]
    finally:
        callback.server_close()
    if result is None:
        raise ProbeError("sign-in timed out")
    if result.get("error"):
        raise ProbeError(f"sign-in failed: {result.get('error')} {result.get('error_description', '')}")
    if result.get("state") != state:
        raise ProbeError("sign-in failed: state mismatch")
    token = server.json("POST", endpoint("token_endpoint", "/oauth/mcp/token"), form={
        "grant_type": "authorization_code", "code": result.get("code", ""), "redirect_uri": redirect_uri,
        "client_id": client_id, "code_verifier": verifier, "resource": resource,
    })
    now = int(time.time())
    saved = dict(token)
    saved.update({"client_id": client_id, "redirect_uri": redirect_uri, "server": server.base_url,
                  "obtained_at": now})
    if isinstance(token.get("expires_in"), (int, float)):
        saved["expires_at"] = now + int(token["expires_in"])
    write_private_json(token_file, saved)
    return saved


# --------------------------------------------------------------------------- probe


CHECKS: list[tuple[int, str, float]] = [
    (1, "server/discover lists io.modelcontextprotocol/events", 60),
    (2, "t3_environment_read returns environmentId", 60),
    (3, "granted scope contains settings:write (Full access)", 30),
    (4, "duplicate t3_project_create is 'already registered'", 60),
    (5, "launch into existing_worktree; commit lands on its branch", 300),
    (6, "non-project worktreePath rejected with invalid_request", 60),
    (7, "same clientRequestId returns the same thread", 120),
    (8, "question round trip (needs_input user_input, list/read/respond)", 300),
    (9, "approval: needs_input approval, pendingRequestCount 1, list []", 240),
    (10, "outside turn: no event before settle; list shows running", 240),
    (11, "interrupt -> interrupted; shell loop stops writing", 240),
    (12, "stop:true leaves a queued prompt unrun", 300),
    (13, "organize settle then archive -> archived: true", 240),
    (14, "orchestrator_capabilities lists providers with constraints", 60),
    (15, "event cursors share one <epoch>.<n> sequence", 240),
]


class Probe:
    def __init__(self, client: McpClient, token: dict, verbose: bool = False):
        self.client = client
        self.token = token
        self.verbose = verbose
        self.sanitizer = Sanitizer()
        self.sanitizer.register_literal(token.get("access_token"), "TOKEN")
        self.sanitizer.register_path(os.path.expanduser("~"), "/HOME")
        self.temp: Optional[Path] = None
        self.repo: Optional[Path] = None
        self.project_id: Optional[str] = None
        self.model_selection: Optional[dict] = None
        self.streams: Optional[EventStreams] = None
        self.threads: list[str] = []
        self.extra: dict[str, Any] = {}
        self._worktree_count = 0

    def log(self, message: str) -> None:
        if self.verbose:
            print(f"  . {message}", flush=True)

    # setup -----------------------------------------------------------------

    def ensure_repo(self) -> Path:
        if self.repo:
            return self.repo
        self.temp = Path(tempfile.mkdtemp(prefix=TEMP_PREFIX))
        self.sanitizer.register_path(str(self.temp), "/TMP")
        repo = self.temp / "repo"
        repo.mkdir()
        git("init", "-q", "-b", "main", cwd=repo)
        git("config", "user.name", "Focus Queue Probe", cwd=repo)
        git("config", "user.email", "probe@example.invalid", cwd=repo)
        git("config", "commit.gpgsign", "false", cwd=repo)
        (repo / "README.md").write_text("# fq contract probe\n")
        with open(repo / ".git" / "info" / "exclude", "a") as handle:
            handle.write(".worktrees/\n")
        git("add", "README.md", cwd=repo)
        git("commit", "-q", "-m", "init", cwd=repo)
        self.repo = repo
        self.sanitizer.register_path(str(repo), "/REPO")
        return repo

    def worktree(self, name: Optional[str] = None) -> tuple[Path, str]:
        repo = self.ensure_repo()
        self._worktree_count += 1
        name = name or f"a{self._worktree_count}"
        path = repo / ".worktrees" / "foc-1" / "agents" / name
        if path.exists():
            return path, f"focus-queue/foc-1-{name}"
        branch = f"focus-queue/foc-1-{name}"
        path.parent.mkdir(parents=True, exist_ok=True)
        git("worktree", "add", "-q", "-b", branch, str(path), "main", cwd=repo)
        return path, branch

    def ensure_project(self) -> str:
        if self.project_id:
            return self.project_id
        repo = self.ensure_repo()
        self.delete_stale_projects()
        payload = self.client.tool("t3_project_create", {"title": PROJECT_TITLE, "workspaceRoot": str(repo)})
        project = payload.get("project", payload) if isinstance(payload, dict) else {}
        self.project_id = project.get("id") or project.get("projectId")
        if not self.project_id:
            raise ProbeError(f"t3_project_create returned no id: {payload}")
        self.sanitizer.register(self.project_id, "PROJECT")
        return self.project_id

    def list_projects(self) -> list[dict]:
        projects: list[dict] = []
        cursor: Any = None
        for _ in range(50):
            arguments = {"limit": 100}
            if cursor is not None:
                arguments["cursor"] = cursor
            payload = self.client.tool("t3_project_list", arguments)
            projects.extend(first_list(payload, "projects", "items", "data"))
            cursor = payload.get("nextCursor") if isinstance(payload, dict) else None
            if cursor is None:
                break
        return projects

    def delete_stale_projects(self) -> None:
        """Removes probe projects left by an earlier --keep run (title and temp root both match)."""
        for project in self.list_projects():
            root = str(project.get("workspaceRoot", ""))
            if project.get("title") == PROJECT_TITLE and TEMP_PREFIX in root:
                project_id = project.get("id") or project.get("projectId")
                if project_id and project_id != self.project_id:
                    self.log(f"deleting stale probe project {project_id}")
                    self.client.tool("t3_project_delete", {"projectId": project_id, "force": True})

    def ensure_model(self) -> dict:
        if self.model_selection:
            return self.model_selection
        payload = self.client.tool("orchestrator_capabilities", {})
        self.extra["capabilities"] = self.client.captures.get("tool-orchestrator_capabilities")
        for provider in first_list(payload, "providers"):
            if provider.get("driverKind") != PROVIDER_DRIVER:
                continue
            if DISABLED_CONSTRAINT in (provider.get("constraints") or []):
                continue
            models = [model.get("id") for model in provider.get("models") or []]
            if MODEL not in models:
                raise ProbeError(f"{PROVIDER_DRIVER} provider has no {MODEL} (has {models})")
            self.model_selection = {"instanceId": provider["providerInstanceId"], "model": MODEL}
            return self.model_selection
        raise ProbeError(f"no enabled {PROVIDER_DRIVER} provider in orchestrator_capabilities")

    def ensure_streams(self) -> EventStreams:
        if self.streams:
            return self.streams
        streams = EventStreams(self.client, WATCHED_EVENTS, {"projectIds": [self.ensure_project()]})
        streams.start()
        self.streams = streams
        return streams

    # thread helpers --------------------------------------------------------

    def launch(self, title: str, message: str, worktree_path: Path, client_request_id: Optional[str] = None,
               runtime_mode: str = "full-access", fixture: Optional[str] = None) -> dict:
        arguments = {
            "title": title,
            "projectId": self.ensure_project(),
            "message": message,
            "modelSelection": self.ensure_model(),
            "workspaceStrategy": {"type": "existing_worktree", "worktreePath": str(worktree_path)},
            "runtimeMode": runtime_mode,
            "clientRequestId": client_request_id or f"fq-probe-{uuid.uuid4()}",
        }
        payload = self.client.tool("t3_thread_launch", arguments, fixture=fixture)
        thread_id = payload.get("threadId")
        if not thread_id:
            raise ProbeError(f"t3_thread_launch returned no threadId: {payload}")
        if thread_id not in self.threads:
            self.threads.append(thread_id)
        return payload

    def read(self, thread_id: str, fixture: Optional[str] = None, **extra: Any) -> dict:
        arguments = {"threadId": thread_id, "limit": 1, "runLimit": 5}
        arguments.update(extra)
        return self.client.tool("t3_thread_read", arguments, fixture=fixture)

    def list_threads(self, fixture: Optional[str] = None) -> list[dict]:
        payload = self.client.tool("t3_thread_list", {"projectId": self.ensure_project()}, fixture=fixture)
        return first_list(payload, "threads", "items", "data")

    def thread_row(self, thread_id: str) -> Optional[dict]:
        return next((row for row in self.list_threads() if row.get("threadId") == thread_id), None)

    def wait_until(self, predicate: Callable[[], Any], timeout: float, interval: float = 1.5) -> Any:
        deadline = time.time() + timeout
        while True:
            value = predicate()
            if value:
                return value
            if time.time() >= deadline:
                return None
            time.sleep(interval)

    def wait_idle(self, thread_id: str, timeout: float = 180) -> dict:
        def idle() -> Optional[dict]:
            snapshot = self.read(thread_id)
            thread = snapshot.get("thread") or {}
            if thread.get("activeRunId") is None and thread.get("status") not in ACTIVE_THREAD_STATUSES:
                return snapshot
            return None
        snapshot = self.wait_until(idle, timeout, interval=2)
        if not snapshot:
            raise ProbeError(f"thread did not settle within {timeout:.0f}s")
        return snapshot

    def wait_running(self, thread_id: str, timeout: float = 60) -> dict:
        def running() -> Optional[dict]:
            snapshot = self.read(thread_id)
            thread = snapshot.get("thread") or {}
            return snapshot if thread.get("activeRunId") else None
        snapshot = self.wait_until(running, timeout)
        if not snapshot:
            raise ProbeError("thread never started a run")
        return snapshot

    def quick_thread(self, title: str) -> str:
        path, _ = self.worktree()
        thread_id = self.launch(title, "Reply with the single word ok. Do not use any tools.", path)["threadId"]
        self.wait_idle(thread_id)
        return thread_id

    @staticmethod
    def file_size(path: Path) -> int:
        try:
            return path.stat().st_size
        except FileNotFoundError:
            return -1

    # checks ----------------------------------------------------------------

    def check_1(self) -> str:
        result = self.client.call("server/discover", {})
        self.extra["discover"] = result
        extensions = ((result or {}).get("capabilities") or {}).get("extensions") or {}
        if EVENTS_EXTENSION not in extensions:
            raise ProbeError(f"extensions: {sorted(extensions)}")
        server_info = ((result or {}).get("_meta") or {}).get("io.modelcontextprotocol/serverInfo") or {}
        return f"server {server_info.get('name')} {server_info.get('version')}"

    def check_2(self) -> str:
        payload = self.client.tool("t3_environment_read", {})
        environment_id = payload.get("environmentId")
        if not environment_id:
            raise ProbeError(f"no environmentId in {sorted(payload)}")
        self.sanitizer.register(environment_id, "ENVIRONMENT")
        self.sanitizer.register_literal(payload.get("label"), "Test Mac")
        return f"serverVersion {payload.get('serverVersion')}"

    def check_3(self) -> str:
        scope = str(self.token.get("scope", ""))
        if "settings:write" not in scope.split():
            raise ProbeError(f"granted scope is '{scope}'; reconnect with --login and choose Full access")
        return scope

    def check_4(self) -> str:
        self.ensure_project()
        try:
            self.client.tool("t3_project_create", {"title": PROJECT_TITLE, "workspaceRoot": str(self.repo)},
                             fixture="tool-t3_project_create-duplicate")
        except ToolFailure as failure:
            if "already registered" in failure.message:
                return f"{failure.code}: {failure.message}"
            raise
        raise ProbeError("duplicate project was accepted")

    def check_5(self) -> str:
        path, branch = self.worktree("a1")
        thread_id = self.launch(
            "fq-probe launch", "In the current directory, create a file named probe.txt containing the word ok, "
            "then run `git add probe.txt && git commit -m 'probe commit'`. Reply with only: done", path)["threadId"]
        snapshot = self.wait_idle(thread_id)
        thread = snapshot.get("thread") or {}
        if not same_path(thread.get("worktreePath"), str(path)):
            raise ProbeError(f"thread worktreePath {thread.get('worktreePath')} != checkout")
        subject = git("log", "-1", "--format=%s", branch, cwd=path)
        if "probe" not in subject:
            raise ProbeError(f"latest commit on {branch} is '{subject}'")
        if git("rev-list", "--count", "main", cwd=self.ensure_repo()) != "1":
            raise ProbeError("commit landed on main")
        return f"commit '{subject}' on {branch}; branch field {thread.get('branch')!r}"

    def check_6(self) -> str:
        self.ensure_project()
        outside = self.temp / "outside"  # type: ignore[operator]
        outside.mkdir(exist_ok=True)
        try:
            payload = self.launch("fq-probe outside", "Reply ok.", outside, fixture="tool-t3_thread_launch-rejected")
        except ToolFailure as failure:
            if failure.code == "invalid_request":
                return failure.message
            raise
        raise ProbeError(f"launch outside the project succeeded: {payload.get('threadId')}")

    def check_7(self) -> str:
        path, _ = self.worktree()
        request_id = f"fq-probe-{uuid.uuid4()}"
        first = self.launch("fq-probe idempotent", "Reply with the single word ok.", path, request_id)
        second = self.launch("fq-probe idempotent", "Reply with the single word ok.", path, request_id,
                             fixture="tool-t3_thread_launch-repeat")
        if first["threadId"] != second["threadId"]:
            raise ProbeError(f"different threads: {first['threadId']} vs {second['threadId']}")
        self.wait_idle(first["threadId"])
        return "same threadId"

    def check_8(self) -> str:
        streams = self.ensure_streams()
        path, _ = self.worktree()
        mark = streams.mark()
        thread_id = self.launch(
            "fq-probe question",
            "Use your AskUserQuestion tool (ask-user-question) right now to ask me exactly one question with "
            "header \"Probe\", question \"Pick one\", and exactly two options: \"Option A\" and \"Option B\". "
            "Do nothing else. After I answer, reply with only the label I chose.", path)["threadId"]
        event = streams.wait_event(EVENT_NEEDS_INPUT, thread_id, 150, mark,
                                   extra=lambda data: data.get("kind") == "user_input")
        if not event:
            raise ProbeError("no thread.needs_input kind:user_input")
        request_id = event["params"]["data"].get("requestId")
        listed = self.client.tool("t3_pending_request", {"action": "list", "threadId": thread_id},
                                  fixture="tool-t3_pending_request-list")
        if request_id not in (listed.get("requestIds") or []):
            raise ProbeError(f"requestId not listed: {listed}")
        request = self.client.tool("t3_pending_request",
                                   {"action": "read", "threadId": thread_id, "requestId": request_id},
                                   fixture="tool-t3_pending_request-read")
        questions = request.get("questions") or []
        if not questions:
            raise ProbeError("pending request has no questions")
        labels = [option.get("label") for option in questions[0].get("options") or []]
        if "Option B" not in labels:
            raise ProbeError(f"options are {labels}")
        self.client.tool("t3_pending_request", {
            "action": "respond", "threadId": thread_id, "requestId": request_id,
            "answers": {questions[0]["id"]: "Option B"},
        }, fixture="tool-t3_pending_request-respond")
        resolved = streams.wait_event(EVENT_INPUT_RESOLVED, thread_id, 30, mark,
                                      extra=lambda data: data.get("requestId") == request_id)
        if not resolved:
            raise ProbeError("no thread.input_resolved after respond")
        self.wait_idle(thread_id)
        return f"answered Option B; resolution {resolved['params']['data'].get('resolution')!r}"

    def check_9(self) -> str:
        streams = self.ensure_streams()
        path, _ = self.worktree()
        mark = streams.mark()
        thread_id = self.launch(
            "fq-probe approval", "Run the shell command `touch approval-probe.txt` in the current directory "
            "with your Bash tool. Reply with only: done", path, runtime_mode="approval-required")["threadId"]
        event = streams.wait_event(EVENT_NEEDS_INPUT, thread_id, 150, mark,
                                   extra=lambda data: data.get("kind") == "approval")
        if not event:
            raise ProbeError("no thread.needs_input kind:approval")
        snapshot = self.read(thread_id, fixture="tool-t3_thread_read-approval")
        self.read(thread_id, fixture="tool-t3_thread_read-activity", view="activity", limit=20)
        count = (snapshot.get("thread") or {}).get("pendingRequestCount")
        listed = self.client.tool("t3_pending_request", {"action": "list", "threadId": thread_id},
                                  fixture="tool-t3_pending_request-list-approval")
        request_ids = listed.get("requestIds")
        try:
            self.client.tool("t3_thread_interrupt", {"threadId": thread_id, "stop": True, "reason": "probe done"})
        except ToolFailure:
            pass
        if count != 1:
            raise ProbeError(f"pendingRequestCount {count}")
        if request_ids != []:
            raise ProbeError(f"t3_pending_request list returned {request_ids}")
        return "approval hidden from t3_pending_request; counted in pendingRequestCount"

    def check_10(self) -> str:
        streams = self.ensure_streams()
        thread_id = self.quick_thread("fq-probe external turn")
        before = self.thread_row(thread_id) or {}
        mark = streams.mark()
        self.client.tool("t3_thread_send", {
            "threadId": thread_id, "mode": "auto",
            "message": "Run `sleep 20` with your Bash tool, then reply with only: ok",
        })
        sent_at = time.time()

        def running() -> Optional[dict]:
            row = self.thread_row(thread_id)
            if row and row.get("status") == "running" and row.get("latestRunId") not in (None, before.get("latestRunId")):
                return row
            return None
        row = self.wait_until(running, 15, interval=1)
        self.list_threads(fixture="tool-t3_thread_list-running")
        seen_after = time.time() - sent_at
        settled = streams.wait_event(EVENT_RUN_SETTLED, thread_id, 120, mark)
        if not row:
            raise ProbeError("t3_thread_list never showed running with a new latestRunId")
        if not settled:
            raise ProbeError("no thread.run_settled for the outside turn")
        early = [m for m in streams.events(mark, thread_id) if m["t"] < settled["t"]]
        if early:
            raise ProbeError(f"events before settle: {[m['params'].get('name') for m in early]}")
        return f"list showed running after {seen_after:.1f}s; first event was run_settled"

    def check_11(self) -> str:
        path, _ = self.worktree()
        log = path / "loop.txt"
        thread_id = self.launch(
            "fq-probe interrupt", "Run exactly this in your Bash tool and wait for it to finish: "
            "`for i in $(seq 60); do echo $i >> loop.txt; sleep 1; done`. Then reply with only: done",
            path)["threadId"]
        if not self.wait_until(lambda: self.file_size(log) > 4, 120, interval=1):
            raise ProbeError("shell loop never started writing loop.txt")
        interrupted = self.client.tool("t3_thread_interrupt", {"threadId": thread_id, "reason": "probe"})
        if interrupted.get("status") != "interrupt_requested":
            raise ProbeError(f"interrupt returned {interrupted}")
        waited = self.client.tool("t3_thread_wait", {
            "threadId": thread_id, "runId": interrupted.get("runId"), "timeoutMs": 30000}, timeout=60)
        status = waited.get("status") or (waited.get("run") or {}).get("status")
        if status != "interrupted":
            raise ProbeError(f"t3_thread_wait returned {waited}")
        settled_size = self.file_size(log)
        time.sleep(4)
        grown = self.file_size(log) - settled_size
        if grown:
            raise ProbeError(f"loop.txt grew {grown} bytes after the interrupt settled")
        return "interrupted; 0 bytes written after settle"

    def check_12(self) -> str:
        path, _ = self.worktree()
        thread_id = self.launch(
            "fq-probe stop", "Run `sleep 45` with your Bash tool, then reply with only: done", path)["threadId"]
        self.wait_running(thread_id)
        self.client.tool("t3_thread_send", {
            "threadId": thread_id, "mode": "queue",
            "message": "Run `touch queued.txt` with your Bash tool. Reply with only: done"})
        time.sleep(2)
        stopped = self.client.tool("t3_thread_interrupt", {"threadId": thread_id, "stop": True, "reason": "probe"},
                                   fixture="tool-t3_thread_interrupt-stop")
        if stopped.get("status") != "interrupt_requested":
            raise ProbeError(f"interrupt returned {stopped}")

        def held() -> Optional[dict]:
            snapshot = self.read(thread_id)
            thread = snapshot.get("thread") or {}
            return snapshot if thread.get("activeRunId") is None and thread.get("status") == "queued" else None
        snapshot = self.wait_until(held, 60, interval=2)
        if not snapshot:
            raise ProbeError(f"thread did not hold its queue: {self.read(thread_id).get('thread')}")
        self.read(thread_id, fixture="tool-t3_thread_read-held")
        time.sleep(10)
        if (path / "queued.txt").exists():
            raise ProbeError("queued prompt ran after stop:true")
        if (self.read(thread_id).get("thread") or {}).get("activeRunId"):
            raise ProbeError("a new run started after stop:true")
        return "status queued, no active run, queued prompt unrun after 10s"

    def check_13(self) -> str:
        thread_id = self.quick_thread("fq-probe archive")
        self.client.tool("t3_thread_organize", {"threadId": thread_id, "action": "settle"},
                         fixture="tool-t3_thread_organize-settle")
        self.client.tool("t3_thread_organize", {"threadId": thread_id, "action": "archive"},
                         fixture="tool-t3_thread_organize-archive")
        thread = self.read(thread_id, fixture="tool-t3_thread_read-archived").get("thread") or {}
        if thread.get("archived") is not True:
            raise ProbeError(f"archived is {thread.get('archived')!r}")
        return f"archived true, settled {thread.get('settled')!r}"

    def check_14(self) -> str:
        payload = self.client.tool("orchestrator_capabilities", {})
        self.extra["capabilities"] = self.client.captures.get("tool-orchestrator_capabilities")
        providers = first_list(payload, "providers")
        if not providers:
            raise ProbeError("no providers")
        missing = [p.get("providerInstanceId") for p in providers if not isinstance(p.get("constraints"), list)]
        if missing:
            raise ProbeError(f"providers without constraints: {missing}")
        enabled = [p for p in providers if not p["constraints"]]
        return f"{len(providers)} providers, {len(enabled)} without constraints"

    def check_15(self) -> str:
        streams = self.ensure_streams()
        if not streams.events():
            self.quick_thread("fq-probe cursor")
            streams.wait_for(lambda m: m["kind"] == "event", 60, from_index=0)
        cursors: list[tuple[str, str, int, Optional[str]]] = []
        for message in streams.messages:
            params = message["params"] if isinstance(message["params"], dict) else {}
            parsed = parse_cursor(params.get("cursor"))
            if message["kind"] in ("active", "heartbeat", "event") and params.get("cursor") is not None:
                if not parsed:
                    raise ProbeError(f"cursor {params.get('cursor')!r} is not <epoch>.<n>")
                cursors.append((message["stream"], parsed[0], parsed[1], params.get("eventId")))
        streams_with_cursors = {item[0] for item in cursors}
        epochs = {item[1] for item in cursors}
        if len(streams_with_cursors) < len(WATCHED_EVENTS):
            raise ProbeError(f"cursors seen on {sorted(streams_with_cursors)} only")
        if len(epochs) != 1:
            raise ProbeError(f"epochs differ: {sorted(epochs)}")
        by_number: dict[int, set] = {}
        for _, _, number, event_id in cursors:
            if event_id:
                by_number.setdefault(number, set()).add(event_id)
        clashes = {number: ids for number, ids in by_number.items() if len(ids) > 1}
        if clashes:
            raise ProbeError(f"one sequence number used by different events: {clashes}")
        events = [item for item in cursors if item[3]]
        if not events:
            raise ProbeError("no events received to compare")
        return f"epoch {epochs.pop()}, {len(events)} events across {len(streams_with_cursors)} streams"

    # run -------------------------------------------------------------------

    def run_check(self, number: int, timeout: float) -> tuple[bool, str]:
        outcome: dict[str, Any] = {}

        def target() -> None:
            try:
                outcome["detail"] = getattr(self, f"check_{number}")()
                outcome["ok"] = True
            except Exception as error:  # noqa: BLE001 - reported as FAIL
                outcome["ok"] = False
                outcome["detail"] = f"{type(error).__name__}: {error}"
                if self.verbose:
                    traceback.print_exc()

        worker = threading.Thread(target=target, daemon=True, name=f"check-{number}")
        worker.start()
        worker.join(timeout)
        if worker.is_alive():
            return False, f"timed out after {timeout:.0f}s"
        return bool(outcome.get("ok")), str(outcome.get("detail", ""))

    def teardown(self) -> list[str]:
        problems: list[str] = []
        if self.streams:
            self.streams.close()
        if self.project_id:
            try:
                self.client.tool("t3_project_delete", {"projectId": self.project_id, "force": True},
                                 timeout=60)
            except Exception as error:  # noqa: BLE001
                problems.append(f"t3_project_delete failed: {error}")
        try:
            self.delete_stale_projects()
            leftovers = [p for p in self.list_projects() if p.get("title") == PROJECT_TITLE]
            if leftovers:
                problems.append(f"{len(leftovers)} project(s) titled {PROJECT_TITLE} remain")
        except Exception as error:  # noqa: BLE001
            problems.append(f"could not verify project cleanup: {error}")
        if self.temp and self.temp.exists():
            shutil.rmtree(self.temp, ignore_errors=True)
            if self.temp.exists():
                problems.append(f"temporary directory remains: {self.temp}")
        return problems

    def fixtures(self) -> dict[str, str]:
        """Sanitized fixture file name -> text."""
        raw: dict[str, Any] = dict(self.client.captures)
        if self.extra.get("discover") is not None:
            raw["discover"] = self.extra["discover"]
        if self.extra.get("capabilities") is not None:
            raw["capabilities"] = self.extra["capabilities"]
        stream_text = ""
        if self.streams:
            ranked = sorted(self.streams.raw.items(),
                            key=lambda item: sum("notifications/events/event" in line for line in item[1]))
            stream_text = "".join(ranked[-1][1]) if ranked else ""
        for value in raw.values():
            self.sanitizer.observe(value)
        if stream_text:
            self.sanitizer.observe_sse(stream_text)
        files = {f"{name}.json": json.dumps(self.sanitizer.value(value), indent=2, ensure_ascii=False) + "\n"
                 for name, value in raw.items()}
        if stream_text:
            files["stream.sse"] = self.sanitizer.text(stream_text)
        return files


def write_fixtures(files: dict[str, str], directory: Path) -> list[str]:
    directory.mkdir(parents=True, exist_ok=True)
    problems = []
    for name, text in sorted(files.items()):
        leaks = find_leaks(text)
        if leaks:
            problems.append(f"{name}: {', '.join(leaks)} (not written)")
            continue
        (directory / name).write_text(text, encoding="utf-8")
    return problems


def print_table(rows: list[tuple[int, str, bool, str]]) -> None:
    print()
    print(f"{'#':>2}  {'Result':<6}  Check")
    print(f"{'-' * 2}  {'-' * 6}  {'-' * 60}")
    for number, title, ok, detail in rows:
        print(f"{number:>2}  {'PASS' if ok else 'FAIL':<6}  {title}")
        if detail:
            print(f"{'':>10}{detail[:200]}")
    passed = sum(1 for row in rows if row[2])
    print(f"\n{passed}/{len(rows)} passed")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="t3_contract_probe.py",
        description="Verify the T3 Code MCP contract Focus Queue relies on, as an outside OAuth client, "
                    "and capture sanitized fixtures into Tests/Fixtures/T3/.")
    parser.add_argument("--server", default=DEFAULT_SERVER, help=f"T3 Code server URL (default {DEFAULT_SERVER})")
    parser.add_argument("--token-file", required=True, type=Path,
                        help="token JSON written by --login (or a file holding a bare access token)")
    parser.add_argument("--login", action="store_true",
                        help="sign in with OAuth (opens T3 Code's approval page), save the token with mode 600, "
                             "and exit")
    parser.add_argument("--login-timeout", type=float, default=600, help="seconds to wait for approval")
    parser.add_argument("--only", help="run a subset of checks, e.g. 1,2,5-7")
    parser.add_argument("--keep", action="store_true",
                        help="skip teardown: keep the scratch project, threads and temporary repo")
    parser.add_argument("--fixtures-dir", type=Path, default=DEFAULT_FIXTURES,
                        help="where sanitized fixtures are written")
    parser.add_argument("--no-fixtures", action="store_true", help="do not write fixtures")
    parser.add_argument("--timeout-scale", type=float, default=1.0, help="multiply every per-check timeout")
    parser.add_argument("--verbose", "-v", action="store_true")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        only = parse_only(args.only, len(CHECKS))
        server = Server(args.server)
    except (ValueError, ProbeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.login:
        try:
            saved = login(server, args.token_file, args.login_timeout)
        except (ProbeError, OSError, KeyError, ValueError) as error:
            print(f"sign-in failed: {error}", file=sys.stderr)
            return 1
        print(f"Saved token to {args.token_file} (mode 600). Granted scope: {saved.get('scope', '?')}")
        print(f"Next: python3 {sys.argv[0]} --token-file {args.token_file}")
        return 0

    try:
        token = load_token(args.token_file)
    except (OSError, ValueError, ProbeError) as error:
        print(f"error: cannot read token: {error}", file=sys.stderr)
        return 2
    probe = Probe(McpClient(server, token["access_token"]), token, verbose=args.verbose)
    rows: list[tuple[int, str, bool, str]] = []
    problems: list[str] = []
    try:
        for number, title, timeout in CHECKS:
            if number not in only:
                continue
            print(f"[{number:>2}] {title} ...", flush=True)
            ok, detail = probe.run_check(number, timeout * args.timeout_scale)
            rows.append((number, title, ok, detail))
            print(f"     {'PASS' if ok else 'FAIL'} {detail[:160]}", flush=True)
    except KeyboardInterrupt:
        problems.append("interrupted by user")
    finally:
        if not args.no_fixtures:
            problems.extend(write_fixtures(probe.fixtures(), args.fixtures_dir))
        if args.keep:
            print(f"\n--keep: project {probe.project_id}, repo {probe.repo}, threads {len(probe.threads)}")
        else:
            problems.extend(probe.teardown())
    print_table(rows)
    for problem in problems:
        print(f"problem: {problem}")
    return 0 if rows and all(row[2] for row in rows) and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
