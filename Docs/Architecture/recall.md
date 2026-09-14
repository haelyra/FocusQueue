<!-- fq-architecture: {"id":"recall","title":"Agent runtime sessions and terminal connections","sources":[{"path":"Sources/FocusQueueCore/Integrations.swift","sha256":"06670c5de801d2ffb5585940309229a2bc6cd5f579438e7bc631d14617575745"},{"path":"Sources/FocusQueueCore/WezTermConnection.swift","sha256":"e72b649ee180c05ec9d5010a382f3d3cd4e7d1b0b8c2981ab465b69bd2bda2a5"},{"path":"Sources/FocusQueueCore/AgentLauncher.swift","sha256":"a6b7716c20d6d5154c8d04e62c80bccc7b9e62069b4b0c22a0fce116be0b7916"},{"path":"Sources/FocusQueueCore/Tmux.swift","sha256":"e277a4ff8dcf317f7f5a73240256cea0f5ec009424c8ff6b848f0117645cbd06"}]} -->

# Agent runtime sessions and terminal connections

The saved runtime is the current execution identity. In the default tmux mode, a terminal pane is a replaceable client view. In direct mode, the exact WezTerm pane owns the live process. Agent creation starts the provider once and persists the selected runtime identity on its named subtask. Recall focuses or reattaches only that identity.

## Follow the code

- [Integrations.swift](../../Sources/FocusQueueCore/Integrations.swift), `WezTermController.openManagedRuntime`: verifies the saved tmux identity, focuses its existing client or spawns only an attach client, and labels the exact pane.
- [WezTermConnection.swift](../../Sources/FocusQueueCore/WezTermConnection.swift), `resolve`: tries the configured connection, then bounded same-user socket candidates. Successful JSON is required; deadlines remain visible.
- [AgentLauncher.swift](../../Sources/FocusQueueCore/AgentLauncher.swift), `startManagedSession`: builds the provider command as positional data and returns the tmux identity without opening a terminal.
- [AgentLauncher.swift](../../Sources/FocusQueueCore/AgentLauncher.swift), `launchDirect`: starts one provider in WezTerm and returns its exact pane and socket without a retry launch.
- [Tmux.swift](../../Sources/FocusQueueCore/Tmux.swift), `TmuxController`: creates, decodes, verifies and attaches sessions in the dedicated `ecc-focus-queue` server.

## Boundaries and checks

Provider UUIDs and historical transcripts do not authorize recall. A missing, stopped or changed runtime fails without running provider resume commands, creating a replacement, or opening a shell. Review `ManagedSessionRecallTests`, `SetupAndTmuxTests`, `AgentLauncherTests` and `WezTermConnectionTests` when changing this path. New providers require a launch adapter and runtime verification.

Summary semantics are unverified after generation. Source checksum drift requires rereading the relevant implementation before editing this card.
