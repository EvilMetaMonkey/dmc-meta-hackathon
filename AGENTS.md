# AGENTS.md

## Session status (STATUS.md)
[STATUS.md](STATUS.md) is the running record of this hackathon build. Every coding agent working in
this repository, whatever the tool, must keep it current:

- **At the start of a session**, read `STATUS.md` before doing anything else.
- **During a session**, update it whenever a task finishes, something breaks or gets fixed, or the
  plan changes. Do not wait until the end.
- **At the end of every session**, update it before you stop, even if the session was short or
  nothing worked.

Each update must keep the four sections accurate:

- **Done:** finished and verified work. Say how it was verified (tests, analyzer, manual check).
- **In progress:** started but not finished, with enough detail for the next agent to pick it up.
- **Broken:** known failures, failing tests and regressions, with the exact command or symptom.
- **Next:** the ordered list of what to do next.

Also update the `Last updated` line (date and agent) and add one line to the session log, newest
first. Keep it factual: never mark anything done that was not verified, and never drop a broken
item without saying how it was fixed. Commit `STATUS.md` with the work it describes.

---

## Project Summary
dmc is a Dart CLI for local shadow-history version control designed for AI-assisted coding workflows. It watches project files, debounces rapid changes, stores snapshot metadata plus hashed backups in a hidden repo-local `.dmc/` SQLite vault, restores prior file states quickly, and can diff a working file against historical snapshots.

The long-term product direction is:

> dmc is a trusted rollback safety net for AI coding agents.

It is **not** intended to replace Git.  
Git is for source control and commits.  
dmc is for recovering from risky or broken AI-assisted edits before commit.

---

## Current Phase Status
The current numbering refers to the checkpoint hardening plan, replacing the original feature milestones.

- Hardening Phase 1: implemented locally; snapshot integrity, migrations, preimages, and retention protection. See `docs/PHASE1-IMPLEMENTATION.md`.
- Hardening Phase 2: implemented locally for review; baseline/readiness, event reconciliation, graceful drain, path/ignore safety, authenticated daemon control, and CI. See `docs/PHASE2-IMPLEMENTATION.md` for evidence and remaining platform gates.
- Hardening Phase 3: implemented locally for review; explicit begin/close manifests, change classification, exclusions/issues, retention pins, show/diff/release, and versioned JSON. See `docs/PHASE3-IMPLEMENTATION.md`.
- Hardening Phase 4: implemented locally for review; conflict-aware checkpoint restore/redo, durable operation journals, per-file atomic replacement, recovery storage, and resume/rollback. See `docs/PHASE4-IMPLEMENTATION.md`.
- Hardening Phase 5: implemented locally for review; finalized Haven JSON schema 1, schema negotiation, checkpoint listing and operation discovery, compiled reference harness, and forced-cancellation recovery tests. See `docs/PHASE5-IMPLEMENTATION.md` and `docs/HAVEN-INTEGRATION.md`.
- Existing CLI features include restore/undo/redo, previews, audit history, status/doctor, configuration, bursts, tasks, marks, manual snap, GC, and terminal UI.
- Current version: `1.1.0-dev.5.1`, an unreleased development preview with additive recovery preview. Passing local tests is not a public-release verdict. Phase 6 remains separate.

### Next Planned Phases (not yet implemented)
- Phase 6: distribution, documentation, platform and release gates.

Legacy bursts, tasks, marks, and `snap` are not complete project checkpoints. Preserve their documented meaning. Do not proceed into another phase without the user's authorization.

---

## Product Goals
dmc should help developers safely recover from:
- bad AI edits
- multi-file hallucinations
- destructive agent runs
- mixed manual + agent workflows
- risky refactors before Git commits

The most important product qualities are:
1. **Trust**
2. **Safety**
3. **Clarity**
4. **Predictability**
5. **Minimal workflow friction**

---

## Tech Stack
- Language: Dart
- Storage: SQLite via `sqlite3`
- Path handling: `path`
- Hashing: `crypto` (SHA-256)
- CLI parsing: `args`
- Text diffing: `diff_match_patch`

---

## Architecture Rules (Must Follow)
- All internal logic MUST remain in `lib/src/`.
- `bin/dmc.dart` is only the CLI entry point and should only call into library code.
- Public API exports are managed via `lib/dmc.dart`.
- Keep concerns separated:
  - CLI parsing and routing
  - application/services
  - repository/data access
  - watcher/file system logic
  - diff/restore logic
  - config handling
- Prefer additive changes over rewrites.
- Do not move large amounts of logic unless necessary to support a feature cleanly.
- Avoid introducing framework-like complexity into a small CLI tool.
- New features should fit the existing repo-local `.dmc/` model.
- **Doc is a separate program.** `doc/` is its own Dart package (`dmc_doc`, executable `doc`) with
  its own pubspec, `bin/doc.dart`, `lib/src/`, analyzer run and tests (the root analyzer excludes
  `doc/**`). Every model call lives in Doc; dmc never runs a model. Doc talks to dmc only by
  running the dmc executable with `--json --schema-version 1` (found via `--dmc`, `DMC_BIN`, then
  `PATH`, and checked with `capabilities`, skipping Apple's `/usr/bin/dmc`). It never reads
  `.dmc/`, imports dmc's Dart code, or writes workspace files; it writes only `config.json` and
  `usage.json` in its user config directory, and lessons in its user data directory (keyed by
  dmc's workspace fingerprint). Secrets are redacted before any hosted call.
- **Doc providers:** `meta` (Muse Spark 1.3, Muse Wonder), `baseten` (Muse Spark Open), `fireworks`
  (Muse Spark Open backup), `modal` (Mike's private Muse Glimmer deployment in `deploy/modal/`;
  base URL from the config or `DOC_MODAL_BASE_URL`, never committed) and `local` (this Mac).
  Roles: `summary` baseten → fireworks (Modal Glimmer is an opt-in, see `doc/README.md`),
  `workhorse` baseten → fireworks, `restore` meta → baseten;
  every fallback is logged and there is no second hop. `--local` means this Mac only and refuses
  Modal. Keys only from env vars (`MODEL_API_KEY`, `BASETEN_API_KEY`, `FIREWORKS_API_KEY`,
  `MODAL_GLIMMER_KEY`). See `doc/README.md`.
- **`doc restore` only drives dmc.** It previews with `dmc checkpoint restore <id> --json`, applies
  with `--apply` after the user agrees, never forces a conflict or recovery, then offers a lesson.
  To show the model the undone work, Doc exports the checkpoint's states with
  `dmc checkpoint export` into a temporary directory outside the workspace and diffs them there.
- **`doc bisect` tests exports, never the working copy.** Each probe is a `dmc checkpoint export`
  into a temporary folder outside the workspace, where `--setup` and `--test` run; the folders
  are deleted unless `--keep`. The search (`bisectFirstBad`) is pure and deterministic. A model
  only explains the result, and a restore is offered, never taken automatically.
- **Lessons are Doc-only.** dmc never sees them. Matching is a fixed file-overlap rule; models only
  draft lessons (workhorse) and condense briefs (summary). Nothing enters the library without
  `doc lesson approve`, and a brief reaches an agent only after the user agrees (`--yes` is for
  scripted demos).

---

## Runtime/Data Notes
- DMC working directory: `.dmc/`
- Snapshots folder: `.dmc/snapshots/`
- Database file: `.dmc/dmc.db`
- Schema version: 5 (`PRAGMA user_version`); history, marks, and restore events retain their legacy meanings. Checkpoint operation and per-file journal tables are additive and foreign-key constrained. Version 4 adds nullable agent-turn context columns to `checkpoints` (agent, session, turn, transcript path, and transcript size/SHA-256 at close); see `docs/AGENT-HOOKS.md`. Version 5 adds nullable `checkpoints.close_policy_fingerprint` and `checkpoint_files.scope_change` (`left_scope`/`entered_scope`) for ignore-policy drift; existing rows are not rewritten.
- One checkpoint may be `creating`, `open`, or `closing`. `invalid`, `closed`, and `released` checkpoints do not block a new begin. Explicit release can abandon an interrupted state.
- Begin and close each scan and verify eligible file state. A rename is represented as deletion plus creation.
- **Ignore-policy drift is handled per file.** If the policy fingerprint at close differs from begin (an agent edited `.gitignore`, added a nested one, or `.dmcignore` or the config changed), close still succeeds: the close-time policy decides what is protected, `closePolicyFingerprint` records it, and a non-fatal `policy_changed` warning is added. A file in scope at both ends is captured and restorable as usual. A file in scope at begin but not at close (including a deleted file the new policy ignores) is `left_scope`: its before snapshot is kept, no after state is captured, and restore and redo skip it. A file excluded at begin (it or a parent was recorded as an exclusion) but in scope at close is `entered_scope`: it has no before state (recorded as `absent`), restore never deletes or overwrites it, and redo only confirms it still matches its after state (otherwise a `workspace_drift` conflict). Both have a null `change` and appear under `skipped` in the restore/redo plan, which does not block apply. The ignore files themselves restore like any other in-scope file. Checkpoints that were already `invalid` stay invalid.
- Manifest and operation references pin history until explicit release. Release is blocked while an operation is incomplete, then clears snapshot IDs while retaining hashes, modes, classifications, issues, and audit metadata.
- Machine envelope schema and checkpoint manifest schema are version 1. JSON mode writes exactly one JSON object to stdout. Every envelope includes the DMC version, exit code, command, canonical workspace identity, data, warnings, and errors. `--schema-version 1` lets Haven reject an incompatible executable before work begins.
- Checkpoint restore/redo previews by default and requires `--apply`. Never route checkpoint recovery through legacy burst/task/mark semantics. Stop the watcher and all writers before apply.
- `checkpoint export <id> --to <dir> [--state before|after]` (default `after`, which needs a closed checkpoint; `before` works for open, closing and closed) writes one manifest's files, with recorded modes and every SHA-256 verified, to a new or empty directory that is neither inside the workspace nor contains it (checked on given and link-resolved paths; a link target is refused). It writes to a temporary sibling and renames at the end, so a failure leaves nothing; it holds the workspace lock only while reading the manifest. It never writes inside the workspace, so it is not a restore and has no journal. JSON data: `checkpointId`, `state`, `directory`, `fileCount`, `totalBytes`, `manifestSha256` (SHA-256 of sorted `<octal mode or ->\t<sha256>\t<posix path>\n` lines). **The export holds only protected files: ignored dependencies (`node_modules`, `.dart_tool`, build output) are not included, so bisect must set them up itself.**
- An incomplete operation must be handled with `checkpoint recover <id> --resume|--rollback`; status and doctor expose these journals.
- Add `--preview` to inspect recovery targets and conflicts without changing the workspace or journal. Gate clients on `features.operationRecoveryPreview`. See `docs/RECOVERY-PREVIEW.md`.
- Default ignored directories: `.git`, `.dmc`, `.dart_tool`, `build`, `node_modules`. They apply in both modes below.
- **Git mode** (the workspace root is inside a Git work tree, found by a `.git` entry at or above the root): Git decides what is ignored. The protected file list is `git -C <root> ls-files --cached --others --exclude-standard -z`, which honours nested `.gitignore`, negation, character classes, `.git/info/exclude`, `core.excludesFile`, and keeps tracked files in scope even when they match a pattern. DMC's default directories, `.dmcignore` (still the subset below), and the link, size and protected-path rules apply on top. Gitlinks, submodules and nested repositories are excluded (`nested_repository`). `lib/src/git_ignore.dart` and `scanWorkspace` in `lib/src/workspace_scan.dart` implement it; every scanner path (checkpoint begin/close/verification, `snap`, the watcher) uses that one list.
- Git mode never falls back silently. If git is not on `PATH`, `/usr/bin`, `/opt/homebrew/bin`, `/usr/local/bin` (or `C:\Program Files\Git\cmd` on Windows), begin records `git_unavailable` and close fails with it while the checkpoint stays open; a failing git gives `git_failed`. `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and similar variables are stripped so Git sees the detected repository.
- In Git mode the policy fingerprint (version 2) covers the mode, DMC's rules, and the SHA-256 of every ignore source Git reads: each effective `.gitignore` (including those above the root, and not those inside directories Git already ignores), `info/exclude` and `core.excludesFile`. Changing any of them mid-turn fails close with `policy_changed`, as before.
- Checkpoint restore and redo ask `git check-ignore` about their targets and refuse any Git-ignored path (`git_ignored` conflict): they never create, overwrite or delete a Git-ignored file. The watcher batches its Git checks through one `git check-ignore --stdin -z` per drain, not one process per event.
- **Outside Git**, ignore support is the explicit subset: root `.gitignore` and `.dmcignore` with names, root anchoring, directory patterns, `*`, `**`, and `?`. Reject negation, character classes, Git escapes, and nested `.gitignore` in scanned directories; do not imply full Git compatibility.
- Both files are loaded once when the watcher starts; restart after policy changes. Empty lines and `#` comments are ignored. Scanning prunes ignored directories before descent and excludes all links below the root.
- `status` and `doctor` print the active ignore policy; doctor reports one that cannot be loaded as an issue.
- Debounce delay: `500ms`
- Retention default: `168` hours; max file size default: `2048` KiB. Project `.dmc/config.json` overrides global `~/.dmcconfig`.
- Cleanup runs only through explicit `gc`, never automatically on watcher startup. Mark/audit references pin history; expired unprotected baselines can still be removed.
- `init` adds `.dmc/.gitignore` to exclude vault contents from Git. Vaults contain raw historical bytes; do not collect them as routine diagnostics.
- `dmc log` shows snapshot IDs for historical targeting
- `dmc diff <file>` compares the working file to its latest snapshot and prints ANSI-colored additions/deletions
- `dmc undo --id <id> <file>` and `dmc diff --id <id> <file>` target exact historical snapshots

### Data/Storage Direction
When extending the schema or storage model:
- prefer forward-compatible schema design
- keep migrations simple and explicit
- do not break existing local repos silently
- preserve repo-local operation
- optimize for correctness and trust over premature optimization

---

## Command and UX Principles
- Commands should feel safe, explicit, and predictable.
- Prefer clear command names over clever ones.
- `undo` is convenient, but `restore` should be supported where it improves clarity.
- Destructive actions should support preview/dry-run whenever practical.
- Output should be concise, readable, and useful in plain terminals.
- Errors must be actionable and specific.
- Avoid silent destructive behavior.
- If behavior is ambiguous, fail clearly rather than guessing.
- Logs should become increasingly human-readable as metadata expands.

---

## Safety and Recovery Principles
These rules are critical because dmc is a recovery tool.

- Never silently overwrite user work in a surprising way.
- Prefer warnings before destructive restore behavior.
- Preview/dry-run should be used whenever possible for restore-like operations.
- Restore operations should become auditable.
- Redo should be supported for restore workflows.
- If restore target selection is ambiguous, return a clear error instead of guessing.
- Trust and correctness are more important than cleverness or speed.

---

## File Watching Principles
- Await watcher start before reporting readiness; subscribe and queue events during baseline capture.
- Await stop and pending work before closing the database. Reconcile on restart and periodically while running; never claim to recover unseen intermediate versions.
- Use the shared path validator and snapshot service for file operations. Links below the workspace root, including vault links, are not supported.
- Only the authenticated loopback control endpoint may request background shutdown. A saved PID is not ownership; never signal an arbitrary PID from metadata.
- Surface capture/scan/watch errors as degraded protection through status/doctor.
- Preserve the current per-file debounce concept unless explicitly redesigning it.
- Be conservative when handling duplicate events, rapid write bursts, and atomic-save patterns.
- Avoid creating noisy duplicate snapshots.
- Snapshot creation should be deterministic and explainable.
- File watching behavior should remain Windows-safe.
- Cross-platform correctness is important, but Windows compatibility must not regress.

---

## Config Principles
- Config should remain repo-local and simple.
- New config options should be easy to understand and validate.
- Invalid config should fail clearly.
- Config design should allow future settings such as:
  - retention duration
  - max file size
  - storage cap
  - binary handling policy

---

## Testing Rules (Must Follow)
- Add or update tests for every behavior change.
- Prefer focused unit tests plus integration-style tests for command workflows when practical.
- Do not merge features without reasonable coverage of happy path and failure path.
- Test safety-sensitive features carefully:
  - restore
  - redo
  - retention cleanup
  - watcher behavior
  - config parsing
  - schema migrations
- If a behavior is difficult to test directly, add the most practical coverage possible and document the gap.

---

## Refactor Rules
- Refactor only as much as needed to support the feature cleanly.
- Do not rewrite unrelated files.
- Do not introduce large abstractions prematurely.
- Keep public behavior stable unless explicitly changing it.
- Preserve existing commands unless the task explicitly includes a migration/update.
- Avoid mixing unrelated cleanup with feature work.

---

## Database and Migration Rules
- SQLite schema changes must be explicit and safe.
- Prefer additive migrations.
- Existing `.dmc` repositories should continue working after upgrade when practical.
- Migration code should be understandable and testable.
- New metadata should be designed with future features in mind:
  - restore audit trail
  - burst IDs
  - task/session IDs
  - source/agent attribution
  - marks/bookmarks

---

## Performance Rules
- Correctness first, then performance.
- Avoid unnecessary DB writes and duplicate snapshots.
- Continue using hashing/deduplication for snapshot efficiency.
- Be mindful of storage growth as new metadata and snapshot features are added.
- Large-file and binary-file handling should be conservative and safe.

---

## Implementation Workflow for Agents
Before making changes:
1. Read `STATUS.md`, then inspect the relevant files.
2. Briefly explain the implementation plan.
3. List the files you intend to modify.
4. Make the smallest clean change that fits the existing architecture.
5. Do not rewrite unrelated code.
6. Add or update tests.
7. Summarize what changed and note any follow-up work.
8. Update `STATUS.md` (see Session status above).

When implementing a feature:
- preserve current behavior unless the task explicitly changes it
- prefer service/repository extraction over CLI bloat
- keep `bin/dmc.dart` thin
- keep Windows compatibility intact

---

## Near-Term Build Priorities
1. Review Phase 5 and run the configured platform matrix before claiming support for each platform.
2. Connect the real Haven process controller to the documented schema 1 contract without reading DMC's SQLite database.
3. Complete Phase 6 and validate an invited standalone trial with exact tested bundles, licensing/distribution decisions, and honest exclusions.

Use `docs/TESTER-READINESS-AUDIT.md` as the original audit and the Phase 2/3 handoffs as current implementation addenda. Do not treat historical findings already addressed as fresh reproductions.

---

## Common Commands
- Doc (from `doc/`): `dart run bin/doc.dart models [--check] [--available]`,
  `dart run bin/doc.dart summarize <checkpoint-id> [--local] [--show-prompt] [--role-provider summary=baseten]`,
  `dart run bin/doc.dart usage`, `dart run bin/doc.dart lesson draft|edit|approve|reject|show|brief`,
  `dart run bin/doc.dart lessons [path]`, `dart run bin/doc.dart start <muse-code|claude-code> "<task>"`,
  `dart run bin/doc.dart restore <checkpoint-id> [--yes] [--no-lesson]`,
  `dart run bin/doc.dart lesson draft --last-restore`,
  `dart run bin/doc.dart bisect --test "<command>" [--setup …] [--link <dir>]… [--json]`. Its gate: `dart pub get --enforce-lockfile`,
  `dart analyze --fatal-infos`, `DMC_TEST_BIN=../build/dmc/bundle/bin/dmc dart test --concurrency=1`.
- `dart run bin/dmc.dart init`
- `dart run bin/dmc.dart watch`
- `dart run bin/dmc.dart log`
- `dart run bin/dmc.dart undo <file>`
- `dart run bin/dmc.dart undo --id <snapshot-id> <file>`
- `dart run bin/dmc.dart diff <file>`
- `dart run bin/dmc.dart diff --id <snapshot-id> <file>`
- `dart run bin/dmc.dart checkpoint begin --label "<label>" --source manual`
- `dart run bin/dmc.dart checkpoint close <checkpoint-id>`
- `dart run bin/dmc.dart checkpoint list --json --schema-version 1`
- `dart run bin/dmc.dart checkpoint show <checkpoint-id>`
- `dart run bin/dmc.dart checkpoint restore <checkpoint-id> --dry-run`
- `dart run bin/dmc.dart checkpoint restore <checkpoint-id> --apply`
- `dart run bin/dmc.dart checkpoint redo <checkpoint-id> --apply`
- `dart run bin/dmc.dart checkpoint recover <operation-id> --resume`
- `dart run bin/dmc.dart checkpoint diff <checkpoint-id>`
- `dart run bin/dmc.dart checkpoint release <checkpoint-id>`
- `dart run bin/dmc.dart checkpoint export <checkpoint-id> --to <dir> [--state before|after] [--json --schema-version 1]`
- `dart run bin/dmc.dart capabilities --json`
- `dart run bin/dmc.dart hooks install --agent claude-code --dmc-command "dart run <repo>/bin/dmc.dart"` (preview; add `--apply` to write; see `docs/AGENT-HOOKS.md`)
- `dmc agent-hook <muse-code|claude-code> <event>` (called by agent hooks; always exits 0 with empty stdout)
- `dart test`
- `dart analyze`
- `dart run tool/check_analyzer.dart` (CI gate; fails on any analyzer diagnostic)
- `dart build cli -o build/dmc`
- `dart run tool/smoke_bundle.dart build/dmc/bundle/bin/dmc` (append `.exe` on Windows)

### Additional Existing Commands
Preserve these CLI routes and their documented legacy meanings:
- `dmc restore <file>`
- `dmc redo <file>`
- `dmc status`
- `dmc doctor`
- `dmc log --bursts`
- `dmc diff --burst <id>`
- `dmc undo --burst <id>`
- `dmc redo --burst <id>`
- `dmc task start "<label>"`
- `dmc task end`
- `dmc log --tasks`
- `dmc undo --task "<label>"`
- `dmc redo --task "<label>"`
- `dmc mark "<label>"`
- `dmc marks`
- `dmc restore --mark "<label>"`
- `dmc snap`
- `dmc gc`

---

## Windows Global Install
- Build the full native-assets bundle: `dart build cli -o build/dmc`
- Test it: `dart run tool/smoke_bundle.dart build/dmc/bundle/bin/dmc.exe`
- Install: `.\install.ps1`

Installer behavior:
- Ensures `C:\bin` exists
- Removes an existing `C:\bin\dmc` installation, then moves `build\dmc\bundle` there; this is not an atomic upgrade with rollback
- Adds `C:\bin\dmc\bin` to persistent user `PATH` if missing
- Instructs user to restart terminal

For trials, prefer keeping the full extracted bundle in a separate folder. Never distribute only the EXE: keep its adjacent `lib` directory. Installer/upgrade safety still needs a later release pass.

---

## Non-Goals
dmc should NOT become:
- a Git replacement
- a remote/cloud-first source control platform
- an overly abstract framework
- a tool that hides risky restore behavior behind vague UX

The focus is:
- local trust
- safe rollback
- AI-assisted coding workflows
- minimal friction
