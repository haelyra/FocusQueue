# FOC-080: Guided project creation

Project creation now asks a sequence of questions instead of requiring users to configure dashboard and workspace paths manually. Both Add project entry points open the same wizard. Editing and archiving existing projects retain their existing editor.

## Questions and saved results

| Step | Question | Result |
| --- | --- | --- |
| Project | What is it called, and is there an existing folder? | Explicit letter-only task prefix; existing folder or Create new folder with a chosen parent and name. |
| Repository | Which repository belongs to this project? | Suggested Git origin, another detected remote, a manually entered URL, no remote, or opt-in private GitHub creation. |
| Purpose | What is the purpose, audience, and measure of success? | Required purpose in the concise project plan; full answers in project context. |
| Documents | Include an existing PRD/document or start a PRD? | Explicitly selected Markdown, text, or PDF copies; optional PRD starter from the answers. |
| Review | Are these choices correct? | Final submission, with Back and Cancel available before submission. |

## Storage and repository choices

- Queue storage stays under Application Support's `projects/<id>/`. Connecting an existing folder does not put a dashboard or generated guidance in its source tree.
- Create new folder shows a parent-folder selector, a folder-name field, and the resulting path. It creates the folder only on final submission. It rejects existing file/folder names and uses an atomic directory creation so a concurrent collision cannot reuse another folder. A failed later save retains the created folder for retry.
- Native folder choosers also enable their New Folder control, including first-run setup and the existing-project editor.
- Task prefix starts empty and stays empty when the project name changes. Setup accepts 2 to 5 ASCII letters, normalizes them to uppercase, and rejects spaces, numbers, and punctuation. The helper text explains APP-001 as an example; legacy saved project prefixes remain supported.
- Git discovery reads the repository root and remotes. It supports SSH URLs, subfolders, and worktrees whose `.git` entry is a file.
- The suggested main remote prefers origin, then a GitHub remote, then the first recognized remote. Users can replace or clear the suggestion.
- Entering a URL records the project binding. It does not clone, push, or change local Git remotes.
- The Create new GitHub repository (private) checkbox accepts a repository name, owner/name, or GitHub URL. It runs authenticated, noninteractive `gh repo create --private --source <folder> --remote origin` on final submission and omits `--push`. See the [GitHub CLI command reference](https://cli.github.com/manual/gh_repo_create).
- The repository page displays the active local GitHub account using structured [GitHub CLI authentication status](https://cli.github.com/manual/gh_auth_status). If sign-in is needed, Copy sign-in command prepares a safely quoted command starting in the selected existing/parent folder. Check again refreshes status. The app never opens a terminal or signs in automatically.
- Read-only [GitHub API checks](https://cli.github.com/manual/gh_api) detect existing repositories before creating either a working folder or remote. The UI offers Use existing repository for a taken name. Final submission repeats this check. A 404 is only an availability hint; authentication, permission, rate-limit, and connection failures never count as available. GitHub remains authoritative if the name is claimed after the check.
- Account/name checks follow the current input and discard cancelled or stale results. Existing URLs remain recordable without requiring a successful online check, with any access failure displayed.
- Creation refuses folders that already have remotes or sit inside another Git repository. Authentication failures stop before Git initialization.
- A successful remote creation updates the draft before local persistence. Retrying a failed local save reuses that remote.
- An ambiguous timeout tells the user to check GitHub and enter the created URL before retrying.

## Documentation choices

- Discovery checks top-level documentation and up to three levels in docs, Documentation, or Documents. It skips hidden entries and symlinks, and caps traversal at 3,000 entries and 100 discovered documents.
- Imports accept Markdown, text, and PDF files up to 10 MB each and 40 MB total. Duplicate destination names require choosing one source.
- An imported Markdown PRD or requirements document becomes `prd.md` and takes precedence over the generated starter. An imported `plan.md` becomes `source-plan.md`.
- Copies preserve original bytes. Project Files and the existing document viewer expose the saved copies. Later edits to source files do not synchronize automatically.
- Setup refuses symlinked storage and conflicting existing documents rather than replacing authored content.

## Verification

Headless regression run: **205 tests in eight suites passed**, exit 0, with the opt-in live check skipped. This covered project setup, GitHub preflight, the app workflow, existing project/transaction behavior, first-run setup, project documents, queue state integration, and legacy persistence cases. A subsequent focused run checks the final account-error handling and URL parsing changes. `git diff --check` also passed.

Focused workflow command:

```sh
swift test --filter 'ProjectSetupTests|ProjectSetupGitHubTests|ProjectCreationWorkflowTests|SetupWizardTests|ProjectTests|ProjectTransactionTests|QueueViewModelTests|ProjectFilesSectionTests|ProjectPersistenceTests'
```

The actual affected workflow sanity test, `ProjectCreationWorkflowTests.existingProjectWorkflow`, uses a real temporary Git repository and real disk storage. It detects an SSH origin and authored PRD, submits through the wizard's view-model method, verifies source bytes and the existing catalog remain intact, creates WIZ-001 in the new project's dashboard, and reloads the project and task after restarting the model.

Other checks exercise manual URLs, new managed workspaces, PRD generation, document-copy precedence, invalid inputs, duplicate prefixes, missing CLI, existing remotes, authentication failure, timeout recovery, failed local saves, worktrees, and redirected storage. Every wizard page also mounts offscreen; opening the wizard leaves project storage unchanged.

The new-folder app workflow creates a working folder beneath a chosen parent outside managed storage, saves the project, creates FOL-001, and reloads it after restart. It also verifies a blank prefix blocks creation without creating the folder. Folder tests cover both file and directory collisions, traversal, and retry. GitHub tests cover duplicate names, a name claimed between wizard check and submission, signed-out JSON with exit zero, 200/404/401/403/429/500 responses, malformed inputs, and timeouts.

The opt-in live read-only check **passed separately** against the user's existing CLI session. It confirmed sign-in, detected the existing haelyra/ECCFocusQueue repository, and received 404 for a unique test name. It created no repository:

```sh
ECC_FOCUS_QUEUE_GITHUB_READ_CHECKS=1 swift test --filter ProjectSetupGitHubTests/liveReadOnlyGitHub
```

No simulated input or application activation ran. Default GitHub tests substitute network-facing CLI calls while executing local Git commands. Live GitHub creation, interactive sign-in, and installed-app interaction remain untested.

## Integration QA

After authorized integration and installation from the clean canonical checkout:

1. Open Settings, then Add project. Verify all five steps appear.
2. Verify task prefix is blank. Enter letters, check Create new folder, choose its parent, and enter a name. Verify an existing name produces a correction and an unused name shows the desired path.
3. On Repository, verify the signed-in account or copyable sign-in instruction. Check Create new GitHub repository and enter an existing name; verify creation is blocked and Use existing repository is offered. Try an unused name and verify the check finishes before Continue enables.
4. Enter purpose, select an existing PRD, and review. Cancel once and confirm neither the new folder nor a project was added.
5. Complete setup. Verify the working folder exists at the chosen path and the project lists its imported requirements and repository link under Files. Create a task with its selected prefix.
6. Keep private GitHub creation checked only when you intend to create a real remote. Confirm the remote stays private and no files were pushed.

Feature worktrees do not replace the shared app. Remote delivery and canonical integration require their authorized delivery workflow.
