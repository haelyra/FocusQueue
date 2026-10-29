# FOC-080: Guided project creation

Project creation now asks a sequence of questions instead of requiring users to configure dashboard and workspace paths manually. Both Add project entry points open the same wizard. Editing and archiving existing projects retain their existing editor.

## Questions and saved results

| Step | Question | Result |
| --- | --- | --- |
| Project | What is it called, and is there an existing folder? | Unique name and task prefix; existing folder or a new managed workspace. |
| Repository | Which repository belongs to this project? | Suggested Git origin, another detected remote, a manually entered URL, no remote, or opt-in private GitHub creation. |
| Purpose | What is the purpose, audience, and measure of success? | Required purpose in the concise project plan; full answers in project context. |
| Documents | Include an existing PRD/document or start a PRD? | Explicitly selected Markdown, text, or PDF copies; optional PRD starter from the answers. |
| Review | Are these choices correct? | Final submission, with Back and Cancel available before submission. |

## Storage and repository choices

- Queue storage stays under Application Support's `projects/<id>/`. Connecting an existing folder does not put a dashboard or generated guidance in its source tree.
- A new managed workspace uses `projects/<id>/workspace`. To choose or create a folder elsewhere, use Connect an existing folder and the folder chooser.
- Git discovery reads the repository root and remotes. It supports SSH URLs, subfolders, and worktrees whose `.git` entry is a file.
- The suggested main remote prefers origin, then a GitHub remote, then the first recognized remote. Users can replace or clear the suggestion.
- Entering a URL records the project binding. It does not clone, push, or change local Git remotes.
- The Create a new private GitHub repository checkbox runs authenticated, noninteractive `gh repo create --private --source <folder> --remote origin` on final submission. It omits `--push`. See the [GitHub CLI command reference](https://cli.github.com/manual/gh_repo_create).
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

Final headless regression run: **183 tests passed in seven suites**, exit 0. This covered project setup, the app workflow, existing project/transaction behavior, first-run setup, project documents, queue state integration, and selected legacy persistence cases. `git diff --check` also passed.

Focused workflow command:

```sh
swift test --filter 'ProjectSetupTests|ProjectCreationWorkflowTests|SetupWizardTests|ProjectTests|ProjectTransactionTests|QueueViewModelTests|ProjectFilesSectionTests|ProjectPersistenceTests'
```

The actual affected workflow sanity test, `ProjectCreationWorkflowTests.existingProjectWorkflow`, uses a real temporary Git repository and real disk storage. It detects an SSH origin and authored PRD, submits through the wizard's view-model method, verifies source bytes and the existing catalog remain intact, creates WIZ-001 in the new project's dashboard, and reloads the project and task after restarting the model.

Other checks exercise manual URLs, new managed workspaces, PRD generation, document-copy precedence, invalid inputs, duplicate prefixes, missing CLI, existing remotes, authentication failure, timeout recovery, failed local saves, worktrees, and redirected storage. Every wizard page also mounts offscreen; opening the wizard leaves project storage unchanged.

No simulated input or application activation ran. GitHub command tests substitute the network-facing CLI calls while executing local Git commands. Live GitHub creation and installed-app interaction remain untested.

## Integration QA

After authorized integration and installation from the clean canonical checkout:

1. Open Settings, then Add project. Verify all five steps appear.
2. Connect an existing repository. Verify the suggested URL; use Back and return to confirm the answers remain.
3. Enter purpose, select an existing PRD, and review. Cancel once and confirm no project was added.
4. Complete setup. Verify the project lists its imported requirements and repository link under Files. Create a task with its selected prefix.
5. For a fresh folder, check private GitHub creation only when you intend to create a real remote. Confirm the remote stays private and no files were pushed.

Feature worktrees do not replace the shared app. Remote delivery and canonical integration require their authorized delivery workflow.
