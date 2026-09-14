# Setup preview foundation

The setup preview reports optional tools, planned application paths, and conflicts using filesystem metadata only. It performs zero installation actions and spends zero model tokens. It is groundwork for a setup wizard; `installationReady` remains false.

Run [focus_queue_setup.py](/Users/hira/Documents/Github/ECCFocusQueue/Scripts/focus_queue_setup.py) with Python 3:

```sh
python3 Scripts/focus_queue_setup.py
python3 Scripts/focus_queue_setup.py --workspace "/absolute/path/to/workspace" --enable terminal_sessions --enable agent_chat
```

The default workspace is the current directory. Repeat `--enable` to select optional capabilities in the preview. A selection describes a future setup plan and performs no action. Use `--home` only for isolated fixtures or a second-user layout test. Paths must be absolute; paths with spaces are supported.

The JSON includes:

- Platform and workspace metadata. Unsupported platforms receive no macOS installation plan. Workspace contents and schema are not read or validated.
- Known provider, terminal, and supporting-tool locations under the user's local bins, conventional system bins, and application bundles. Detected executables remain `detected_unverified`, with authentication and compatibility verification explicitly false. Providers, version commands, startup profiles, and helper scripts are never executed.
- Optional agent, terminal, connector, login-launch, and Desktop capabilities with missing dependency groups. Telegram personal-inbox support is explicitly unavailable. Selecting an optional capability includes its shared helper paths without enabling unrelated features.
- Planned application bundle, support files, helper, and LaunchAgent destinations. Every existing destination remains unverified and receives `preserve_and_review`. Symlink destinations, symlink/file parents, and inaccessible paths are conflicts. The script neither follows destination links for writes nor changes their contents.
- Explicit zero-effect counters and limitations. JSON contains local paths intentionally, so keep the output local if those paths are sensitive. It contains no account identities, environment values, file contents, credentials, or inbox data.

This preview does not establish file ownership from a familiar filename. It does not inspect an existing app's signature, available disk space, access permissions, OS minimum version, or provider behavior. Tool discovery uses conventional locations rather than executing a shell to interpret customized aliases or PATH. Missing detections require later user-selected paths and separate verification.

The inventory is preliminary. A production installer still needs a complete ownership manifest, selected account configuration, permission guidance, reviewed migration/overwrite decisions, staged installation, rollback, and uninstall behavior. Keep those mutations in a separate command with a concrete reviewed plan.

Run the fixture tests in [test_focus_queue_setup.py](/Users/hira/Documents/Github/ECCFocusQueue/Tests/test_focus_queue_setup.py):

```sh
python3 -m unittest discover -s Tests -p 'test_focus_queue_setup.py' -v
```

Coverage includes second-user homes, spaces, missing dependencies, unverified executable candidates, unrelated files, broken symlinks, parent conflicts, inaccessible paths, shared capability paths, unsupported platforms, safe CLI errors, and tests that forbid content reads, tool execution, and network access. No live installation or account connection is needed.
