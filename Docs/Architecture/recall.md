<!-- fq-architecture: {"id":"recall","title":"Agent runtime sessions and terminal connections","sources":[{"path":"Sources/FocusQueueCore/Integrations.swift","sha256":"7e7f5f0c1de9a918d169f4f914ea2f5b717cafa83803ce937c7ea09624e4e756"},{"path":"Sources/FocusQueueCore/WezTermConnection.swift","sha256":"f7dda381290b0d2c5610f385d81e07e958c4fe2bc381635e7c363e979ae727ed"},{"path":"Sources/FocusQueueCore/AgentLauncher.swift","sha256":"ca8815a5e0638a3ba339fcf4c502bf65f42c05dc51a826eade96202d088dbaaa"},{"path":"Sources/FocusQueueCore/Tmux.swift","sha256":"8aaf1016816dc504ac2011749589a7c4caa3b37285da74a1cc9dded2d4f41c5e"},{"path":"Sources/FocusQueueCore/ManagedTerminalLauncher.swift","sha256":"2821e3cb9f221a2f7d1d08157f61e2a292cea7358d9afa2ac9af5bd50ce27881"},{"path":"Sources/ECCFocusQueue/QueueViewModel.swift","sha256":"c2909beae79ffcded1653194155a24e059d7c3784726181284e56d64982c0d29"}]} -->

# Agent runtime sessions and terminal connections

The saved provider UUID identifies the conversation and the saved tmux reference identifies its current execution. In managed mode, a terminal window is only a replaceable client view. Agent creation starts the provider once and persists both identities on its named subtask. Recall verifies both identities before opening the exact live pane. A stopped conversation is resumed once with its saved UUID and workspace, then receives a new verified tmux reference. Codex multi-agent sub-agent threads are not directly resumable: recall resolves the saved UUID to the root of its rollout lineage and resumes that root conversation instead.

## Follow the code

- [Integrations.swift](../../Sources/FocusQueueCore/Integrations.swift), `WezTermController.openManagedRuntime`: verifies and selects the saved tmux pane immediately before launching its terminal client. `locateProviderProcess`: blocks a resume only when an unverified process could plausibly own the requested session — Claude is scoped by project directory, Codex by the working directories its rollout records.
- [AgentLauncher.swift](../../Sources/FocusQueueCore/AgentLauncher.swift), `CodexSessionLineage.root`: walks rollout `parent_thread_id` links so a saved sub-agent UUID resumes its root conversation.
- [ManagedTerminalLauncher.swift](../../Sources/FocusQueueCore/ManagedTerminalLauncher.swift), `open`: opens a fresh WezTerm process or a private one-use macOS Terminal command file with the exact tmux attach argv.
- [QueueViewModel.swift](../../Sources/ECCFocusQueue/QueueViewModel.swift), `openSubtask`: compares the clicked record's provider UUID with the live process, rejects mismatches, and resumes a stopped exact UUID from its saved workspace.
- [WezTermConnection.swift](../../Sources/FocusQueueCore/WezTermConnection.swift), `resolve`: remains the bounded connection resolver for direct WezTerm runtimes only.
- [AgentLauncher.swift](../../Sources/FocusQueueCore/AgentLauncher.swift), `startManagedSession`: builds the provider command as positional data and returns the tmux identity without opening a terminal.
- [AgentLauncher.swift](../../Sources/FocusQueueCore/AgentLauncher.swift), `launchDirect`: starts one provider in WezTerm and returns its exact pane and socket without a retry launch.
- [Tmux.swift](../../Sources/FocusQueueCore/Tmux.swift), `TmuxController`: creates sessions in the dedicated `ecc-focus-queue` server with mouse scrolling and 50,000 lines of pane history, waits for three matching final-process observations, explains incomplete fields, and verifies recall without creating replacements.

## Boundaries and checks

Neither a terminal pane nor a provider UUID alone authorizes managed recall. A live runtime needs an exact tmux identity and matching provider UUID. A stopped record needs a valid saved UUID and workspace before one provider-native resume is allowed. Missing, ambiguous, or changed identities fail without opening another agent. Review `ManagedSessionRecallTests`, `QueueViewModelTests`, `AgentLauncherTests`, `TmuxOrganizerTests`, and `LiveAgentLaunchTests` when changing this path. New providers require an exact resume adapter and runtime verification.

Summary semantics are unverified after generation. Source checksum drift requires rereading the relevant implementation before editing this card.
