# Saved tmux layouts

Focus Queue bundles pinned copies of tmux-resurrect and tmux-continuum. Builds and installs do not fetch plugins or change the user's tmux configuration. Both upstream MIT licenses travel with the app.

The managed `ecc-focus-queue` server saves its sessions, windows, pane layout, titles and current directories every five minutes, including while no terminal client is attached. It also saves when a client detaches. Prefix + Ctrl-s saves immediately. Prefix + Ctrl-r restores a saved layout. The application and CLI can use the same save and restore APIs.

Restore is explicit. It recreates shells in their saved directories and preserves existing pane processes. Task and agent ownership metadata is restored separately from live runtime identity. Resuming the matching saved conversation starts a fresh tracked pane, then retires only the old shell's agent-assignment marker. The shell itself is retained because it may have been repurposed after restore. A computer restart ends the old agent processes; neither plugin makes those processes survive a reboot. Launch prompts and command arguments are stripped from new snapshots, and terminal contents are not captured.

On the first use of a newly started server, the previous snapshot is copied to a recovery slot before any automatic save can replace the latest snapshot. An unresolved recovery copy survives additional restarts. A successful restore archives that recovery copy. Ordinary backups retain upstream's policy of keeping at least five copies and pruning older copies after thirty days.

## Storage and integration

The default private directory is `~/Library/Application Support/ECC Focus Queue/tmux/ecc-focus-queue`. `FOCUS_QUEUE_SUPPORT_DIR` changes the application support root. Tests use unique server names and temporary directories.

| Item | Purpose |
| --- | --- |
| `tmux.conf` | Generated configuration used only with the managed server |
| `save.sh` | Quoted launcher used by continuum |
| `resurrect/last` | Latest saved layout |
| `resurrect/recovery/last` | Previous server layout waiting for explicit recovery |
| `resurrect/recovery/restored-*.txt` | Retained recovery layouts after successful restoration |

`TmuxPersistence.prepare(executable:serverName:)` returns the generated configuration URL. Pass it with tmux's `-f` option when starting a managed server. Call `enable()` for an already running server. `save()`, `restoreLayout()` and `status()` back the user actions and status display. Newly recreated panes receive `@focus-queue-restored=1` plus a separate `@focus-queue-restored-agent` assignment. They never receive the live `@focus-queue-agent` marker until that exact conversation is started and confirmed in the pane. Existing live panes are not demoted by an idempotent restore.

The server schedules a lightweight timer every thirty seconds, and the actual bundled continuum save script decides whether its five-minute interval has elapsed. This is necessary because upstream's status-line polling cannot run while detached, and its initializer intentionally suppresses operation when other tmux servers exist. Our adapter scopes every plugin command to the managed socket, including when a user's own tmux server is also running. We leave continuum's operating-system boot helpers disabled.

## Upstream pins and adjustments

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect/tree/cff343cf9e81983d3da0c8562b01616f12e8d548): `cff343cf9e81983d3da0c8562b01616f12e8d548`.
- [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum/tree/0698e8f4b17d6454c71bf5212895ec055c578da0): `0698e8f4b17d6454c71bf5212895ec055c578da0`.

The source trees are included in the repository. The machine-readable upstream manifest records the codeload archive SHA-256 values. Resurrect carries a small local quoting patch for paths containing spaces, including macOS's Application Support directory, and escapes literal tmux format characters in restored directories. Continuum source is unchanged. The separate Focus Queue adapter supplies socket isolation, timer scheduling, recovery retention, command stripping and explicit restoration.

Headless integration tests exercise detached automatic saving with another unrelated server present, paths containing spaces/quotes/hash characters, live-pane preservation and stopped-server restoration into shells. They create and stop only disposable test servers. No UI automation is required.
