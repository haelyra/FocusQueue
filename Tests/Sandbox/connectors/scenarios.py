#!/usr/bin/env python3
"""Connector setup and diagnostics scenarios for a clean Linux home.

Runs inside the ECC Tier 1 Podman sandbox (see README.md). Every scenario
builds a fresh Focus Queue support folder from fake fixtures, runs the real
connector scripts as subprocesses, and checks the result a new user would see.
Network is off, so nothing here can reach Telegram, Discord, Slack, Gmail, or
GitHub. Apple Mail needs macOS automation and is reported as not exercised.

Exit status is 0 only when every scenario passes. Results are printed as one
JSON document on stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

PLATFORMS = {"discord", "telegram", "email", "github", "gmail", "slack"}
# Fixture secrets. Any of these appearing in diagnostic output is a leak.
FIXTURE_SECRETS = (
    "xoxb-fixture-secret",
    "discord-fixture-secret",
    "fixture-client-secret",
    "reader@fixture.test",
    "report@fixture.test",
)
VALID_OAUTH_CLIENT = {
    "installed": {
        "client_id": "fixture-client.apps.googleusercontent.com",
        "client_secret": "fixture-client-secret",
    }
}


class Context:
    def __init__(self, scripts: Path, home: Path) -> None:
        self.scripts = scripts
        self.home = home
        self.support = home / "Library/Application Support/ECC Focus Queue"
        self.config = self.support / "ingestion.json"

    def reset(self) -> None:
        if self.support.exists():
            shutil.rmtree(self.support)
        self.support.mkdir(parents=True, mode=0o700)
        for name in ("bin", "alt"):
            shutil.rmtree(self.home / name, ignore_errors=True)

    def write_json(self, path: Path, payload: Any, mode: int = 0o600) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")
        path.chmod(mode)
        return path

    def ingestion(self, payload: dict[str, Any]) -> Path:
        return self.write_json(self.config, payload)

    def credentials(self, payload: dict[str, Any], directory: Path | None = None) -> Path:
        return self.write_json((directory or self.support) / "credentials.json", payload)

    def app_config(self, platforms: list[str]) -> Path:
        return self.write_json(
            self.support / "config.json",
            {"dailyReport": {"enabledPlatforms": platforms}},
        )

    def dashboard(self) -> dict[str, str]:
        directory = self.home / "dashboard"
        directory.mkdir(exist_ok=True)
        dashboard = self.write_json(directory / "dashboard.json", {"tickets": []})
        agent = self.home / "bin/agent"
        agent.parent.mkdir(exist_ok=True)
        agent.write_text("#!/bin/sh\nexit 1\n")
        agent.chmod(0o700)
        return {
            "dashboardPath": str(dashboard),
            "dashboardDirectory": str(directory),
            "agentExecutable": str(agent),
        }

    def run(self, script: str, *arguments: str, timeout: int = 60) -> dict[str, Any]:
        environment = {
            "HOME": str(self.home),
            "PATH": f"{self.home / 'bin'}:/usr/local/bin:/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            # Belt and braces for --home runs on a host with a network: route
            # urllib through a closed local port so no fixture token leaves.
            "http_proxy": "http://127.0.0.1:9",
            "https_proxy": "http://127.0.0.1:9",
            "HTTP_PROXY": "http://127.0.0.1:9",
            "HTTPS_PROXY": "http://127.0.0.1:9",
        }
        completed = subprocess.run(
            [sys.executable, str(self.scripts / script), *arguments],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=environment,
            cwd=self.home,
            stdin=subprocess.DEVNULL,
        )
        return {
            "command": " ".join([Path(script).name, *arguments]).replace(str(self.home), "$HOME"),
            "returncode": completed.returncode,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
        }

    def diagnose(self, config: Path | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
        result = self.run("focus_queue_connectors.py", "--config", str(config or self.config))
        try:
            payload = json.loads(result["stdout"])
        except ValueError:
            payload = {}
        return result, payload


def connector(payload: dict[str, Any], identifier: str) -> dict[str, Any]:
    for item in payload.get("connectors", []):
        if item.get("id") == identifier:
            return item
    return {}


def last_json(text: str) -> dict[str, Any]:
    """Return the last top-level JSON object printed on stdout."""
    decoder = json.JSONDecoder()
    found: dict[str, Any] = {}
    index = 0
    while index < len(text):
        start = text.find("{", index)
        if start < 0:
            break
        try:
            value, end = decoder.raw_decode(text, start)
        except ValueError:
            index = start + 1
            continue
        if isinstance(value, dict):
            found = value
        index = end
    return found


class Scenario:
    def __init__(self, context: Context, name: str) -> None:
        self.context = context
        self.name = name
        self.checks: list[dict[str, Any]] = []
        self.commands: list[dict[str, Any]] = []

    def record(self, result: dict[str, Any]) -> dict[str, Any]:
        self.commands.append({
            "command": result["command"],
            "returncode": result["returncode"],
            "stdout_tail": result["stdout"][-1500:],
            "stderr_tail": result["stderr"][-800:],
        })
        output = result["stdout"] + result["stderr"]
        leaked = [secret for secret in FIXTURE_SECRETS if secret in output]
        self.expect("no fixture secret or account echoed", not leaked, leaked or None)
        return result

    def expect(self, description: str, condition: bool, observed: Any = None) -> None:
        entry: dict[str, Any] = {"check": description, "passed": bool(condition)}
        if not condition and observed is not None:
            entry["observed"] = observed
        self.checks.append(entry)

    @property
    def passed(self) -> bool:
        return all(check["passed"] for check in self.checks)


def scenario_clean_machine(s: Scenario) -> None:
    """A brand-new user has no ingestion.json yet."""
    c = s.context
    result, payload = c.diagnose()
    s.record(result)
    s.expect("diagnostics succeed without ingestion.json", result["returncode"] == 0, result["stdout"][-300:])
    s.expect("configuration reported missing", payload.get("configurationPresent") is False, payload.get("configurationPresent"))
    ids = {item.get("id") for item in payload.get("connectors", [])}
    s.expect("all six platforms reported", ids == PLATFORMS, sorted(ids))
    statuses = {item.get("id"): item.get("status") for item in payload.get("connectors", [])}
    s.expect("every platform needs setup", set(statuses.values()) == {"setup_required"}, statuses)
    steps = [item.get("nextStep", "") for item in payload.get("connectors", [])]
    s.expect("every next step names ingestion.json", steps and all("ingestion.json" in step for step in steps), steps)


def scenario_malformed_config(s: Scenario) -> None:
    c = s.context
    c.config.write_text('{"slackToken": "xoxb-fixture-secret"', encoding="utf-8")
    result, payload = c.diagnose()
    s.record(result)
    s.expect("malformed config exits 1", result["returncode"] == 1, result["returncode"])
    s.expect("structured error code", payload.get("errorCode") == "invalid_connector_config", payload)


def scenario_empty_config(s: Scenario) -> None:
    c = s.context
    c.ingestion({})
    result, payload = c.diagnose()
    s.record(result)
    s.expect("configuration reported present", payload.get("configurationPresent") is True, payload.get("configurationPresent"))
    statuses = {item.get("id"): item.get("status") for item in payload.get("connectors", [])}
    s.expect("every platform needs setup", set(statuses.values()) == {"setup_required"}, statuses)


def scenario_discord_token_missing(s: Scenario) -> None:
    """A credentials file that holds only a Slack token cannot serve Discord."""
    c = s.context
    c.ingestion({"discordGuildId": "123456789"})
    c.credentials({"slackToken": "xoxb-fixture-secret"})
    result, payload = c.diagnose()
    s.record(result)
    discord = connector(payload, "discord")
    s.expect("discord needs setup without discordBotToken", discord.get("status") == "setup_required", discord.get("status"))
    s.expect("next step names discordBotToken", "discordBotToken" in discord.get("nextStep", ""), discord.get("nextStep"))
    cli = s.record(c.run("focus_queue_discord.py", "--config", str(c.config), "status"))
    error = last_json(cli["stdout"]).get("error", cli["stderr"])
    s.expect("connector CLI agrees the bot token is missing", "credential is not installed" in error, error)


def scenario_discord_default_paths(s: Scenario) -> None:
    """focus-discord runs without --config; defaults must follow $HOME."""
    c = s.context
    c.ingestion({"discordGuildId": "123456789"})
    c.credentials({"discordBotToken": "discord-fixture-secret"})
    result, payload = c.diagnose()
    s.record(result)
    s.expect("diagnostics: discord configured", connector(payload, "discord").get("status") == "configured_unverified", connector(payload, "discord"))
    cli = s.record(c.run("focus_queue_discord.py", "status"))
    output = cli["stdout"] + cli["stderr"]
    s.expect("no hard-coded /Users/ path", "/Users/" not in output, output[-400:])
    s.expect("not blocked by unrelated settings", "Missing ingestion settings" not in output, output[-400:])
    s.expect("reaches the network step (offline failure)", last_json(cli["stdout"]).get("status") == "error", output[-400:])
    proofs = [str(path.relative_to(c.home)) for path in c.support.rglob("discord-response.json")]
    s.expect("proof written under the clean home", bool(proofs), proofs)


def scenario_support_dir_override(s: Scenario) -> None:
    """A support folder override keeps credentials next to its ingestion.json."""
    c = s.context
    alternate = c.home / "alt"
    config = c.write_json(alternate / "ingestion.json", {"discordGuildId": "1"})
    c.credentials({"discordBotToken": "discord-fixture-secret", "slackToken": "xoxb-fixture-secret"}, alternate)
    result, payload = c.diagnose(config)
    s.record(result)
    s.expect("discord finds sibling credentials", connector(payload, "discord").get("status") == "configured_unverified", connector(payload, "discord"))
    s.expect("slack finds sibling credentials", connector(payload, "slack").get("status") == "configured_unverified", connector(payload, "slack"))
    cli = s.record(c.run("focus_queue_discord.py", "--config", str(config), "status"))
    output = cli["stdout"] + cli["stderr"]
    s.expect("connector CLI reads the same sibling credentials", "credential is not installed" not in output, output[-400:])


def gmail_config(c: Context, client_mode: int, client: dict[str, Any] | None = None) -> Path:
    oauth = c.write_json(c.home / "bin/oauth-client.json", client or VALID_OAUTH_CLIENT, client_mode)
    c.ingestion({"gmailAddress": "report@fixture.test", "gmailOAuthClientPath": str(oauth)})
    return oauth


def gmail_authorize(c: Context) -> dict[str, Any]:
    return c.run("focus_queue_gmail.py", "--config", str(c.config), "--report-account", "authorize", "--timeout", "1")


def scenario_gmail_insecure_client(s: Scenario) -> None:
    c = s.context
    gmail_config(c, 0o644)
    result, payload = c.diagnose()
    s.record(result)
    gmail = connector(payload, "gmail")
    s.expect("readable-by-others client needs setup", gmail.get("status") == "setup_required", gmail.get("status"))
    s.expect("next step says chmod 600", "chmod 600" in gmail.get("nextStep", ""), gmail.get("nextStep"))
    cli = s.record(gmail_authorize(c))
    code = last_json(cli["stdout"]).get("errorCode")
    s.expect("connector CLI rejects it as insecure", code == "gmail_oauth_client_insecure", cli["stdout"][-400:])


def scenario_gmail_invalid_client(s: Scenario) -> None:
    c = s.context
    gmail_config(c, 0o600, {"web": {"client_id": "x"}})
    result, payload = c.diagnose()
    s.record(result)
    gmail = connector(payload, "gmail")
    s.expect("web-app client needs setup", gmail.get("status") == "setup_required", gmail.get("status"))
    s.expect("next step names a Desktop app client", "Desktop" in gmail.get("nextStep", ""), gmail.get("nextStep"))
    cli = s.record(gmail_authorize(c))
    code = last_json(cli["stdout"]).get("errorCode")
    s.expect("connector CLI rejects it as invalid", code == "gmail_oauth_client_invalid", cli["stdout"][-400:])


def scenario_gmail_not_authorized(s: Scenario) -> None:
    """A valid client alone is not enough: authorization has not run."""
    c = s.context
    gmail_config(c, 0o600)
    result, payload = c.diagnose()
    s.record(result)
    gmail = connector(payload, "gmail")
    s.expect("unauthorized Gmail needs setup", gmail.get("status") == "setup_required", gmail.get("status"))
    s.expect("next step gives the authorize command", "--report-account authorize" in gmail.get("nextStep", ""), gmail.get("nextStep"))
    cli = s.record(gmail_authorize(c))
    output = cli["stdout"] + cli["stderr"]
    s.expect("minimal Gmail config reaches OAuth", "authorization_required" in cli["stdout"], output[-400:])
    s.expect("authorize times out cleanly", last_json(cli["stdout"]).get("errorCode") == "gmail_authorization_timeout", output[-400:])


def scenario_gmail_authorized(s: Scenario) -> None:
    c = s.context
    gmail_config(c, 0o600)
    state = c.write_json(c.support / "gmail-auth.json", {"version": 1, "provider": "gmail", "account": "someone-else@fixture.test"})
    result, payload = c.diagnose()
    s.record(result)
    s.expect("authorization for another account needs setup", connector(payload, "gmail").get("status") == "setup_required", connector(payload, "gmail"))
    c.write_json(state, {"version": 1, "provider": "gmail", "account": "someone-else@fixture.test", "accounts": ["report@fixture.test", "someone-else@fixture.test"]})
    result, payload = c.diagnose()
    s.record(result)
    s.expect("authorized account is configured", connector(payload, "gmail").get("status") == "configured_unverified", connector(payload, "gmail"))


def scenario_email_gmail_provider(s: Scenario) -> None:
    c = s.context
    oauth = c.write_json(c.home / "bin/oauth-client.json", VALID_OAUTH_CLIENT, 0o644)
    c.ingestion({"emailProvider": "gmail", "emailAddress": "reader@fixture.test", "gmailOAuthClientPath": str(oauth)})
    result, payload = c.diagnose()
    s.record(result)
    s.expect("Mail via Gmail with insecure client needs setup", connector(payload, "email").get("status") == "setup_required", connector(payload, "email"))
    cli = s.record(c.run("focus_queue_mail.py", "--config", str(c.config), "authorize", "--timeout", "1"))
    output = cli["stdout"] + cli["stderr"]
    s.expect("focus-mail not blocked by unrelated settings", "Missing ingestion settings" not in output, output[-400:])
    s.expect("focus-mail rejects the insecure client", last_json(cli["stdout"]).get("errorCode") == "gmail_oauth_client_insecure", output[-400:])


def scenario_email_apple_mail(s: Scenario) -> None:
    c = s.context
    c.ingestion({"emailAddress": "reader@fixture.test"})
    result, payload = c.diagnose()
    s.record(result)
    email = connector(payload, "email")
    s.expect("Apple Mail account is configured, not verified", email.get("status") == "configured_unverified", email)
    step = email.get("nextStep", "")
    s.expect("next step gives the focus-mail status command", "focus-mail" in step and step.rstrip(").").find(" status") > 0, step)
    s.checks.append({"check": "Apple Mail reader (JXA/osascript) not exercised: needs macOS", "passed": True, "notTested": True})


def scenario_slack_only_report(s: Scenario) -> None:
    """A Slack-only user should not need Discord, Mail, GitHub, or Telegram keys."""
    c = s.context
    c.ingestion(c.dashboard())
    c.credentials({"slackToken": "xoxb-fixture-secret"})
    c.app_config(["slack"])
    result, payload = c.diagnose()
    s.record(result)
    s.expect("slack configured from default credentials", connector(payload, "slack").get("status") == "configured_unverified", connector(payload, "slack"))
    cli = s.record(c.run("focus_queue_morning.py", "collect", "--config", str(c.config), "--runtime", str(c.support / "ingestion")))
    output = cli["stdout"] + cli["stderr"]
    s.expect("collect is not blocked by disabled platforms", "Missing ingestion settings" not in output, output[-400:])
    s.expect("collect completes", cli["returncode"] == 0, output[-400:])
    s.expect("summary counts Slack", "Slack 0" in cli["stdout"], cli["stdout"][-400:])


def scenario_report_requires_unused_key(s: Scenario) -> None:
    """telegramBotUsername is required by the report but read nowhere."""
    c = s.context
    c.ingestion({**c.dashboard(), "telegramArchiveExecutable": str(c.home / "bin/agent")})
    c.app_config(["telegram"])
    cli = s.record(c.run("focus_queue_morning.py", "collect", "--config", str(c.config), "--runtime", str(c.support / "ingestion"), timeout=90))
    output = cli["stdout"] + cli["stderr"]
    s.expect("telegramBotUsername not required", "telegramBotUsername" not in output, output[-400:])
    s.expect("not blocked by disabled platforms", "Missing ingestion settings" not in output, output[-400:])


def stub_gh(c: Context, *, sentinel: Path) -> Path:
    gh = c.home / "bin/gh"
    gh.parent.mkdir(exist_ok=True)
    gh.write_text(f"#!/bin/sh\ntouch '{sentinel}'\necho '[]'\n")
    gh.chmod(0o755)
    return gh


def scenario_github_cli_missing(s: Scenario) -> None:
    c = s.context
    c.ingestion({**c.dashboard(), "githubRepositories": ["octo/repo"]})
    c.app_config(["github"])
    result, payload = c.diagnose()
    s.record(result)
    github = connector(payload, "github")
    s.expect("missing gh needs setup", github.get("status") == "setup_required", github.get("status"))
    s.expect("next step says install the GitHub CLI", "GitHub CLI" in github.get("nextStep", "") and "install" in github.get("nextStep", "").lower(), github.get("nextStep"))
    cli = s.record(c.run("focus_queue_morning.py", "collect", "--config", str(c.config), "--runtime", str(c.support / "ingestion")))
    output = cli["stdout"] + cli["stderr"]
    s.expect("collector is not blocked by disabled platforms", "Missing ingestion settings" not in output, output[-400:])


def scenario_github_cli_present(s: Scenario) -> None:
    c = s.context
    sentinel = c.home / "gh-executed"
    sentinel.unlink(missing_ok=True)
    gh = stub_gh(c, sentinel=sentinel)
    c.ingestion({**c.dashboard(), "githubRepositories": ["octo/repo"], "githubExecutable": str(gh)})
    c.app_config(["github"])
    result, payload = c.diagnose()
    s.record(result)
    s.expect("gh present is configured", connector(payload, "github").get("status") == "configured_unverified", connector(payload, "github"))
    s.expect("diagnostics never execute gh", not sentinel.exists())
    cli = s.record(c.run("focus_queue_morning.py", "collect", "--config", str(c.config), "--runtime", str(c.support / "ingestion")))
    output = cli["stdout"] + cli["stderr"]
    s.expect("collector uses the configured gh", sentinel.exists(), output[-400:])
    s.expect("collect completes", cli["returncode"] == 0, output[-400:])


def scenario_github_bad_repository(s: Scenario) -> None:
    c = s.context
    c.ingestion({"githubRepositories": ["octo"]})
    result, payload = c.diagnose()
    s.record(result)
    github = connector(payload, "github")
    s.expect("bad repository needs setup", github.get("status") == "setup_required", github.get("status"))
    s.expect("next step names owner/name", "owner/name" in github.get("nextStep", ""), github.get("nextStep"))


def scenario_telegram_states(s: Scenario) -> None:
    c = s.context
    helper = c.home / "bin/hermes"
    helper.parent.mkdir(exist_ok=True)
    helper.write_text("#!/bin/sh\nexit 0\n")
    helper.chmod(0o600)
    c.ingestion({"telegramArchiveExecutable": str(helper)})
    result, payload = c.diagnose()
    s.record(result)
    telegram = connector(payload, "telegram")
    s.expect("non-executable archive helper needs setup", telegram.get("status") == "setup_required", telegram.get("status"))
    s.expect("next step names telegramArchiveExecutable", "telegramArchiveExecutable" in telegram.get("nextStep", ""), telegram.get("nextStep"))
    helper.chmod(0o700)
    result, payload = c.diagnose()
    s.record(result)
    telegram = connector(payload, "telegram")
    s.expect("executable helper is limited coverage", telegram.get("status") == "limited", telegram.get("status"))
    s.expect("limited next step does not repeat setup", "telegramArchiveExecutable" not in telegram.get("nextStep", ""), telegram.get("nextStep"))


SCENARIOS: list[tuple[str, Callable[[Scenario], None]]] = [
    ("clean-machine-no-config", scenario_clean_machine),
    ("malformed-config", scenario_malformed_config),
    ("empty-config", scenario_empty_config),
    ("discord-credentials-without-bot-token", scenario_discord_token_missing),
    ("discord-cli-default-paths-clean-home", scenario_discord_default_paths),
    ("support-dir-override-credentials", scenario_support_dir_override),
    ("gmail-oauth-client-readable-by-others", scenario_gmail_insecure_client),
    ("gmail-oauth-client-wrong-type", scenario_gmail_invalid_client),
    ("gmail-client-not-authorized", scenario_gmail_not_authorized),
    ("gmail-authorization-state", scenario_gmail_authorized),
    ("mail-via-gmail-provider", scenario_email_gmail_provider),
    ("mail-apple-mail-account", scenario_email_apple_mail),
    ("report-slack-only", scenario_slack_only_report),
    ("report-telegram-unused-required-key", scenario_report_requires_unused_key),
    ("github-cli-missing", scenario_github_cli_missing),
    ("github-cli-present", scenario_github_cli_present),
    ("github-bad-repository", scenario_github_bad_repository),
    ("telegram-archive-states", scenario_telegram_states),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scripts", type=Path, default=Path(__file__).resolve().parents[3] / "Scripts")
    parser.add_argument("--home", type=Path, help="Use this disposable directory as HOME (host debugging).")
    parser.add_argument("--only", action="append", help="Run only the named scenario.")
    parser.add_argument(
        "--format",
        choices=["json", "summary"],
        default="json",
        help="summary prints one line per scenario, short enough for an ECC report step tail.",
    )
    arguments = parser.parse_args()

    if arguments.home:
        home = arguments.home.resolve()
        if home == Path.home().resolve() or any(home.iterdir()):
            parser.error("--home must be an empty disposable directory, never the real home")
    elif os.environ.get("FOCUS_QUEUE_CONNECTOR_SANDBOX") == "1":
        home = Path(os.environ["HOME"])
    else:
        parser.error("refusing to run against the real home; use the sandbox (run.sh) or --home EMPTY_DIR")

    context = Context(arguments.scripts.resolve(), home)
    results = []
    for name, operation in SCENARIOS:
        if arguments.only and name not in arguments.only:
            continue
        context.reset()
        scenario = Scenario(context, name)
        try:
            operation(scenario)
        except Exception as error:  # a crashing scenario is a failure, not an abort
            scenario.expect("scenario ran without crashing", False, repr(error)[:400])
        results.append({
            "scenario": name,
            "passed": scenario.passed,
            "checks": scenario.checks,
            "commands": scenario.commands,
        })
    summary = {
        "version": 1,
        "environment": {
            "home": str(home),
            "python": sys.version.split()[0],
            "platform": sys.platform,
            "network": "disabled" if os.environ.get("FOCUS_QUEUE_CONNECTOR_SANDBOX") == "1" else "host",
        },
        "passed": sum(1 for item in results if item["passed"]),
        "failed": sum(1 for item in results if not item["passed"]),
        "scenarios": results,
    }
    if arguments.format == "summary":
        for item in results:
            failed = [check["check"] for check in item["checks"] if not check["passed"]]
            line = f"{'PASS' if item['passed'] else 'FAIL'} {item['scenario']}"
            if failed:
                line += ": " + "; ".join(dict.fromkeys(failed))
            print(line[:240])
        print(f"connector scenarios: {summary['passed']} passed, {summary['failed']} failed")
    else:
        print(json.dumps(summary, indent=2))
    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
