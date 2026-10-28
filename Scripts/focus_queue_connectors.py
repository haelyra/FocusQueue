#!/usr/bin/env python3
"""Offline connector readiness. Never invokes helpers, signs in, or reads inboxes.

Each check mirrors what the matching connector requires before it touches the
network, so "configured" here means the connector will at least attempt a read.
Defaults resolve beside the --config file, as the connectors do, so a support
folder override never inspects the real home's credentials.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import stat
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = Path.home() / "Library/Application Support/ECC Focus Queue/ingestion.json"
SCRIPT_DIRECTORY = Path(__file__).resolve().parent
# Mirrors focus_queue_morning.GITHUB_CLI_CANDIDATES; kept local so this checker
# stays importable on its own.
GITHUB_CLI_CANDIDATES = ("/opt/homebrew/bin/gh", "/usr/local/bin/gh")


def configured_file(value: Any, *, executable: bool = False) -> bool:
    if not isinstance(value, str) or not value.strip():
        return False
    path = Path(value).expanduser()
    return path.is_absolute() and path.is_file() and (not executable or os.access(path, os.X_OK))


def read_json_object(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("rb") as handle:
            content = handle.read(1_048_577)
        if len(content) > 1_048_576:
            return None
        value = json.loads(content)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def oauth_client_problem(value: Any) -> str | None:
    """The same gates as focus_queue_gmail.oauth_client, without echoing contents."""
    if not isinstance(value, str) or not value.strip():
        return "missing"
    path = Path(value).expanduser()
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        return "invalid_path"
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        return "insecure"
    payload = read_json_object(path)
    client = payload.get("installed") if payload else None
    if not isinstance(client, dict) or not str(client.get("client_id") or "").strip():
        return "wrong_type"
    return None


def authorized_accounts(path: Path) -> set[str]:
    state = read_json_object(path) or {}
    values = state.get("accounts")
    if not isinstance(values, list):
        values = [state.get("account")]
    return {value.strip().casefold() for value in values if isinstance(value, str) and value.strip()}


def github_cli(config: dict[str, Any]) -> str | None:
    configured = str(config.get("githubExecutable") or "").strip()
    candidates = [configured] if configured else [*GITHUB_CLI_CANDIDATES, shutil.which("gh") or ""]
    for candidate in candidates:
        if candidate and configured_file(candidate, executable=True):
            return candidate
    return None


def command(*arguments: str | Path) -> str:
    return " ".join(shlex.quote(str(argument)) for argument in arguments)


def gmail_check(
    config: dict[str, Any],
    *,
    address_key: str,
    client_problem: str | None,
    state_path: Path,
    authorize_command: str,
) -> tuple[str, str]:
    """Return (status, nextStep) for one Gmail account."""
    address = str(config.get(address_key) or "").strip().casefold()
    if not address or "@" not in address:
        return "setup_required", (
            f"Set {address_key} and gmailOAuthClientPath in ingestion.json, then run {authorize_command}."
        )
    client_step = {
        "missing": "Set gmailOAuthClientPath in ingestion.json to the absolute path of a downloaded Google OAuth client file.",
        "invalid_path": "gmailOAuthClientPath must be the absolute path of a regular file, not a symlink or folder.",
        "insecure": "The Gmail OAuth client file is readable by other users; run chmod 600 on it.",
        "wrong_type": (
            "The Gmail OAuth client file must be a Desktop app client (JSON with an \"installed\" "
            "client_id). Create one in Google Cloud Console and download it."
        ),
    }
    if client_problem:
        return "setup_required", client_step[client_problem]
    if address not in authorized_accounts(state_path):
        return "setup_required", f"Authorize read-only Gmail access: run {authorize_command}."
    return "configured_unverified", "Authorized earlier. Live Gmail access is verified when a report runs."


def diagnose(config: dict[str, Any], config_path: Path) -> dict[str, Any]:
    """Return safe metadata only. File contents and account identifiers stay local."""
    config_path = config_path.expanduser()
    support = config_path.parent
    python = "/usr/bin/python3"

    archive = config.get("telegramArchiveExecutable") or config.get("profileExecutable")
    telegram_available = configured_file(archive, executable=True)
    archive_database = configured_file(config.get("telegramArchiveDatabasePath"))
    if telegram_available:
        telegram_step = (
            "Agent archive only: personal Telegram chats are not read. "
            + (
                "Active sessions are included."
                if archive_database
                else "Set telegramArchiveDatabasePath to include sessions that are still running."
            )
        )
    elif archive:
        telegram_step = "telegramArchiveExecutable must be the absolute path of an executable Hermes CLI."
    else:
        telegram_step = (
            "Set telegramArchiveExecutable in ingestion.json to the Hermes CLI that exports "
            "Telegram agent sessions. Personal Telegram chats are not supported."
        )

    discord_credentials_path = Path(
        config.get("discordCredentialPath") or support / "credentials.json"
    ).expanduser()
    discord_credentials = read_json_object(discord_credentials_path) or {}
    discord_token = bool(str(discord_credentials.get("discordBotToken") or "").strip())
    if not config.get("discordGuildId"):
        discord_status, discord_step = "setup_required", (
            "Set discordGuildId in ingestion.json to the server ID, and add discordBotToken to credentials.json."
        )
    elif not discord_token:
        discord_status, discord_step = "setup_required", (
            f"Add discordBotToken to {discord_credentials_path.name} (mode 600) for a bot invited "
            "to the server with Read Message History."
        )
    else:
        discord_status, discord_step = "configured_unverified", (
            f"Verify bot access to the server and channels with: {command('focus-discord', '--config', config_path, 'status')}"
        )

    gmail_script = SCRIPT_DIRECTORY / "focus_queue_gmail.py"
    gmail_state = Path(config.get("gmailAuthStatePath") or support / "gmail-auth.json").expanduser()
    client_problem = oauth_client_problem(config.get("gmailOAuthClientPath"))
    email_provider = str(config.get("emailProvider", "apple_mail")).strip().casefold()
    if email_provider == "gmail":
        email_coverage = "configured_gmail_api_account"
        email_status, email_step = gmail_check(
            config,
            address_key="emailAddress",
            client_problem=client_problem,
            state_path=gmail_state,
            authorize_command=command("focus-mail", "--config", config_path, "authorize", "--open-browser"),
        )
    elif email_provider == "apple_mail":
        email_coverage = "configured_apple_mail_account_and_mailboxes"
        if config.get("emailAddress"):
            email_status, email_step = "configured_unverified", (
                "Verify the Mail reader can read this account with: "
                f"{command('focus-mail', '--config', config_path, 'status')} "
                "(needs Mail automation permission)."
            )
        else:
            email_status, email_step = "setup_required", (
                "Set emailAddress in ingestion.json to an account synchronized in Apple Mail, "
                "and optionally emailMailboxes (default INBOX)."
            )
    else:
        email_coverage = "unconfigured"
        email_status, email_step = "setup_required", "Set emailProvider in ingestion.json to apple_mail or gmail."

    gmail_status, gmail_step = gmail_check(
        config,
        address_key="gmailAddress",
        client_problem=client_problem,
        state_path=gmail_state,
        authorize_command=command(python, gmail_script, "--config", config_path, "--report-account", "authorize", "--open-browser"),
    )

    slack_path = Path(
        config.get("slackCredentialPath")
        or config.get("discordCredentialPath")
        or support / "credentials.json"
    ).expanduser()
    slack_credentials = read_json_object(slack_path) or {}
    slack_available = bool(str(slack_credentials.get("slackToken") or "").strip())
    slack_step = (
        "Token found. Scopes and channel membership are verified when a report runs."
        if slack_available
        else (
            "Create a Slack app with channels:history, groups:history, im:history, mpim:history, "
            "and the matching :read scopes plus users:read, install it, and add its token as "
            f"slackToken in {slack_path.name} (mode 600)."
        )
    )

    repositories = config.get("githubRepositories")
    repositories_valid = (
        isinstance(repositories, list)
        and bool(repositories)
        and all(
            isinstance(value, str) and value.count("/") == 1 and all(value.split("/"))
            for value in repositories
        )
    )
    gh = github_cli(config)
    if not repositories_valid:
        github_status, github_step = "setup_required", (
            "Set githubRepositories in ingestion.json to a list of owner/name repositories."
        )
    elif not gh:
        github_status, github_step = "setup_required", (
            "Install the GitHub CLI (brew install gh) and run gh auth login, or set githubExecutable "
            "in ingestion.json to its absolute path."
        )
    else:
        github_status, github_step = "configured_unverified", (
            f"Verify the signed-in account can read the repositories with: {command(gh, 'auth', 'status')}"
        )

    connectors = [
        {
            "id": "telegram",
            "status": "limited" if telegram_available else "setup_required",
            "coverage": "agent_session_archive" if telegram_available else "unconfigured",
            "personalInboxSupported": False,
            "activeArchiveConfigured": archive_database,
            "accountSwitchSupported": False,
            "nextStep": telegram_step,
        },
        {
            "id": "discord",
            "status": discord_status,
            "coverage": "configured_guild_bot_visibility" if discord_status != "setup_required" else "unconfigured",
            "accountSwitchSupported": False,
            "nextStep": discord_step,
        },
        {
            "id": "email",
            "status": email_status,
            "coverage": email_coverage,
            "accountSwitchSupported": False,
            "nextStep": email_step,
        },
        {
            "id": "gmail",
            "status": gmail_status,
            "coverage": "configured_gmail_inbox" if gmail_status != "setup_required" else "unconfigured",
            "accountSwitchSupported": False,
            "nextStep": gmail_step,
        },
        {
            "id": "slack",
            "status": "configured_unverified" if slack_available else "setup_required",
            "coverage": "token_member_conversations" if slack_available else "unconfigured",
            "accountSwitchSupported": False,
            "nextStep": slack_step,
        },
        {
            "id": "github",
            "status": github_status,
            "coverage": "configured_repositories" if github_status != "setup_required" else "unconfigured",
            "accountSwitchSupported": False,
            "nextStep": github_step,
        },
    ]
    return {
        "version": 1,
        "mode": "offline",
        "authenticationVerified": False,
        "configurationPresent": True,
        "connectors": connectors,
    }


def diagnose_missing_configuration(config_path: Path) -> dict[str, Any]:
    """A new install has no ingestion.json yet; every source needs setup."""
    result = diagnose({}, config_path)
    result["configurationPresent"] = False
    for item in result["connectors"]:
        item["nextStep"] = (
            f"Create {config_path.name} in {config_path.parent} (a JSON object). "
            + item["nextStep"]
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    arguments = parser.parse_args()
    config_path = arguments.config.expanduser()
    if not config_path.exists() and not config_path.is_symlink():
        print(json.dumps(diagnose_missing_configuration(config_path), indent=2))
        return 0
    try:
        # Bound input size, and report generic errors to avoid echoing credentials
        # embedded in malformed JSON, paths, or parser exceptions.
        with config_path.open("rb") as handle:
            content = handle.read(1_048_577)
        if len(content) > 1_048_576:
            raise ValueError("oversized config")
        config = json.loads(content)
        if not isinstance(config, dict):
            raise ValueError("invalid config type")
    except (OSError, ValueError):
        print(json.dumps({"version": 1, "mode": "offline", "errorCode": "invalid_connector_config"}))
        return 1
    print(json.dumps(diagnose(config, config_path), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
