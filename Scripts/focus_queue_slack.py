#!/usr/bin/env python3
"""Read-only Slack collection for the Focus Queue daily report.

The connector reads conversations the token's identity belongs to: channels a
bot was invited to with an xoxb- token, or the user's channels and direct
messages with an xoxp- token. It never posts, reacts, or marks anything read.
"""

from __future__ import annotations

import datetime as dt
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

API_BASE = "https://slack.com/api"
CONVERSATION_TYPES = "public_channel,private_channel,mpim,im"
MAX_CONVERSATIONS = 500
MAX_MESSAGES_PER_SOURCE = 5_000
MAX_THREADS_PER_CONVERSATION = 50
MAX_USER_LOOKUPS = 200
MAX_RATE_LIMIT_WAIT_SECONDS = 30.0
REQUIRED_SCOPES = "channels:history, groups:history, im:history, mpim:history, channels:read, groups:read, im:read, mpim:read, users:read"
# Errors that mean this identity cannot read one conversation. The workspace
# decides membership, so these are coverage gaps rather than failed reads.
HIDDEN_CONVERSATION_ERRORS = {"not_in_channel", "channel_not_found", "access_denied"}
AUTHENTICATION_ERRORS = {"invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"}
# Message subtypes that are membership or system notices, not conversation.
SKIPPED_SUBTYPES = {
    "bot_message", "channel_join", "channel_leave", "channel_topic", "channel_purpose",
    "channel_name", "channel_archive", "channel_unarchive", "group_join", "group_leave",
    "group_topic", "group_purpose", "group_name", "group_archive", "group_unarchive",
    "pinned_item", "unpinned_item", "reminder_add", "tombstone", "message_deleted",
}


class SlackAccessError(RuntimeError):
    def __init__(self, message: str, *, code: str = "slack_access_failed") -> None:
        super().__init__(message)
        self.code = code


Requester = Callable[[str, str, dict[str, str]], dict[str, Any]]


def slack_get(token: str, method: str, parameters: dict[str, str]) -> dict[str, Any]:
    query = urllib.parse.urlencode({key: value for key, value in parameters.items() if value})
    request = urllib.request.Request(
        f"{API_BASE}/{method}?{query}",
        headers={"Authorization": f"Bearer {token}", "User-Agent": "ECCFocusQueue/1.0"},
    )
    waited = 0.0
    while True:
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 429 and waited < MAX_RATE_LIMIT_WAIT_SECONDS:
                delay = min(float(error.headers.get("Retry-After") or 1), 10.0)
                time.sleep(delay)
                waited += delay
                continue
            raise SlackAccessError(f"Slack {method} returned HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise SlackAccessError(
                f"Could not reach Slack for {method}; check the network connection.",
                code="slack_unreachable",
            ) from error
        if not isinstance(payload, dict):
            raise SlackAccessError(f"Slack {method} returned an invalid response")
        return payload


def checked(payload: dict[str, Any], method: str) -> dict[str, Any]:
    if payload.get("ok"):
        return payload
    error = str(payload.get("error") or "unknown_error")
    if error in AUTHENTICATION_ERRORS:
        raise SlackAccessError(
            f"Slack rejected the token ({error}); replace slackToken in the credentials file.",
            code="slack_auth_failed",
        )
    if error == "missing_scope":
        needed = str(payload.get("needed") or REQUIRED_SCOPES)
        raise SlackAccessError(
            f"The Slack token lacks the {needed} scope for {method}; add it to the Slack app "
            "and reinstall the app to the workspace.",
            code="slack_missing_scope",
        )
    raise SlackAccessError(f"Slack {method} failed: {error}", code=f"slack_{error}")


def credential_path(config: dict[str, Any]) -> Path:
    """slackCredentialPath, else the shared credentials file beside ingestion.json."""
    configured = config.get("slackCredentialPath") or config.get("discordCredentialPath")
    if configured:
        return Path(str(configured)).expanduser()
    if config.get("_configPath"):
        return Path(config["_configPath"]).expanduser().parent / "credentials.json"
    return Path.home() / "Library/Application Support/ECC Focus Queue/credentials.json"


def slack_token(config: dict[str, Any]) -> str:
    path = credential_path(config)
    try:
        credentials = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return ""
    return str(credentials.get("slackToken") or "").strip() if isinstance(credentials, dict) else ""


def timestamp_iso(ts: str) -> str:
    try:
        seconds = float(ts)
    except (TypeError, ValueError):
        return ""
    return dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")


def permalink(workspace_url: str, channel_id: str, ts: str, thread_ts: str | None = None) -> str:
    if not workspace_url:
        return ""
    link = f"{workspace_url.rstrip('/')}/archives/{channel_id}/p{ts.replace('.', '')}"
    if thread_ts and thread_ts != ts:
        link += f"?thread_ts={thread_ts}&cid={channel_id}"
    return link


def paged(
    request: Requester,
    method: str,
    parameters: dict[str, str],
    key: str,
    *,
    maximum: int,
) -> tuple[list[dict[str, Any]], bool]:
    items: list[dict[str, Any]] = []
    cursor = ""
    while True:
        payload = checked(request(method, cursor, parameters), method)
        items.extend(item for item in payload.get(key) or [] if isinstance(item, dict))
        cursor = str((payload.get("response_metadata") or {}).get("next_cursor") or "")
        if len(items) >= maximum:
            return items[:maximum], True
        if not cursor:
            return items, False


def collect(
    config: dict[str, Any],
    cutoff: dt.datetime,
    *,
    request: Requester | None = None,
) -> dict[str, Any]:
    token = slack_token(config)
    if request is None:
        if not token:
            return {
                "status": "unavailable",
                "error": "Slack is not configured: add slackToken to the Focus Queue credentials file.",
                "messages": [],
            }

        def request(method: str, cursor: str, parameters: dict[str, str]) -> dict[str, Any]:
            return slack_get(token, method, {**parameters, "cursor": cursor})

    identity = checked(request("auth.test", "", {}), "auth.test")
    team_id = str(identity.get("team_id") or "workspace")
    workspace_url = str(identity.get("url") or "")
    self_user = str(identity.get("user_id") or "")
    page_size = str(min(max(int(config.get("maxSlackMessagesPerChannel", 200)), 1), 200))
    oldest = f"{cutoff.timestamp():.6f}"
    allowed = {
        str(value).strip().lstrip("#").casefold()
        for value in config.get("slackChannels") or []
        if str(value).strip()
    }

    conversations, truncated = paged(
        request,
        "users.conversations",
        {"types": CONVERSATION_TYPES, "exclude_archived": "true", "limit": "200"},
        "channels",
        maximum=MAX_CONVERSATIONS,
    )
    user_names: dict[str, str] = {}

    def user_name(user_id: str) -> str:
        if not user_id:
            return "unknown"
        if user_id not in user_names:
            name = user_id
            if len(user_names) < MAX_USER_LOOKUPS:
                try:
                    profile = checked(request("users.info", "", {"user": user_id}), "users.info")
                    user = profile.get("user") or {}
                    details = user.get("profile") or {}
                    name = (
                        str(details.get("display_name") or "").strip()
                        or str(details.get("real_name") or "").strip()
                        or str(user.get("name") or "").strip()
                        or user_id
                    )
                except SlackAccessError:
                    name = user_id
            user_names[user_id] = name
        return user_names[user_id]

    messages: list[dict[str, Any]] = []
    hidden: list[str] = []
    inaccessible: list[str] = []
    scanned = 0

    def conversation_label(conversation: dict[str, Any]) -> str:
        if conversation.get("is_im"):
            return f"DM with {user_name(str(conversation.get('user') or ''))}"
        return str(conversation.get("name") or conversation.get("id") or "conversation")

    def append(conversation_id: str, label: str, item: dict[str, Any]) -> None:
        if item.get("subtype") in SKIPPED_SUBTYPES or item.get("bot_id"):
            return
        text = str(item.get("text") or "").strip()
        files = [
            {"filename": str(entry.get("name") or "file"), "url": str(entry.get("permalink") or "")}
            for entry in item.get("files") or []
            if isinstance(entry, dict)
        ]
        ts = str(item.get("ts") or "")
        if not ts or (not text and not files):
            return
        author = str(item.get("user") or "")
        messages.append(
            {
                "sourceKey": f"slack:{team_id}:{conversation_id}:{ts}",
                "channel": label,
                "author": "you" if author and author == self_user else user_name(author),
                "timestamp": timestamp_iso(ts),
                "text": text[:1600],
                "attachments": files,
                "threadTs": str(item.get("thread_ts") or "") or None,
                "url": permalink(workspace_url, conversation_id, ts, str(item.get("thread_ts") or "") or None),
            }
        )

    for conversation in conversations:
        conversation_id = str(conversation.get("id") or "")
        if not conversation_id:
            continue
        label = conversation_label(conversation)
        if allowed and label.casefold() not in allowed and conversation_id.casefold() not in allowed:
            continue
        if len(messages) >= MAX_MESSAGES_PER_SOURCE:
            truncated = True
            break
        scanned += 1
        try:
            history, history_truncated = paged(
                request,
                "conversations.history",
                {"channel": conversation_id, "oldest": oldest, "limit": page_size},
                "messages",
                maximum=MAX_MESSAGES_PER_SOURCE - len(messages),
            )
        except SlackAccessError as error:
            code = error.code.removeprefix("slack_")
            if code in HIDDEN_CONVERSATION_ERRORS:
                hidden.append(label)
                continue
            if error.code in {"slack_auth_failed", "slack_missing_scope"}:
                raise
            inaccessible.append(label)
            continue
        truncated = truncated or history_truncated
        threads = 0
        for item in history:
            append(conversation_id, label, item)
            # Replies live outside channel history. Read threads whose parent
            # is inside the window and that received a reply inside it.
            thread_ts = str(item.get("thread_ts") or "")
            if (
                thread_ts
                and thread_ts == str(item.get("ts") or "")
                and int(item.get("reply_count") or 0) > 0
                and str(item.get("latest_reply") or "0") >= oldest
            ):
                if threads >= MAX_THREADS_PER_CONVERSATION:
                    truncated = True
                    continue
                threads += 1
                try:
                    replies, replies_truncated = paged(
                        request,
                        "conversations.replies",
                        {"channel": conversation_id, "ts": thread_ts, "oldest": oldest, "limit": page_size},
                        "messages",
                        maximum=MAX_MESSAGES_PER_SOURCE - len(messages),
                    )
                except SlackAccessError:
                    inaccessible.append(f"{label} thread")
                    continue
                truncated = truncated or replies_truncated
                for reply in replies:
                    if str(reply.get("ts") or "") != thread_ts:
                        append(conversation_id, label, reply)
    unique: dict[str, dict[str, Any]] = {}
    for message in messages:
        unique.setdefault(message["sourceKey"], message)
    ordered = sorted(unique.values(), key=lambda item: item.get("timestamp", ""), reverse=True)
    return {
        "status": "partial" if inaccessible else "ok",
        "workspace": workspace_url,
        "channelsScanned": scanned,
        "hiddenChannels": hidden,
        "inaccessibleChannels": inaccessible,
        "truncated": truncated,
        "messages": ordered,
    }
