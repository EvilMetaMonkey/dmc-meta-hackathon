# dmc

> **Meta AI Developer Hackathon 2026 entry.** This repository is a hackathon build on top of
> [dmc](https://github.com/EvilMetaMonkey/dmc). Everything up to the `pre-hackathon` tag (commit `d177c4b`)
> existed before the event, and every commit after it is hackathon work. See [HACKATHON.md](HACKATHON.md).

Local file history for coding projects, including changes made by AI tools.

dmc runs beside your editor, records eligible file versions in a local `.dmc/` folder, and lets you inspect, restore, and redo a selected version. It does not require a model, an AI subscription, or Haven.

> **Development preview: `1.1.0-dev.5.1`. Use a disposable project first.** This revision can record, inspect, restore, and redo complete eligible pre/post checkpoint manifests with conflict checks, interrupted-operation recovery, and a finalized Haven machine contract. Keep Git commits and independent backups.

## Read this before installing

- dmc records file contents while it is running, after its initial baseline is ready. It cannot recover an earlier version that it never captured.
- A successful start protects eligible text files. Binary files, files above the configured limit, ignored paths, and symlinks are excluded.
- Restoring a version replaces the current contents. Stop your agent/editor's writes and stop dmc's watcher before trying recovery. Preview first.
- Bursts, tasks, and marks group saved versions. They are **not complete before-and-after project checkpoints** and do not reliably undo an entire AI run.
- The new `checkpoint begin`/`close` workflow records an interval. It cannot prove whether an agent, editor, formatter, or person caused each change inside that interval.
- History stays in the project's `.dmc/` folder. It contains raw old file contents, which may include secrets if you allowed them to be captured. Do not upload the vault when reporting a bug.
- dmc is local recovery data, not protection against a lost disk or deleted project. Deleting `.dmc/` deletes its history.
- macOS arm64 is the locally verified platform for this revision. CI is configured for macOS arm64/Intel, Linux, and Windows; check the results for the exact revision you install. Windows file-symlink tests may require Developer Mode or suitable privileges.

## Get the right build

This branch is an unreleased development revision. An older GitHub release or Homebrew package may not contain these changes. For an invited trial, use the exact archive and checksum supplied by the maintainer and verify that `dmc --version` prints `1.1.0-dev.5.1`.

### Maintainer-provided bundle

1. Get the archive for your operating system and processor.
2. Compare its SHA-256 with the checksum supplied for that build.
3. Extract the **whole bundle** into a permanent folder. Keep `bin/` and `lib/` together; the SQLite native library is part of the app.
4. Add the bundle's `bin` folder to your PATH, or invoke the executable by its full path.
5. Run `dmc --version` and `dmc --help` before opening a project.

On Windows, the executable is `bin\dmc.exe`. Do not copy only the EXE out of the bundle. In PowerShell, run a quoted full path with the call operator, for example `& 'C:\Tools\dmc\bin\dmc.exe' --version`.

On macOS/Linux, the executable is `bin/dmc`. If macOS resolves `dmc` to Apple's `/usr/bin/dmc`, refresh the shell with `rehash` and check `command -v dmc`, or use your bundle's full executable path. If your OS blocks an unsigned build, ask the maintainer for the supported installation procedure for that archive.

### Build from source

You need repository access, this revision of the source, Git, and the Dart SDK. CI uses Dart **3.11.5**. The development changes must be published to the revision you check out; cloning an older main branch does not install them.

```sh
git clone https://github.com/EvilMetaMonkey/dmc-meta-hackathon.git
cd dmc-meta-hackathon
dart pub get --enforce-lockfile
dart test
dart run tool/check_analyzer.dart
dart build cli -o build/dmc
```

The bundle is in `build/dmc/bundle/`. On macOS/Linux, check it with:

```sh
./build/dmc/bundle/bin/dmc --version
dart run tool/smoke_bundle.dart build/dmc/bundle/bin/dmc
```

On Windows:

```powershell
.\build\dmc\bundle\bin\dmc.exe --version
dart run tool/smoke_bundle.dart build/dmc/bundle/bin/dmc.exe
```

An optional source-build installer, `install.ps1`, moves that bundle to `C:\bin\dmc` and updates your user PATH. It replaces an existing installation at that location; preserve the old bundle before using it. The bundled-path method above lets you try the new build without replacing another installation.

## Protect and recover an agent run

Checkpoints record the eligible state before and after one serialized run. Begin must succeed before allowing the agent to write:

```sh
dmc checkpoint begin --label "small refactor" --source haven
```

Save the returned checkpoint ID. If the checkpoint is `invalid` or the command exits nonzero, do not start the agent. Resolve every fatal issue and begin a new checkpoint. Exclusions are shown because ignored, binary, oversized, and linked paths are outside the checkpoint guarantee.

After the agent and other writers have stopped, close and inspect the same ID:

```sh
dmc checkpoint close cp_example_id
dmc checkpoint list
dmc checkpoint show cp_example_id
dmc checkpoint diff cp_example_id
```

`diff` classifies modified, created, and deleted paths. A rename appears as one deletion plus one creation. Stop the watcher and every editor or agent write before recovery. Restore previews by default:

```sh
dmc stop
dmc checkpoint restore cp_example_id
dmc checkpoint restore cp_example_id --apply
```

The preview checks every affected path and required snapshot without creating an operation journal or changing project files. Apply proceeds only when all paths still match the recorded post-run state. It restores modified and deleted files, removes files created during the interval, and records an operation ID.

After a completed restore, checkpoint redo also previews by default:

```sh
dmc checkpoint redo cp_example_id
dmc checkpoint redo cp_example_id --apply
```

If an apply exits with code `6`, preserve the project and vault. Use the operation ID printed by the failed command:

```sh
dmc checkpoint recover op_example_id --resume
# or return every target to its state immediately before the failed apply
dmc checkpoint recover op_example_id --rollback
```

Do not edit affected files before recovery. `status` and `doctor` report incomplete operations. Release is refused until the operation is completed or rolled back.

The checkpoint pins its manifest and operation snapshots against GC until:

```sh
dmc checkpoint release cp_example_id
```

Release detaches retention references after recovery is complete; use it only after you no longer need to restore or redo that checkpoint. It remains the explicit way to abandon an interrupted checkpoint lifecycle that has no restore operation.

Integrations request one JSON object on stdout with `--json`. Start with `dmc capabilities --json --schema-version 1`. Machine schema version 1 and checkpoint manifest version 1 are the finalized Phase 5 Haven contract. DMC rejects unsupported requested schema versions before running the command. See the [Haven integration guide](docs/HAVEN-INTEGRATION.md).

## Single-file history recovery

This older per-file workflow remains available for ordinary history. It is separate from the journaled agent-run checkpoint workflow above. Use a new disposable folder with one text file, `notes.txt`, containing `Version one`. Open a terminal in that folder. Run every project command from the same project root.

```sh
dmc init
dmc start
dmc status
dmc log
```

Wait for the **Ready** message. `status` should say `Protection: ready`. `start` captures a baseline before returning success. Note the snapshot ID for `notes.txt` in the log.

Change the file in your editor to `Version two` and save it. Stop the watcher; this waits for pending captures, including a recent save inside the debounce window:

```sh
dmc stop
dmc log
```

Use the original ID from your log. The example below uses `1`; substitute your actual ID:

```sh
dmc restore notes.txt --id 1 --dry-run
dmc restore notes.txt --id 1
```

The preview should describe the change back to `Version one`. The second command applies it. Open the file and verify the contents.

To preview and recover the overwritten `Version two`:

```sh
dmc redo notes.txt --dry-run
dmc redo notes.txt
dmc doctor
```

`status` reports `Protection: not ready` when the watcher is stopped. That is expected; run `dmc start` to record future edits.

For a slower, step-by-step exercise and feedback checklist, read the [tester walkthrough](docs/TESTER-WALKTHROUGH.md).

## Primary checkpoint commands

New users and Haven should use this workflow for agent runs.

| Command | What it does |
| --- | --- |
| `dmc init` | Creates a vault in the current folder. Adds a `.dmc/.gitignore` that excludes vault contents from Git. |
| `dmc start` | Starts one background watcher and waits for baseline readiness, up to 30 seconds. |
| `dmc stop` | Requests an authenticated graceful stop and waits up to 30 seconds. Never forcibly kills a PID from an old metadata file. |
| `dmc status` | Shows current protection readiness, last watcher state, errors, exclusions and settings. |
| `dmc checkpoint begin [--label <text>] [--source <name>]` | Captures and verifies the eligible pre-run manifest. Only an `open` result authorizes the run. |
| `dmc checkpoint close <id>` | Captures and verifies the post-run manifest and classifies changes. Stop the agent first. |
| `dmc checkpoint list [--limit <count>]` | Lists recent checkpoints, protection counts, lifecycle states, and recorded operation IDs. |
| `dmc checkpoint show <id>` | Shows lifecycle state, protected files, exclusions, and fatal issues. |
| `dmc checkpoint diff <id>` | Lists modified, created, and deleted paths; it does not change files. |
| `dmc checkpoint restore <id> [--dry-run]` | Preflights and previews the whole checkpoint. Preview is the default. |
| `dmc checkpoint restore <id> --apply` | Restores all changed eligible files through a durable operation journal. The watcher must be stopped. |
| `dmc checkpoint redo <id> [--dry-run]` | Previews the post-run state after a completed checkpoint restore. |
| `dmc checkpoint redo <id> --apply` | Reapplies the checkpoint post-run state through a new journal. |
| `dmc doctor` | Checks saved content hashes, missing/orphaned data, database references and watcher errors. Reports issues; does not repair them. |

## Advanced commands

These commands support diagnosis, interrupted recovery, integration, and storage management. Most users will need them only when DMC reports a specific condition.

| Command | What it does |
| --- | --- |
| `dmc watch` | Watches in the foreground. Wait for Ready; use Ctrl+C to stop gracefully. |
| `dmc checkpoint recover <operation-id> --resume` | Continues an interrupted checkpoint restore or redo. |
| `dmc checkpoint recover <operation-id> --rollback` | Returns every target to its captured pre-operation state. |
| `dmc checkpoint release <id>` | Explicitly abandons/purges retention pins while keeping small metadata. |
| `dmc capabilities --json --schema-version 1` | Reports the stable Haven contract, schema versions, checkpoint commands, safety capabilities, and cancellation requirements. |
| `dmc gc --dry-run` | Previews removal of expired, unprotected history. |
| `dmc gc` | Removes that expired history. Stop the watcher and other dmc commands first. |
| `dmc ui` | Opens the terminal history interface once history exists. Its restore key applies directly; use CLI previews for the first trial. |

## Single-file and legacy history

The following commands remain available for compatibility and manual file recovery. They are not complete, journaled project checkpoints and should not be used by Haven for agent runs.

| Command | What it does |
| --- | --- |
| `dmc log` | Shows the ten most recent saved file versions and their IDs. |
| `dmc diff notes.txt --id 1` | Compares a selected saved version with the current file. |
| `dmc restore notes.txt --id 1 --dry-run` | Previews a selected single-file restore. |
| `dmc restore notes.txt --id 1` | Applies that single-file restore directly. |
| `dmc undo notes.txt` | Alias-style selection of the most recent saved contents that differ from the current file. |
| `dmc redo notes.txt` | Restores the state saved immediately before the latest legacy undo/restore. |
| `dmc snap` | Manually scans and saves eligible current files. It is not a before-and-after checkpoint. |

Task labels (`dmc task start "label"`, `dmc task end`), burst/task logs, and marks (`dmc mark "label"`, `dmc marks`) also remain available as legacy grouping tools. A mark names the latest burst; restoring a group selects each included file's latest saved state in that group. It does not restore every file to the moment before that group began.

## What gets recorded

Default exclusions include `.git/`, `.dmc/`, `.dart_tool/`, `build/`, and `node_modules/`. Links inside the project are excluded even if they point to another file inside it. Do not replace vault files or folders with symlinks.

**Inside a Git repository, Git decides what is ignored.** dmc asks Git for the file list (`git ls-files --cached --others --exclude-standard`), so nested `.gitignore` files, negation, character classes, `.git/info/exclude` and your global excludes file all work exactly as in Git, and tracked files stay protected even if they match a pattern. dmc's default exclusions, `.dmcignore` and the link and size rules then apply on top. Submodules and nested repositories are excluded. Git must be installed: if dmc cannot find or run it inside a Git repository, checkpoints stop with `git_unavailable` instead of guessing. Checkpoint restore and redo never create, overwrite or delete a Git-ignored file.

**Outside a Git repository**, dmc loads root `.gitignore` and `.dmcignore` files when it starts. Its ignore language is deliberately limited, and `.dmcignore` uses the same limited language in both cases:

- Simple names, root-anchored paths beginning with `/`, directory patterns ending in `/`, `*`, `**`, and `?` are supported.
- `.dmcignore` also accepts backslashes as legacy path separators. Prefer `/` for portable new rules.
- Negation (`!`), character classes (`[ab]`), and Git backslash escapes are rejected with an error.
- Nested `.gitignore` files in scanned directories block readiness. Consolidate the necessary dmc exclusions in the root and exclude the affected subtree if appropriate; do not remove Git's own rules just to make dmc start.
- This is not full Git ignore compatibility. Unsupported policies stop capture rather than being silently accepted.

Example `.dmcignore`:

```text
# Keep private data and generated files out of new snapshots
/.env
.env.*
secrets/
*.log
**/generated/
```

Stop dmc before changing exclusions, then restart it. New exclusions do not erase previously captured contents. Review `dmc doctor` to see reported exclusions.

## Settings and retention

Optional global settings live in `~/.dmcconfig` (the user profile on Windows). Project settings in `.dmc/config.json` override them:

```json
{
  "retention_hours": 168,
  "max_file_size_kb": 2048
}
```

Both values must be positive integers. The defaults are seven days and 2 MiB per tracked file. Binary detection uses file extensions and a content probe; it is not a promise to preserve every file format.

This revision uses **explicit `dmc gc` cleanup**, avoiding startup pruning of an old baseline. GC preserves marked bursts, snapshots referenced by restore events, and snapshots pinned by unreleased checkpoint manifests and operations. Expired unmarked/unreferenced history can be removed even if it was a file's only older version. There is no storage cap or automatic orphan repair yet.

## If something goes wrong

- **Not ready / capture failed:** stop your agent and inspect `dmc status` and `dmc doctor`. Resolve the reported path, permission, ignore or storage error; restart and wait for Ready.
- **Start timed out:** a large baseline may still be running. Check status; use `dmc stop` to request cancellation. A timeout is not success.
- **Stop timed out:** capture may still be draining. Check status and doctor. Do not delete the vault or force-stop unrelated processes.
- **Legacy watcher metadata:** older versions do not have the authenticated control endpoint. Stop the old process from its own terminal. Only after verifying that it stopped, remove the old `.dmc/daemon.pid` file and retry. Keep the rest of the vault. A new watcher refuses to start over legacy PID metadata; do not run old and new binaries on the same vault.
- **Snapshot missing or corrupt:** preserve the vault and report the failure. Restore refuses mismatched content. Doctor does not reconstruct lost bytes.
- **Checkpoint conflict:** another program changed at least one affected path after the checkpoint closed. No checkpoint file is changed when preflight finds a conflict. Preserve the current work and inspect the reported paths instead of forcing the restore.
- **Interrupted checkpoint operation:** stop all writers, copy the operation ID from the error or `dmc status`, and choose `checkpoint recover ... --resume` or `--rollback`. Do not release the checkpoint or delete `.dmc/operations/`.
- **No version found:** dmc can only restore versions it captured and still retains. Restart scans reconcile current changes/deletions but cannot recreate intermediate edits made while dmc was stopped.

Do not edit the project during a restore. The journal makes completed steps detectable and recoverable, while each individual file replacement is atomic. The full multi-file operation is not one filesystem transaction, so interruption can temporarily leave a mix of before and after states until resume or rollback completes. Parent-link checks and stable reads reduce ordinary filesystem hazards, but this build does not sandbox hostile concurrent processes. POSIX permission bits are recorded and restored on macOS/Linux; Windows ACL preservation requires native validation and is not claimed.

## Feedback

Use [GitHub Issues](https://github.com/EvilMetaMonkey/dmc/issues) if you have access, or the feedback route supplied with your invited build. Include the dmc version, OS/processor, exact commands, expected result, actual result, and whether the watcher was ready. Remove private paths and file contents. Never attach a raw `.dmc/` vault unless you have deliberately reviewed its contents and arranged an appropriate transfer.

Developer details: [Phase 5 handoff](docs/PHASE5-IMPLEMENTATION.md), [Haven integration contract](docs/HAVEN-INTEGRATION.md), [Phase 4 handoff](docs/PHASE4-IMPLEMENTATION.md), and [original readiness audit](docs/TESTER-READINESS-AUDIT.md). No cloud service or Haven integration is required to use standalone dmc.

## License

dmc is released under the [MIT License](LICENSE).
