## Unreleased — Meta AI Developer Hackathon 2026

- Add Doc's lesson library (part 1). Lessons are markdown with YAML front matter in Doc's data dir, keyed by dmc's workspace fingerprint (never in the repo or `.dmc/`). New commands: `doc lesson draft <checkpoint-id>` (workhorse role; files from the checkpoint, never the model; redacted), `doc lesson edit|approve|reject|show`, `doc lessons [--files]`, `doc lessons path`, `doc lesson brief --task` (a fixed file-overlap match, then a brief of at most 100 words from the summary role), and `doc start <muse-code|claude-code> "<task>"` (asks before adding the brief to the agent's first prompt; `--yes` for scripted demos). dmc is unchanged and model-free.
- Add Doc providers `modal` (a private Muse Glimmer 30B deployment; `deploy/modal/` serves Meta's official weights with vLLM 0.28.0 on one L40S, not yet deployed) and `fireworks` (Muse Spark Open backup). `summary` now uses Modal with a logged fallback to Baseten, and `workhorse` falls back from Baseten to Fireworks. Provider request styles (reasoning effort, token-limit field, sampling, Glimmer's reasoning strength) are configuration, and reasoning text is stripped from answers.
- Fix a Windows flake in the watcher rename test: retry the delete of a file the watcher may still hold open (test only).
- Keep agent hooks inside their own Git work tree. `muse -w` creates linked worktrees inside the repository (`<repo>/.muse/worktrees/<date>-<hex>`), so a hook there used to record the turn in the main work tree's vault. `dmc agent-hook` now records nothing, and warns on stderr, when the nearest `.git` marker above its cwd is below the `.dmc` root (a linked worktree, a nested repository or a submodule). It checks marker positions only, with no git process. Each worktree has its own vault and checkpoints after `dmc init` there. `status` and `doctor` show whether the workspace is a linked worktree, its main work tree, and which linked worktrees have a vault.
- Add Doc, a separate companion program in `doc/` (package `dmc_doc`). It talks to dmc only through `--json --schema-version 1`. It has one OpenAI-compatible client for Meta (`api.meta.ai`), Baseten (Muse Spark Open) and a local server (Muse Glimmer), with retries, timeouts, one logged fallback, per-provider budgets and usage tracking, and a tested secret-redaction module. Commands: `doc models [--check] [--available]`, `doc summarize <checkpoint-id> [--local] [--show-prompt]` and `doc usage`. CI analyzes and tests `doc/`.
- Add `dmc agent-hook <muse-code|claude-code> <event>`: a UserPromptSubmit hook begins a checkpoint labelled with the prompt's first line, and Stop, StopFailure, SessionEnd (and Muse Code Interrupt) close it, but only when the same agent and session own it. A missed Stop is closed by the next prompt; a foreign active checkpoint is left alone with a stderr warning. The command always exits 0, prints nothing on stdout, retries a busy workspace lock for up to 5 seconds, and falls back to the session environment when stdin is empty or invalid.
- Add `dmc hooks install|uninstall|status --agent <agent> [--scope project|local|user] [--apply] [--dmc-command <command>]`. It previews the exact JSON change by default, merges idempotently, and removes only exact dmc entries.
- Add schema-version 4: nullable agent-turn context per checkpoint (agent, session, turn, transcript path, and transcript size/SHA-256 at close). Checkpoint JSON gains an additive `agent` object within machine schema 1; `checkpoint show`, `checkpoint list` and `status` print it.
- Add `CheckpointService.closeActive`, which checks ownership of the active checkpoint under the same workspace lock as the close.
- Document the verified Claude Code 2.1.310 hook surface and the researched, not yet verified, Muse Code surface in `docs/AGENT-HOOKS.md`.
- Verify the Muse Code 1.4.13 hook surface on macOS: both `~/.config/muse/settings.json` and a trusted workspace's `.muse/hooks.json` fire; StopFailure and Interrupt payloads were captured; `transcript_path` is always null; `HOME` is passed to hooks. The Muse fixtures are now scrubbed captures, and the default Muse scope stays `user` because project hooks are skipped silently in untrusted workspaces.
- Fix `dmc hooks uninstall` to restore the config file's original bytes: it drops a `hooks` object it emptied, keeps the file's layout and final newline, and deletes a file it left empty.
- Fix agent-hook close events so that a turn ID must match the active checkpoint's turn. A late async Muse Interrupt no longer closes the next turn's checkpoint.
- Fix an intermittent `dart test` failure: agent hook fixtures now resolve from the package root rather than the cwd.
- Add Git-compatible ignore handling. Inside a Git work tree, Git decides what is ignored: the protected file list is `git ls-files --cached --others --exclude-standard`, so nested `.gitignore` files, negation, character classes, `.git/info/exclude`, `core.excludesFile` and tracked files that match a pattern all behave as in Git. DMC's default directories, `.dmcignore` (still the documented subset) and the link and size rules apply on top; submodules and nested repositories are excluded (`nested_repository`). Outside Git, the subset parser and its refusals are unchanged. Previously any workspace with a nested `.gitignore`, `!` or `[...]` (including this repository) could not be checkpointed.
- Git mode never falls back silently: a Git work tree without a usable git records `git_unavailable` (or `git_failed`) at begin, and close fails with it while the checkpoint stays open.
- The policy fingerprint in Git mode (version 2) covers the mode and every ignore source Git reads; editing any of them mid-turn fails close with `policy_changed`. `.gitignore` files that tools write into directories Git already ignores (pytest, venv) do not count.
- Checkpoint restore and redo refuse Git-ignored targets with a `git_ignored` conflict, so they never create, overwrite or delete a Git-ignored file. The watcher checks Git once per drain (`git check-ignore --stdin -z`). `status` and `doctor` print the active ignore policy.
- CI runs `dart test --concurrency=1`, the documented gate, which fixes the older-test `Directory.current` race.
- Handle ignore-policy drift per file. When the ignore policy or config changes during a checkpoint (an agent edits `.gitignore`, adds a nested one, or `.dmcignore` changes), close now succeeds with a non-fatal `policy_changed` warning instead of invalidating the checkpoint. The close-time policy decides what is protected, and both fingerprints are recorded (additive `closePolicyFingerprint`). Files that left protection (`left_scope`, before state kept) or entered it (`entered_scope`, no before state) get an additive `scope` field and a null `change`. Restore and redo list them under an additive `skipped` field and never write them; redo of a changed `entered_scope` file is a `workspace_drift` conflict. Schema 5 adds the two nullable columns without rewriting existing rows, and checkpoints that were already invalid stay invalid.
- Add `dmc checkpoint export <id> --to <dir> [--state before|after]` for bisect. It writes one manifest's files (after by default), with every SHA-256 verified and modes restored, to a new or empty directory outside the workspace, through a temporary sibling that is renamed at the end. A failure leaves nothing behind, and the workspace lock is held only while the manifest is read. JSON returns `checkpointId`, `state`, `directory`, `fileCount`, `totalBytes` and `manifestSha256`. `capabilities` adds `checkpoint.export` and the features `checkpointExport` and `policyDriftPerFile`. Ignored dependencies are not exported.

## 1.1.0-dev.5.1 — Unreleased

- Add `checkpoint recover OP --resume|--rollback --preview` and advertise `operationRecoveryPreview` under machine schema 1.
- Report journal-bound per-file recovery targets and conflicts without changing workspace files, source SQLite sidecars, or operation state.
- Verify saved pre-operation recovery bytes during the shared preflight before rollback starts.
- Keep existing explicit recovery execution behavior. Haven's existing pinned bundle is not automatically upgraded.
- Release under the MIT License.
- Document that machine JSON on stdout is UTF-8 on every platform; the Haven contract harness now decodes it as UTF-8 (Windows defaulted to the active code page and mangled Unicode workspace paths).
- Fix Windows-only test failures (locked-file read in a recovery preview test).
- Remove the unused `_shiftArtLineLeft` UI helper; the CI analyzer gate now fails on any diagnostic (fixes the Windows CI failure caused by path matching in the old exception).

## 1.1.0-dev.5 — Unreleased

- Finalize Haven machine envelope schema 1 with DMC version, process exit code, canonical workspace path, and stable workspace fingerprint on every JSON response.
- Add explicit `--schema-version 1` negotiation and reject unsupported requested versions before running a checkpoint command.
- Add `checkpoint list`, including checkpoint protection counts and operation IDs, and include operation history in `checkpoint show`.
- Define cancellation outcomes for capture and journaled apply/recovery commands. Add compiled-subprocess tests that forcibly terminate both paths and prove detection and recovery.
- Add a standalone Haven reference harness that uses argument arrays and JSON to complete begin, close, list, show, diff, restore, redo, and release with spaces, quotes, and Unicode paths.
- Verify machine output never includes fixture file contents and keep diagnostics off JSON stdout.
- Document the stable Haven subprocess contract, timeouts, exit classes, approval boundary, and recovery flow.

## 1.1.0-dev.4 — Unreleased

- Add conflict-aware whole-checkpoint restore and redo with preview as the default and an explicit `--apply` requirement.
- Preflight every changed path and required snapshot before applying; workspace drift, missing data, corrupt data, linked paths, and a running watcher block the whole operation before project files change.
- Add schema-version 3 operation journals with exact pre-operation content, presence, hashes, and POSIX permission modes, persisted before the first workspace mutation.
- Apply files through flushed temporary files and same-directory renames. Preserve replaced/deleted files in operation recovery storage until the operation completes.
- Add per-file completion records and `checkpoint recover <operation-id> --resume|--rollback` for interrupted multi-file operations.
- Make status and doctor surface incomplete operations and operation-storage problems. Block checkpoint release while recovery is incomplete; release detaches operation and manifest retention pins together.
- Add restore/redo round trips for modified, created, deleted, renamed, and permission-only changes, plus corruption, drift, interruption, resume, rollback, migration, CLI, and symlink-safety tests.

This remains a development preview. Local validation is macOS arm64; the configured macOS/Windows/Linux CI matrix must pass for the exact revision before broader tester claims.

## 1.1.0-dev.3 — Unreleased

- Add schema-version 2 checkpoint manifests with stable local IDs, explicit lifecycle states, before/after presence and hashes, change classifications, exclusions, and fatal issues.
- Add `checkpoint begin`, `close`, `show`, `diff`, and `release` without changing legacy burst, task, mark, snap, restore, redo, or UI semantics.
- Capture and verify complete eligible pre-run and post-run manifests; refuse a second active checkpoint and invalidate incomplete capture or changed policy.
- Pin checkpoint snapshots against retention until explicit release while retaining small manifest/audit metadata after references are detached.
- Add versioned JSON schema 1 output and preliminary `capabilities --json`; checkpoint JSON writes exactly one stdout result.
- Surface active, interrupted, and invalid checkpoint states through status and doctor.
- Add migration, lifecycle, classification, exclusion, failure, retention, JSON, status, and compiled-bundle coverage.

Checkpoint apply/restore, conflicts, redo, and interrupted-operation journals remain Phase 4 work. This is still a development preview.

## 1.1.0-dev.2 — Unreleased

- Harden snapshot publication, schema migration, integrity checks, restore preimages, and retention references (Phase 1).
- Capture a baseline before watcher readiness; reconcile creates, moves, deletes, atomic saves, and offline changes after restart.
- Drain pending and in-flight captures during graceful shutdown, and expose persistent watcher errors and exclusions in status/doctor.
- Validate workspace and vault paths, exclude links, and prune ignored directories before scanning. Reject unsupported ignore policies explicitly.
- Replace PID-based daemon signaling with an exclusive watcher lock and authenticated local control. Refuse ambiguous legacy watcher metadata.
- Add Git exclusion for new vaults, CLI help and error statuses, and explicit-only retention cleanup.
- Add cross-platform test/analyzer/bundle CI and make release builds depend on it with a pinned SDK and lockfile.
- Rewrite installation guidance and add a disposable-project tester walkthrough.

This is a development preview, not a published release. Full project checkpoints and recoverable/conflict-aware multi-file apply remain future phases. Existing UI work is preserved.

## 1.0.0

- Initial version.
