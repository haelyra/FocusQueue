#!/usr/bin/env python3
"""Verified read-only Discord access for the Focus Queue Codex agent."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import uuid
from pathlib import Path
from typing import Any

import focus_queue_morning as morning


SUPPORT_DIRECTORY = Path.home() / "Library/Application Support/ECC Focus Queue"
DEFAULT_CONFIG = SUPPORT_DIRECTORY / "ingestion.json"
DEFAULT_RUNTIME = SUPPORT_DIRECTORY / "ingestion"
DEFAULT_CREDENTIALS = SUPPORT_DIRECTORY / "credentials.json"
LEGACY_CREDENTIALS = Path.home() / ".hermes/.env"
CONNECTOR = "ecc-focus-discord-reader"
MAX_RESULT_TEXT = 700
MAX_MESSAGE_TEXT = 10_000


class DiscordAccessError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def credential_path(config: dict[str, Any]) -> Path:
    configured = config.get("discordCredentialPath")
    if configured:
        return Path(configured).expanduser()
    if config.get("_configPath"):
        return Path(config["_configPath"]).expanduser().parent / "credentials.json"
    return DEFAULT_CREDENTIALS


def token_from_private_store(config: dict[str, Any]) -> str:
    path = credential_path(config)
    if path.exists():
        payload = morning.load_json(path)
        token = str(payload.get("discordBotToken", ""))
        if token:
            return token
    raise DiscordAccessError(
        f"Discord credential is not installed in the ECC private store at {path}"
    )


def migrate_credentials(config: dict[str, Any]) -> dict[str, Any]:
    destination = credential_path(config)
    if destination.exists() and token_from_private_store(config):
        return {"status": "ok", "migrated": False, "credentialPath": str(destination)}
    token = morning.read_dotenv(LEGACY_CREDENTIALS).get("DISCORD_BOT_TOKEN", "")
    if not token:
        raise DiscordAccessError("No existing Discord bot credential was found to migrate")
    morning.write_private_json(destination, {"version": 1, "discordBotToken": token})
    return {"status": "ok", "migrated": True, "credentialPath": str(destination)}


def channel_catalog(token: str, guild_id: str) -> list[dict[str, str]]:
    channels = morning.discord_get(token, f"/guilds/{guild_id}/channels")
    catalog = [
        {"id": str(item["id"]), "name": str(item.get("name", "unknown")), "kind": "channel"}
        for item in channels
        if item.get("type") in {0, 5}
    ]
    try:
        threads = morning.discord_get(token, f"/guilds/{guild_id}/threads/active").get("threads", [])
        catalog.extend(
            {"id": str(item["id"]), "name": str(item.get("name", "thread")), "kind": "thread"}
            for item in threads
        )
    except urllib.error.HTTPError:
        pass
    seen: set[str] = set()
    return [item for item in catalog if not (item["id"] in seen or seen.add(item["id"]))]


def discord_message(item: dict[str, Any], guild_id: str, channel: dict[str, str], *, full: bool) -> dict[str, Any]:
    author = item.get("author") or {}
    text = str(item.get("content") or "").strip()
    limit = MAX_MESSAGE_TEXT if full else MAX_RESULT_TEXT
    return {
        "id": str(item.get("id", "")),
        "channelId": channel["id"],
        "channel": channel["name"],
        "author": author.get("global_name") or author.get("username") or "unknown",
        "authorId": str(author.get("id", "")),
        "timestamp": str(item.get("timestamp", "")),
        "text" if full else "snippet": text[:limit],
        "truncated": len(text) > limit,
        "attachments": [
            {
                "filename": str(attachment.get("filename", "attachment"))[:300],
                "url": str(attachment.get("url", "")),
                "contentType": str(attachment.get("content_type", "")),
            }
            for attachment in item.get("attachments", [])
        ],
        "url": f"https://discord.com/channels/{guild_id}/{channel['id']}/{item.get('id', '')}",
    }


def probe_channels(token: str, channels: list[dict[str, str]]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    readable = []
    inaccessible = []
    for channel in channels:
        try:
            morning.discord_get(token, f"/channels/{channel['id']}/messages", {"limit": "1"})
            readable.append(channel)
        except urllib.error.HTTPError as error:
            inaccessible.append({**channel, "error": f"HTTP {error.code}"})
    return readable, inaccessible


def status(config: dict[str, Any], token: str) -> dict[str, Any]:
    guild_id = str(config["discordGuildId"])
    bot = morning.discord_get(token, "/users/@me")
    guild = morning.discord_get(token, f"/guilds/{guild_id}")
    channels = channel_catalog(token, guild_id)
    readable, inaccessible = probe_channels(token, channels)
    return {
        "status": "partial" if inaccessible else "ok",
        "verified": True,
        "operation": "status",
        "connector": CONNECTOR,
        "retrievedAt": utc_now(),
        "guild": {"id": guild_id, "name": str(guild.get("name", "unknown"))},
        "bot": {"id": str(bot.get("id", "")), "username": str(bot.get("username", "unknown"))},
        "visibleChannelCount": len(channels),
        "readableChannelCount": len(readable),
        "inaccessibleChannels": inaccessible,
        "capabilities": ["status", "channels", "search", "read"],
        "writesEnabled": False,
    }


def channels(config: dict[str, Any], token: str) -> dict[str, Any]:
    guild_id = str(config["discordGuildId"])
    catalog = channel_catalog(token, guild_id)
    readable, inaccessible = probe_channels(token, catalog)
    return {
        "status": "partial" if inaccessible else "ok",
        "verified": True,
        "operation": "channels",
        "connector": CONNECTOR,
        "retrievedAt": utc_now(),
        "guild": {"id": guild_id},
        "channels": readable,
        "inaccessibleChannels": inaccessible,
    }


def search(config: dict[str, Any], token: str, query: str, days: int, limit: int) -> dict[str, Any]:
    guild_id = str(config["discordGuildId"])
    catalog = channel_catalog(token, guild_id)
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=min(max(days, 1), 365))
    after = morning.discord_after_snowflake(cutoff)
    terms = [term for term in re.split(r"\s+", query.casefold()) if term]
    results: list[dict[str, Any]] = []
    inaccessible: list[dict[str, str]] = []
    per_channel = min(max(int(config.get("maxDiscordMessagesPerChannel", 100)), 1), 100)
    for channel in catalog:
        try:
            history = morning.discord_get(
                token,
                f"/channels/{channel['id']}/messages",
                {"limit": str(per_channel), "after": after},
            )
        except urllib.error.HTTPError as error:
            inaccessible.append({**channel, "error": f"HTTP {error.code}"})
            continue
        for item in history:
            author = item.get("author") or {}
            if author.get("bot"):
                continue
            attachment_names = " ".join(str(value.get("filename", "")) for value in item.get("attachments", []))
            haystack = "\n".join(
                [
                    channel["name"],
                    str(author.get("global_name") or author.get("username") or ""),
                    str(item.get("content") or ""),
                    attachment_names,
                ]
            ).casefold()
            if terms and not all(term in haystack for term in terms):
                continue
            results.append(discord_message(item, guild_id, channel, full=False))
    results.sort(key=lambda item: item.get("timestamp", ""), reverse=True)
    bounded_limit = min(max(limit, 1), 50)
    return {
        "status": "partial" if inaccessible else "ok",
        "verified": True,
        "operation": "search",
        "connector": CONNECTOR,
        "retrievedAt": utc_now(),
        "guild": {"id": guild_id},
        "query": query,
        "days": min(max(days, 1), 365),
        "resultCount": min(len(results), bounded_limit),
        "results": results[:bounded_limit],
        "truncated": len(results) > bounded_limit,
        "inaccessibleChannels": inaccessible,
    }


def read(config: dict[str, Any], token: str, identifier: str, channel_id: str | None) -> dict[str, Any]:
    guild_id = str(config["discordGuildId"])
    match = re.search(r"discord(?:app)?\.com/channels/(\d+)/(\d+)/(\d+)", identifier)
    if match:
        requested_guild, channel_id, message_id = match.groups()
        if requested_guild != guild_id:
            raise DiscordAccessError("The Discord link belongs to a different server")
    else:
        message_id = identifier.strip()
    if not channel_id or not message_id.isdigit():
        raise DiscordAccessError("Use a Discord message link, or provide a numeric message ID with --channel-id")
    catalog = channel_catalog(token, guild_id)
    channel = next((item for item in catalog if item["id"] == channel_id), None)
    if channel is None:
        channel = {"id": channel_id, "name": "unknown", "kind": "unknown"}
    item = morning.discord_get(token, f"/channels/{channel_id}/messages/{message_id}")
    return {
        "status": "ok",
        "verified": True,
        "operation": "read",
        "connector": CONNECTOR,
        "retrievedAt": utc_now(),
        "guild": {"id": guild_id},
        "message": discord_message(item, guild_id, channel, full=True),
    }


def emit(config: dict[str, Any], payload: dict[str, Any]) -> int:
    payload["nonce"] = str(uuid.uuid4())
    runtime = Path(
        os.environ.get("FOCUS_QUEUE_CONNECTOR_PROOF_DIR")
        or config.get("discordRuntimeDirectory", DEFAULT_RUNTIME)
    ).expanduser()
    morning.write_private_json(runtime / "discord-response.json", payload)
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if payload.get("status") in {"ok", "partial"} else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    subparsers.add_parser("channels")
    search_parser = subparsers.add_parser("search")
    search_parser.add_argument("query")
    search_parser.add_argument("--days", type=int, default=7)
    search_parser.add_argument("--limit", type=int, default=20)
    read_parser = subparsers.add_parser("read")
    read_parser.add_argument("identifier")
    read_parser.add_argument("--channel-id")
    subparsers.add_parser("migrate-credentials", help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    try:
        config = morning.load_config(arguments.config, connector="discord")
        if arguments.command == "migrate-credentials":
            print(json.dumps(migrate_credentials(config), indent=2))
            return 0
        token = token_from_private_store(config)
        if arguments.command == "status":
            payload = status(config, token)
        elif arguments.command == "channels":
            payload = channels(config, token)
        elif arguments.command == "search":
            payload = search(config, token, arguments.query, arguments.days, arguments.limit)
        else:
            payload = read(config, token, arguments.identifier, arguments.channel_id)
        return emit(config, payload)
    except Exception as error:
        try:
            config = morning.load_config(arguments.config, connector="discord")
            return emit(
                config,
                {
                    "status": "error",
                    "verified": False,
                    "operation": arguments.command,
                    "connector": CONNECTOR,
                    "retrievedAt": utc_now(),
                    "error": str(error)[:800],
                },
            )
        except Exception:
            print(f"Discord connector failed: {error}", file=sys.stderr)
            return 2


if __name__ == "__main__":
    raise SystemExit(main())
