# Connector setup sandbox (ECC Tier 1, rootless Podman)

This folder tests daily-report connector setup and diagnostics from a clean
Linux home instead of a developer's configured Mac. It follows the ECC tiered
sandbox model. A manifest declares what the test needs (`linux`, `clean-home`,
non-native, no network). The ECC router then picks Tier 1, which is rootless
Podman. The tier runs with all capabilities dropped, a read-only source mount
at `/workspace/source`, the network off, uid 1000, and a disposable `/home/ecc`.

| File | Role |
| --- | --- |
| `Containerfile` | ECC Tier 1 base (`localhost/ecc-sandbox:ubuntu-lts`) plus stdlib Python 3 |
| `sandbox.yaml` | ECC manifest; routes to Tier 1 Podman, `report: install-diff` |
| `scenarios.py` | 18 scenarios; fake fixtures only; one JSON result document |
| `run.sh` | Builds the image, stages a sanitized copy, runs ECC and a full-detail pass |

## Run

```sh
podman machine start            # once per boot, macOS
Tests/Sandbox/connectors/run.sh --out /tmp/fq-connectors
```

Expected stderr ends with `connector scenarios: 18 passed, 0 failed`. The
script exits 0 only when both of these pass:

- The ECC-routed run, `ecc-sandbox run --local-only` with
  `ECC_SANDBOX_IMAGE`. It writes `ecc-report.json`, the sealed report with
  `backend: podman` and `tier: 1`, plus the layer diff.
- The direct pass, `podman create/start/exec/diff/rm` with the same isolation
  flags. It writes `scenarios.json` with full command output, because the ECC
  report keeps only a step tail.

If `ecc-sandbox` is not installed, `run.sh` skips the ECC run and still does
the direct pass. Use `--direct-only` to force that mode. Build the base image
once from an ECC checkout with this command:
`podman build --file images/sandbox/Containerfile.ubuntu --tag localhost/ecc-sandbox:ubuntu-lts images/sandbox`.

To iterate on the host without Podman, point the scenarios at an empty
throwaway home. Host tools such as `/opt/homebrew/bin/gh` can change the
GitHub results:

```sh
python3 Tests/Sandbox/connectors/scenarios.py --home "$(mktemp -d)" --format summary
```

`scenarios.py` refuses to run against the real home.

## What this does and does not prove

- Proven here: config parsing and connector-scoped validation, which settings
  each connector requires, the offline checker's status and next steps, and
  missing-credential and bad-file paths. Gmail runs up to the OAuth loopback
  timeout, and Discord and Slack run up to the network boundary. Secrets are
  never echoed.
- Not proven here: Apple Mail. The JXA/AppleScript reader needs macOS Mail
  automation. Keychain storage of Gmail refresh tokens is also untested.
  Live Telegram, Discord, Slack, Gmail, and GitHub API access is untested,
  because the network is off and no real accounts are used. Native macOS
  behavior belongs to ECC Tier 2.
- Isolation: the container never sees the home directory, `~/Secrets`, or the
  Keychain. `run.sh` copies only `Scripts/` and this folder into a temporary
  staging directory.
