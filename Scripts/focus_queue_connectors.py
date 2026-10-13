#!/usr/bin/env python3
"""Offline connector readiness. Never invokes helpers, signs in, or reads inboxes."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = Path.home() / "Library/Application Support/ECC Focus Queue/ingestion.json"


def configured_file(value: Any, *, executable: bool = False) -> bool:
    if not isinstance(value, str) or not value.strip():
        return False
    path = Path(value).expanduser()
    return path.is_absolute() and path.is_file() and (not executable or os.access(path, os.X_OK))


def diagnose(config: dict[str, Any]) -> dict[str, Any]:
    """Return safe metadata only. File contents and account identifiers stay local."""
    archive = config.get("telegramArchiveExecutable") or config.get("profileExecutable")
    telegram_available = configured_file(archive, executable=True)
    discord_available = bool(config.get("discordGuildId")) and configured_file(
        config.get("discordCredentialPath")
        or str(DEFAULT_CONFIG.parent / "credentials.json")
    )
    email_provider = str(config.get("emailProvider", "apple_mail")).strip().casefold()
    if email_provider == "gmail":
        email_available = bool(config.get("emailAddress")) and configured_file(
            config.get("gmailOAuthClientPath")
        )
        email_coverage = "configured_gmail_api_account"
        email_next_step = (
            "Run focus-mail authorize, then verify read-only Gmail API access with focus-mail status."
        )
    else:
        email_available = bool(config.get("emailAddress"))
        email_coverage = "configured_apple_mail_account_and_mailboxes"
        email_next_step = (
            "Choose a synchronized Mail account and mailbox scope, then verify reader permissions."
        )
    gmail_available = bool(config.get("gmailAddress")) and configured_file(
        config.get("gmailOAuthClientPath")
    )
    credential_path = Path(
        config.get("slackCredentialPath")
        or config.get("discordCredentialPath")
        or str(DEFAULT_CONFIG.parent / "credentials.json")
    ).expanduser()
    try:
        credentials = json.loads(credential_path.read_text(encoding="utf-8"))
        slack_available = isinstance(credentials, dict) and bool(credentials.get("slackToken"))
    except (OSError, ValueError):
        slack_available = False
    repositories = config.get("githubRepositories")
    github_available = (
        isinstance(repositories, list)
        and bool(repositories)
        and all(isinstance(value, str) and value.count("/") == 1 for value in repositories)
    )
    return {
        "version": 1,
        "mode": "offline",
        "authenticationVerified": False,
        "connectors": [
            {
                "id": "telegram",
                "status": "limited" if telegram_available else "setup_required",
                "coverage": "agent_session_archive" if telegram_available else "unconfigured",
                "personalInboxSupported": False,
                "activeArchiveConfigured": configured_file(config.get("telegramArchiveDatabasePath")),
                "accountSwitchSupported": False,
                "nextStep": (
                    "Install and authorize a Telegram user-account reader for personal chats. "
                    "The agent archive cannot read your inbox. Active archive coverage requires a verified database path."
                ),
            },
            {
                "id": "discord",
                "status": "configured_unverified" if discord_available else "setup_required",
                "coverage": "configured_guild_bot_visibility",
                "accountSwitchSupported": False,
                "nextStep": "Verify bot access to the selected server and channels in a read-only connection test.",
            },
            {
                "id": "email",
                "status": "configured_unverified" if email_available else "setup_required",
                "coverage": email_coverage,
                "accountSwitchSupported": False,
                "nextStep": email_next_step,
            },
            {
                "id": "gmail",
                "status": "configured_unverified" if gmail_available else "setup_required",
                "coverage": "configured_gmail_inbox" if gmail_available else "unconfigured",
                "accountSwitchSupported": False,
                "nextStep": (
                    "Set gmailAddress and gmailOAuthClientPath in ingestion settings, run "
                    "focus_queue_gmail.py --report-account authorize --open-browser, then enable Gmail."
                ),
            },
            {
                "id": "slack",
                "status": "configured_unverified" if slack_available else "setup_required",
                "coverage": "token_member_conversations" if slack_available else "unconfigured",
                "accountSwitchSupported": False,
                "nextStep": (
                    "Install a Slack app with read-only history and read scopes, add its token as "
                    "slackToken in the credentials file, then enable Slack."
                ),
            },
            {
                "id": "github",
                "status": "configured_unverified" if github_available else "setup_required",
                "coverage": "configured_repositories",
                "accountSwitchSupported": False,
                "nextStep": "Verify the GitHub CLI account and repository access before collecting.",
            },
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    arguments = parser.parse_args()
    try:
        # Bound input size, and report generic errors to avoid echoing credentials
        # embedded in malformed JSON, paths, or parser exceptions.
        with arguments.config.expanduser().open("rb") as handle:
            content = handle.read(1_048_577)
        if len(content) > 1_048_576:
            raise ValueError("oversized config")
        config = json.loads(content)
        if not isinstance(config, dict):
            raise ValueError("invalid config type")
    except (OSError, ValueError):
        print(json.dumps({"version": 1, "mode": "offline", "errorCode": "invalid_connector_config"}))
        return 1
    print(json.dumps(diagnose(config), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
